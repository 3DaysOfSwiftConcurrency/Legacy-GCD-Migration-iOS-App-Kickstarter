import Foundation
import KsApi
import Prelude

/// Read boundary shared by project comments, update comments and reply threads.
@MainActor
public protocol DiscussionProvider {
  func comments(slug: String?, updateID: String?, cursor: String?) async throws -> CommentsEnvelope
  func replies(id: String, cursor: String?) async throws -> CommentRepliesEnvelope
  func project(param: Param) async throws -> Project
  func update(id: Int, project: Param) async throws -> Update
  func post(input: PostCommentInput) async throws -> Comment
  func block(id: String) async throws -> EmptyResponseEnvelope
}

@MainActor
public struct AsyncDiscussionProvider: DiscussionProvider {
  private let service: any ServiceType
  public init(service: any ServiceType) { self.service = service }
  public func comments(slug: String?, updateID: String?, cursor: String?) async throws -> CommentsEnvelope {
    try await self.service.discussionComments(slug: slug, updateID: updateID, cursor: cursor)
  }

  public func replies(id: String, cursor: String?) async throws -> CommentRepliesEnvelope {
    try await self.service.discussionReplies(id: id, cursor: cursor)
  }

  public func project(param: Param) async throws -> Project {
    try await self.service.discussionProject(param: param)
  }

  public func update(id: Int, project: Param) async throws -> Update {
    try await self.service.projectUpdate(id: id, project: project)
  }

  public func post(input: PostCommentInput) async throws -> Comment {
    try await self.service.submitDiscussionComment(input: input)
  }

  public func block(id: String) async throws -> EmptyResponseEnvelope {
    try await self.service.blockDiscussionUser(id: id)
  }
}

/// Owns discussion reads and durable mutations. Screen release cancels reads,
/// never an admitted write: server cancellation cannot roll back a comment.
@MainActor
public final class DiscussionFeature {
  public struct Platform {
    let serverConfig: @MainActor () -> any ServerConfigType
    let prepareWebRequest: @MainActor (URLRequest) -> URLRequest
    let optimisticCommentID: @MainActor () -> String
    let now: @MainActor () -> Date
    let responseDelaySeconds: @MainActor () -> TimeInterval

    public init(
      serverConfig: @escaping @MainActor () -> any ServerConfigType,
      prepareWebRequest: @escaping @MainActor (URLRequest) -> URLRequest,
      optimisticCommentID: @escaping @MainActor () -> String,
      now: @escaping @MainActor () -> Date,
      responseDelaySeconds: @escaping @MainActor () -> TimeInterval
    ) {
      self.serverConfig = serverConfig
      self.prepareWebRequest = prepareWebRequest
      self.optimisticCommentID = optimisticCommentID
      self.now = now
      self.responseDelaySeconds = responseDelaySeconds
    }
  }

  public func helpType(for url: URL) -> HelpType? {
    HelpType.helpType(from: url, baseURL: self.platform.serverConfig().webBaseUrl)
  }
  public func helpURL(_ type: HelpType) -> String? {
    type.url(withBaseUrl: self.platform.serverConfig().webBaseUrl)?.absoluteString
  }

  public func canBlock(author: Comment.Author) -> Bool {
    guard let currentUser = self.sessionFeature.currentUser else { return false }
    return String(currentUser.id) != author.id && !author.isBlocked
  }

  public func navigationMatch(_ request: URLRequest) -> Navigation? {
    let config = self.platform.serverConfig()
    return request.url.flatMap {
      Navigation.match($0, apiBaseURL: config.apiBaseUrl, webBaseURL: config.webBaseUrl)
    }
  }

  public enum Source: Equatable {
    case project(String)
    case update(String)
    case replies(String)
  }

  public struct PageSnapshot {
    public fileprivate(set) var comments: [Comment] = []
    public fileprivate(set) var totalCount = 0
    public fileprivate(set) var isLoading = false
    public fileprivate(set) var error: ErrorEnvelope?
  }

  private final class PageRoute {
    var source: Source
    let userID: Int?
    let generation: Int
    var nextSource: Source?
    var cursor: String?
    var snapshot = PageSnapshot()
    var hasReceivedPage = false
    var request: (id: UUID, task: Task<Void, Never>)?
    init(source: Source, userID: Int?, generation: Int) {
      self.source = source
      self.userID = userID
      self.generation = generation
    }
  }

  public let sessionFeature: SessionFeature
  private let makeProvider: () -> any DiscussionProvider
  // Mutations have stable attempt identity, independent from page routes.
  // Identical text submitted deliberately twice has two operation IDs; retries
  // of one failed comment share its ID while the request is in flight.
  private struct PostIdentity: Hashable {
    let operationID: String
    let body: String
    let commentableID: String
    let parentID: String?
    let userID: Int?
    let generation: Int
  }

  private struct BlockIdentity: Hashable {
    let targetID: String
    let userID: Int?
    let generation: Int
  }

  private var posts: [PostIdentity: Task<Comment, Error>] = [:]
  private var blocks: [BlockIdentity: Task<EmptyResponseEnvelope, Error>] = [:]
  private var activePosts = 0
  private var waitingPosts: [CheckedContinuation<Void, Never>] = []

  /// Preserve the existing five-request limit without blocking an executor.
  /// Distinct writes queue FIFO for admission, then may finish independently.
  private func acquirePostSlot() async {
    if self.activePosts < 5 {
      self.activePosts += 1
    } else {
      await withCheckedContinuation { self.waitingPosts.append($0) }
    }
  }

  private func releasePostSlot() {
    if self.waitingPosts.isEmpty {
      self.activePosts -= 1
    } else {
      self.waitingPosts.removeFirst().resume()
    }
  }

  public func post(
    operationID: String, body: String, commentableID: String, parentID: String?
  ) async throws -> Comment {
    try Task.checkCancellation()
    let comment = try await self.requestPost(
      operationID: operationID, body: body, commentableID: commentableID, parentID: parentID
    ).value
    try Task.checkCancellation()
    return comment
  }

  struct OptimisticPost {
    let comment: Comment
    let result: Task<Comment, Error>
  }

  /// Admit the write before publishing an optimistic comment, so a dismissed
  /// presentation cannot prevent the server operation from starting.
  func beginPost(project: Project, commentableID: String, parentID: String?, user: User, body: String) -> OptimisticPost {
    let comment = Comment.failableComment(
      withId: self.platform.optimisticCommentID(),
      date: self.platform.now(),
      project: project, parentId: parentID, user: user, body: body
    )
    let result = self.requestPost(
      operationID: UUID().uuidString, body: body, commentableID: commentableID, parentID: parentID
    )
    return OptimisticPost(comment: comment, result: result)
  }

  /// The write is admitted before the optimistic value is delivered. Cancelling
  /// the presentation stops delivery but does not cancel the server operation.
  @discardableResult
  func beginPresentedPost(
    project: Project, commentableID: String, parentID: String?, user: User, body: String,
    receive: @escaping (Comment, String) -> Void
  ) -> Task<Void, Never> {
    let userID = self.sessionFeature.currentUser?.id
    let generation = self.sessionFeature.generation
    let submission = self.beginPost(
      project: project, commentableID: commentableID, parentID: parentID, user: user, body: body
    )
    receive(submission.comment, submission.comment.id)
    return Task { [self] in
      let result = await submission.result.result
      do {
        try await self.sleep(1)
        try Task.checkCancellation()
        guard self.sessionFeature.isCurrent(userID: userID, generation: generation) else { return }
        switch result {
        case let .success(comment):
          receive(comment, submission.comment.id)
        case .failure(is CancellationError):
          return
        case .failure:
          try await self.sleep(1)
          try Task.checkCancellation()
          guard self.sessionFeature.isCurrent(userID: userID, generation: generation) else { return }
          receive(submission.comment.updatingStatus(to: .failed), submission.comment.id)
        }
      } catch {
        // The independently owned write continues if its presentation disappears.
      }
    }
  }

  @discardableResult
  public func requestPost(
    operationID: String, body: String, commentableID: String, parentID: String?
  ) -> Task<Comment, Error> {
    let key = PostIdentity(
      operationID: operationID, body: body, commentableID: commentableID,
      parentID: parentID, userID: self.sessionFeature.currentUser?.id, generation: self.sessionFeature.generation
    )
    // Cancelling a waiter must not cancel a mutation another caller still needs.
    return self.requestPost(key)
  }

  /// Presents a retry without tying the admitted write to the screen's lifetime.
  /// Capture the session before the first presentation delay so an old comment
  /// can never be submitted under a newly signed-in account.
  @discardableResult
  func beginRetry(
    comment: Comment, commentableID: String, parentID: String?,
    receive: @escaping (Comment, String) -> Void
  ) -> Task<Void, Never> {
    let key = PostIdentity(
      operationID: comment.id, body: comment.body, commentableID: commentableID,
      parentID: parentID, userID: self.sessionFeature.currentUser?.id,
      generation: self.sessionFeature.generation
    )
    let delay = self.platform.responseDelaySeconds()
    receive(comment.updatingStatus(to: .retrying), comment.id)
    return Task { [self] in
      do {
        try await self.sleep(1)
        try Task.checkCancellation()
        guard self.sessionFeature.isCurrent(userID: key.userID, generation: key.generation) else { return }
        receive(comment.updatingStatus(to: .retrying), comment.id)
        let result = await self.requestPost(key).result
        try await self.sleep(delay)
        try Task.checkCancellation()
        guard self.sessionFeature.isCurrent(userID: key.userID, generation: key.generation) else { return }
        switch result {
        case let .success(successfulComment):
          let retrySuccess = successfulComment.updatingStatus(to: .retrySuccess) |> \.id .~ comment.id
          receive(retrySuccess, comment.id)
          try await self.sleep(3)
          try Task.checkCancellation()
          guard self.sessionFeature.isCurrent(userID: key.userID, generation: key.generation) else { return }
          receive(successfulComment, comment.id)
        case .failure(is CancellationError):
          return
        case .failure:
          receive(comment, comment.id)
        }
      } catch {
        // A cancelled presentation must not cancel a write already admitted.
      }
    }
  }

  private func requestPost(_ key: PostIdentity) -> Task<Comment, Error> {
    if let task = self.posts[key] { return task }
    let provider = self.makeProvider()
    let task = Task { [self] in
      await self.acquirePostSlot()
      defer {
        self.posts[key] = nil
        self.releasePostSlot()
      }
      let result: Result<Comment, Error>
      do {
        try Task.checkCancellation()
        guard self.sessionFeature.isCurrent(userID: key.userID, generation: key.generation) else { throw CancellationError() }
        let comment = try await provider.post(input: PostCommentInput(
          body: key.body, commentableId: key.commentableID, parentId: key.parentID
        ))
        try Task.checkCancellation()
        guard self.sessionFeature.isCurrent(userID: key.userID, generation: key.generation) else { throw CancellationError() }
        result = .success(comment)
      } catch {
        result = .failure(
          self.sessionFeature.isCurrent(userID: key.userID, generation: key.generation) ? error : CancellationError()
        )
      }
      return try result.get()
    }
    self.posts[key] = task
    return task
  }

  public func blockUser(id: String) async throws -> EmptyResponseEnvelope {
    try Task.checkCancellation()
    let result = try await self.requestBlockUser(id: id).value
    try Task.checkCancellation()
    return result
  }

  @discardableResult
  public func requestBlockUser(id: String) -> Task<EmptyResponseEnvelope, Error> {
    self.requestBlock(BlockIdentity(targetID: id, userID: self.sessionFeature.currentUser?.id, generation: self.sessionFeature.generation))
  }

  private func requestBlock(_ key: BlockIdentity) -> Task<EmptyResponseEnvelope, Error> {
    if let task = self.blocks[key] { return task }
    let provider = self.makeProvider()
    // Different users are independent writes, not replaceable searches.
    let task = Task { [self] in
      defer { self.blocks[key] = nil }
      let result: Result<EmptyResponseEnvelope, Error>
      do {
        try Task.checkCancellation()
        guard self.sessionFeature.isCurrent(userID: key.userID, generation: key.generation) else { throw CancellationError() }
        let response = try await provider.block(id: key.targetID)
        try Task.checkCancellation()
        guard self.sessionFeature.isCurrent(userID: key.userID, generation: key.generation) else { throw CancellationError() }
        result = .success(response)
      } catch {
        result = .failure(
          self.sessionFeature.isCurrent(userID: key.userID, generation: key.generation) ? error : CancellationError()
        )
      }
      return try result.get()
    }
    self.blocks[key] = task
    return task
  }

  /// Test synchronization for the existing scheduler-driven presentation adapters.
  /// Awaiting writes does not advance or bypass their visible status delays.
  func waitForMutations() async {
    let posts = Array(self.posts.values)
    let blocks = Array(self.blocks.values)
    for task in posts { _ = await task.result }
    for task in blocks { _ = await task.result }
  }

  private let sleep: (TimeInterval) async throws -> Void
  private let platform: Platform
  private var pages: [UUID: PageRoute] = [:]
  internal enum PageUpdate {
    case page(UUID, [Comment], Int)
    case loading(UUID, Bool)
    case error(UUID, ErrorEnvelope)
  }
  private var pageObservers: [(id: UUID, callback: (PageUpdate) -> Void)] = []
  internal func observePages(_ callback: @escaping (PageUpdate) -> Void) -> MainActorObservation {
    let id = UUID()
    self.pageObservers.append((id, callback))
    return MainActorObservation { [weak self] in self?.pageObservers.removeAll { $0.id == id } }
  }
  private func emitPage(_ update: PageUpdate) {
    for observer in self.pageObservers { observer.callback(update) }
  }

  public init(
    platform: Platform,
    sessionFeature: SessionFeature,
    makeProvider: @escaping () -> any DiscussionProvider,
    sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
      if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
    }
  ) {
    self.sessionFeature = sessionFeature
    self.makeProvider = makeProvider
    self.platform = platform
    self.sleep = sleep
  }

  public func preparedWebRequest(from request: URLRequest) -> URLRequest {
    self.platform.prepareWebRequest(request)
  }

  public func snapshot(for route: UUID) -> PageSnapshot {
    guard let page = self.pages[route],
          self.sessionFeature.isCurrent(userID: page.userID, generation: page.generation) else {
      return PageSnapshot()
    }
    return page.snapshot
  }

  public func loadFirstPage(route: UUID, source: Source, refresh: Bool = false) async {
    guard !Task.isCancelled else { return }
    await self.requestFirstPage(route: route, source: source, refresh: refresh).value
  }

  /// Equivalent initial reads share work. Explicit refresh/retry replaces only
  /// this route, including a page request that was still in flight.
  @discardableResult
  public func requestFirstPage(route: UUID, source: Source, refresh: Bool = false) -> Task<Void, Never> {
    let userID = self.sessionFeature.currentUser?.id
    let generation = self.sessionFeature.generation
    let previous = self.pages[route]
    if !refresh, let previous, previous.source == source, previous.userID == userID,
       previous.generation == generation,
       let request = previous.request { return request.task }
    previous?.request?.task.cancel()
    let page = PageRoute(source: source, userID: userID, generation: generation)
    self.pages[route] = page
    // paginate(clearOnNewRequest:) suppressed the first clear but emitted later clears.
    if let previous {
      if case .replies = source {
        // The reply adapter's total-count signal had no value until the first
        // successful envelope. A retry after an initial failure emitted no clear.
        if self.sessionFeature.isCurrent(userID: previous.userID, generation: previous.generation) {
          page.hasReceivedPage = previous.hasReceivedPage
          page.snapshot.totalCount = previous.snapshot.totalCount
        }
        if previous.hasReceivedPage {
          self.emitPage(.page(route, [], page.snapshot.totalCount))
        }
      } else {
        self.emitPage(.page(route, [], 0))
      }
    }
    return self.startPage(route: route, page: page, source: source, cursor: nil)
  }

  public func loadNextPage(route: UUID) async {
    guard !Task.isCancelled else { return }
    await self.requestNextPage(route: route)?.value
  }

  @discardableResult
  public func requestNextPage(route: UUID) -> Task<Void, Never>? {
    guard let page = self.pages[route],
          self.sessionFeature.isCurrent(userID: page.userID, generation: page.generation) else { return nil }
    if let request = page.request { return request.task }
    guard let source = page.nextSource else { return nil }
    return self.startPage(route: route, page: page, source: source, cursor: page.cursor)
  }

  private func startPage(
    route: UUID, page: PageRoute, source: Source, cursor: String?
  ) -> Task<Void, Never> {
    let provider = self.makeProvider()
    let sessionFeature = self.sessionFeature
    let delay = self.platform.responseDelaySeconds()
    let sleep = self.sleep
    let requestID = UUID()
    page.snapshot.isLoading = true
    page.snapshot.error = nil
    let task = Task { [weak self] in
      defer {
        if let self, self.pages[route]?.request?.id == requestID {
          page.request = nil
          page.snapshot.isLoading = false
          self.emitPage(.loading(route, false))
        }
      }
      do {
        try Task.checkCancellation()
        guard sessionFeature.isCurrent(userID: page.userID, generation: page.generation)
        else { throw CancellationError() }
        let comments: [Comment]
        let count: Int
        let nextSource: Source?
        let nextCursor: String?
        switch source {
        case let .replies(id):
          let envelope = try await provider.replies(id: id, cursor: cursor)
          comments = envelope.replies
          count = envelope.totalCount
          nextCursor = envelope.cursor
          nextSource = .replies(envelope.comment.id)
        case .project, .update:
          let slug: String?
          let updateID: String?
          switch source {
          case let .project(value): slug = value; updateID = nil
          case let .update(value): slug = nil; updateID = value
          case .replies: throw ErrorEnvelope.couldNotParseJSON
          }
          let envelope = try await provider.comments(slug: slug, updateID: updateID, cursor: cursor)
          comments = envelope.comments
          count = envelope.totalCount
          nextCursor = envelope.cursor
          nextSource = envelope.slug.map(Source.project) ?? envelope.updateID.map(Source.update)
        }
        try await sleep(delay)
        try Task.checkCancellation()
        guard let self, self.pages[route]?.request?.id == requestID,
              sessionFeature.isCurrent(userID: page.userID, generation: page.generation) else { return }
        page.snapshot.comments = comments
        page.hasReceivedPage = true
        page.snapshot.totalCount = count
        page.cursor = nextCursor
        // Preserve the existing empty-page sentinel (not the envelope flags).
        page.nextSource = comments.isEmpty ? nil : nextSource
        self.emitPage(.page(route, comments, count))
      } catch is CancellationError {
        // Navigation, refresh and account changes never become visible errors.
      } catch DiscussionResponseError.missingEnvelope {
        // The legacy decoder completed silently: retain data/cursor and finish
        // loading without inventing either an empty page or a visible error.
      } catch {
        do { try await sleep(delay) } catch { return }
        guard !Task.isCancelled, let self, self.pages[route]?.request?.id == requestID,
              sessionFeature.isCurrent(userID: page.userID, generation: page.generation) else { return }
        let failure = (error as? ErrorEnvelope) ?? .couldNotParseJSON
        page.snapshot.error = failure
        self.emitPage(.error(route, failure))
      }
    }
    page.request = (requestID, task)
    self.emitPage(.loading(route, true))
    return task
  }

  // Independent read routes preserve the update-list's distinct update/comments
  // navigation streams and the comment screen's project-context request.
  private struct UpdateIdentity: Equatable {
    let project: Param
    let id: Int
    let userID: Int?
    let generation: Int
  }

  private var updates: [UUID: (identity: UpdateIdentity, id: UUID, task: Task<Update?, Never>)] = [:]
  private var projects: [UUID: (param: Param, userID: Int?, generation: Int, id: UUID, task: Task<Project?, Never>)] = [:]

  // Deep-link navigation owns the enclosing task and validates the session
  // across the full destination load. Keep transport in Discussion.
  func projectContext(param: Param) async throws -> Project {
    try await self.makeProvider().project(param: param)
  }

  func updateContext(id: Int, project: Param) async throws -> Update {
    try await self.makeProvider().update(id: id, project: project)
  }

  func initialReplies(id: String) async throws -> CommentRepliesEnvelope {
    try await self.makeProvider().replies(id: id, cursor: nil)
  }

  public func loadUpdate(route: UUID, id: Int, project: Param) async -> Update? {
    guard !Task.isCancelled else { return nil }
    return await self.requestUpdate(route: route, id: id, project: project).value
  }

  @discardableResult
  public func requestUpdate(route: UUID, id: Int, project: Param) -> Task<Update?, Never> {
    let identity = UpdateIdentity(
      project: project, id: id, userID: self.sessionFeature.currentUser?.id,
      generation: self.sessionFeature.generation
    )
    if let existing = self.updates[route], existing.identity == identity { return existing.task }
    self.updates[route]?.task.cancel()
    let provider = self.makeProvider()
    let sessionFeature = self.sessionFeature
    let token = UUID()
    let task: Task<Update?, Never> = Task { [weak self] in
      defer { if self?.updates[route]?.id == token { self?.updates[route] = nil } }
      do {
        try Task.checkCancellation()
        guard sessionFeature.isCurrent(userID: identity.userID, generation: identity.generation) else { return nil }
        let update = try await provider.update(id: id, project: project)
        try Task.checkCancellation()
        guard let self, self.updates[route]?.id == token,
              sessionFeature.isCurrent(userID: identity.userID, generation: identity.generation) else { return nil }
        return update
      } catch {
        // Existing navigation silently demotes lookup errors.
        return nil
      }
    }
    self.updates[route] = (identity, token, task)
    return task
  }

  public func loadProject(route: UUID, param: Param) async -> Project? {
    guard !Task.isCancelled else { return nil }
    return await self.requestProject(route: route, param: param).value
  }

  @discardableResult
  public func requestProject(route: UUID, param: Param) -> Task<Project?, Never> {
    let userID = self.sessionFeature.currentUser?.id
    let generation = self.sessionFeature.generation
    if let existing = self.projects[route], existing.param == param, existing.userID == userID,
       existing.generation == generation {
      return existing.task
    }
    self.projects[route]?.task.cancel()
    let provider = self.makeProvider()
    let sessionFeature = self.sessionFeature
    let token = UUID()
    let task: Task<Project?, Never> = Task { [weak self] in
      defer { if self?.projects[route]?.id == token { self?.projects[route] = nil } }
      do {
        try Task.checkCancellation()
        guard sessionFeature.isCurrent(userID: userID, generation: generation) else { return nil }
        let project = try await provider.project(param: param)
        try Task.checkCancellation()
        guard let self, self.projects[route]?.id == token,
              sessionFeature.isCurrent(userID: userID, generation: generation) else { return nil }
        return project
      } catch {
        // Preserve the legacy context lookup's silent error delivery.
        return nil
      }
    }
    self.projects[route] = (param, userID, generation, token, task)
    return task
  }

  public func release(route: UUID) {
    self.pages.removeValue(forKey: route)?.request?.task.cancel()
    self.updates.removeValue(forKey: route)?.task.cancel()
    self.projects.removeValue(forKey: route)?.task.cancel()
  }

  public func cancelProject(route: UUID) {
    self.projects.removeValue(forKey: route)?.task.cancel()
  }
}
