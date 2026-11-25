import Foundation
import KsApi

@MainActor
public protocol ProfileProvider {
  func fetchProfileProjectsPage(type: ProfileProjectsType, cursor: String?) async throws -> ProfileFeature.Page
}

@MainActor
public struct AsyncProfileProvider: ProfileProvider {
  private let service: any ServiceType
  public init(service: any ServiceType) { self.service = service }
  public func fetchProfileProjectsPage(type: ProfileProjectsType, cursor: String?) async throws -> ProfileFeature.Page {
    let data: ProfileProjectsResponse
    switch type {
    case .backed: data = try await self.service.profileBackedProjects(cursor: cursor)
    case .saved: data = try await self.service.profileSavedProjects(cursor: cursor)
    }
    return ProfileFeature.Page(
      projects: data.projects.compactMap(ProjectCardProperties.init), cursor: data.cursor
    )
  }
}

/// Owns Profile's backed/saved collections and header refresh composition.
/// Header reads remain concurrent and fail independently.
@MainActor
public final class ProfileFeature {
  public struct Page {
    public let projects: [ProjectCardProperties]
    public let cursor: String?
    public init(projects: [ProjectCardProperties], cursor: String?) {
      self.projects = projects
      self.cursor = cursor
    }
  }

  public struct Snapshot {
    public fileprivate(set) var projects: [ProjectCardProperties] = []
    public fileprivate(set) var error: Error?
    public fileprivate(set) var isLoading = false
  }

  private final class Route {
    let userID: Int?
    let generation: Int
    var snapshot = Snapshot()
    var cursor: String?
    var request: (token: UUID, cursor: String?, task: Task<Void, Never>)?
    init(userID: Int?, generation: Int) { self.userID = userID; self.generation = generation }
  }

  public let sessionFeature: SessionFeature
  private let loadAvatar: @MainActor (URL) async throws -> Data
  private var avatarRequest: (url: URL, userID: Int?, generation: Int, id: UUID, task: Task<Data, Error>)?
  private var latestAvatarRequestID: UUID?
  private let makeProvider: () -> any ProfileProvider
  private let responseDelaySeconds: @MainActor () -> TimeInterval
  private let sleep: (TimeInterval) async throws -> Void
  private var projectCollectionsByType: [ProfileProjectsType: Route] = [:]
  private var headerRequest: (
    userID: Int?,
    generation: Int,
    userReadGeneration: Int,
    token: UUID,
    task: Task<Void, Never>
  )?
  public private(set) var userError: Error?
  public private(set) var graphUserError: Error?
  enum HeaderEvent {
    case user(User)
    case graphUser(User)
    case combinedUser(User)
  }
  private var headerSubscribers: [UUID: @MainActor (HeaderEvent) -> Void] = [:]

  func observeHeader(_ receive: @escaping @MainActor (HeaderEvent) -> Void) -> PlatformObservation {
    let id = UUID()
    self.headerSubscribers[id] = receive
    return PlatformObservation { [weak self] in
      Task { @MainActor in self?.headerSubscribers[id] = nil }
    }
  }

  private func publishHeaderEvent(_ event: HeaderEvent) {
    for receive in Array(self.headerSubscribers.values) { receive(event) }
  }

  public enum PageEvent {
    case projects(ProfileProjectsType, [ProjectCardProperties])
    case loading(ProfileProjectsType, Bool)
  }
  private var pageSubscribers: [UUID: @MainActor (PageEvent) -> Void] = [:]

  func observePages(_ receive: @escaping @MainActor (PageEvent) -> Void) -> PlatformObservation {
    let id = UUID()
    self.pageSubscribers[id] = receive
    return PlatformObservation { [weak self] in
      Task { @MainActor in self?.pageSubscribers[id] = nil }
    }
  }

  private func publish(_ event: PageEvent) {
    for receive in Array(self.pageSubscribers.values) { receive(event) }
  }

  public init(
    sessionFeature: SessionFeature, makeProvider: @escaping () -> any ProfileProvider,
    responseDelaySeconds: @escaping @MainActor () -> TimeInterval,
    loadAvatar: (@MainActor (URL) async throws -> Data)? = nil,
    sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
      if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
    }
  ) {
    self.sessionFeature = sessionFeature
    self.makeProvider = makeProvider
    self.responseDelaySeconds = responseDelaySeconds
    self.sleep = sleep
    self.loadAvatar = loadAvatar ?? { try await ProfileAvatarStore.shared.loadAvatarBytes(for: $0) }
  }

  public func cancelAvatarLoad() {
    self.avatarRequest?.task.cancel()
    self.avatarRequest = nil
    self.latestAvatarRequestID = nil
  }

  public func loadAvatarData(url: URL) async throws -> Data {
    try Task.checkCancellation()
    let userID = self.sessionFeature.currentUser?.id
    let generation = self.sessionFeature.generation
    guard userID != nil, self.sessionFeature.currentUser?.avatar.small == url.absoluteString else {
      throw CancellationError()
    }
    let task: Task<Data, Error>
    let id: UUID
    if let pending = self.avatarRequest, pending.url == url, pending.userID == userID,
      pending.generation == generation {
      task = pending.task; id = pending.id
    } else {
      self.cancelAvatarLoad()
      id = UUID()
      self.latestAvatarRequestID = id
      task = Task { [loadAvatar] in
        try Task.checkCancellation()
        let data = try await loadAvatar(url)
        try Task.checkCancellation()
        return data
      }
      self.avatarRequest = (url, userID, generation, id, task)
    }
    defer { if self.avatarRequest?.id == id { self.avatarRequest = nil } }
    let data = try await task.value
    try Task.checkCancellation()
    guard self.latestAvatarRequestID == id,
      self.sessionFeature.isCurrent(userID: userID, generation: generation),
      self.sessionFeature.currentUser?.avatar.small == url.absoluteString else { throw CancellationError() }
    return data
  }

  public func resetForSessionChange() {
    self.cancelAvatarLoad()
    self.headerRequest?.task.cancel()
    self.headerRequest = nil
    for page in self.projectCollectionsByType.values { page.request?.task.cancel() }
    self.projectCollectionsByType.removeAll()
    self.userError = nil
    self.graphUserError = nil
  }

  public func snapshot(for type: ProfileProjectsType) -> Snapshot {
    guard let page = self.projectCollectionsByType[type],
          self.sessionFeature.isCurrent(userID: page.userID, generation: page.generation)
    else { return Snapshot() }
    return page.snapshot
  }

  public func projectCount(for type: ProfileProjectsType) -> Int {
    switch type {
    case .backed: return self.sessionFeature.currentUser?.stats.backedProjectsCount ?? 0
    case .saved: return self.sessionFeature.currentUser?.stats.starredProjectsCount ?? 0
    }
  }

  public func refreshHeader() async { await self.startProfileHeaderLoad().value }
  @discardableResult
  public func startProfileHeaderLoad(replacing: Bool = false) -> Task<Void, Never> {
    let userID = self.sessionFeature.currentUser?.id
    guard userID != nil else { self.resetForSessionChange(); return Task {} }
    let generation = self.sessionFeature.generation
    if !replacing, let request = self.headerRequest, request.userID == userID,
       request.generation == generation,
       request.userReadGeneration == self.sessionFeature.userReadGeneration { return request.task }
    self.headerRequest?.task.cancel()
    if replacing { self.sessionFeature.invalidateAccountReads() }
    let userReadGeneration = self.sessionFeature.userReadGeneration
    let token = UUID()
    let userTask = self.sessionFeature.startCurrentUserFetch()
    let graphTask = self.sessionFeature.startGraphUserFetch()
    let delay = self.responseDelaySeconds()
    self.userError = nil
    self.graphUserError = nil
    if let user = self.sessionFeature.currentUser {
      self.publishHeaderEvent(.user(user))
    }
    let task = Task { [weak self] in
      guard let self else { return }
      defer { if self.headerRequest?.token == token { self.headerRequest = nil } }
      async let user = self.publishHeader(
        userTask,
        graph: false,
        userID: userID,
        generation: generation,
        userReadGeneration: userReadGeneration,
        delay: delay
      )
      async let graph = self.publishHeader(
        graphTask,
        graph: true,
        userID: userID,
        generation: generation,
        userReadGeneration: userReadGeneration,
        delay: delay
      )
      let (restUser, graphUser) = await (user, graph)
      guard !Task.isCancelled, self.headerRequest?.token == token,
            self.sessionFeature.isCurrent(userID: userID, generation: generation),
            self.sessionFeature.userReadGeneration == userReadGeneration,
            var merged = restUser, let graphUser else { return }
      merged.stats.starredProjectsCount = graphUser.stats.starredProjectsCount
      self.sessionFeature.commitUser(merged, userID: userID, generation: generation)
      self.publishHeaderEvent(.combinedUser(merged))
    }
    self.headerRequest = (userID, generation, userReadGeneration, token, task)
    return task
  }

  private func publishHeader(
    _ task: Task<User, Error>, graph: Bool, userID: Int?, generation: Int,
    userReadGeneration: Int, delay: TimeInterval
  ) async -> User? {
    do {
      let user = try await task.value
      try await self.sleep(delay)
      try Task.checkCancellation()
      guard self.sessionFeature.isCurrent(userID: userID, generation: generation),
            self.sessionFeature.userReadGeneration == userReadGeneration else { return nil }
      if graph {
        self.publishHeaderEvent(.graphUser(user))
      } else {
        self.publishHeaderEvent(.user(user))
      }
      return user
    } catch {
      guard !Task.isCancelled, !(error is CancellationError), self.sessionFeature.isCurrent(
        userID: userID,
        generation: generation
      ), self.sessionFeature.userReadGeneration == userReadGeneration else { return nil }
      if graph { self.graphUserError = error } else { self.userError = error }
      return nil
    }
  }

  public func refreshProfileProjects(type: ProfileProjectsType) async { await self.startProfileProjectsPageLoad(type: type)?.value }
  public func loadNextProfileProjectsPage(type: ProfileProjectsType) async {
    await self.startProfileProjectsPageLoad(type: type, next: true)?.value
  }

  @discardableResult
  public func startProfileProjectsPageLoad(type: ProfileProjectsType, next: Bool = false) -> Task<Void, Never>? {
    let userID = self.sessionFeature.currentUser?.id
    guard userID != nil else { self.resetForSessionChange(); return nil }
    let generation = self.sessionFeature.generation
    let page: Route
    if let existing = self.projectCollectionsByType[type], existing.userID == userID, existing.generation == generation {
      page = existing
    } else {
      self.projectCollectionsByType[type]?.request?.task.cancel()
      page = Route(userID: userID, generation: generation)
      self.projectCollectionsByType[type] = page
    }
    if let request = page.request, next || request.cursor == nil { return request.task }
    guard !next || page.cursor != nil else { return nil }
    page.request?.task.cancel()
    let cursor = next ? page.cursor : nil
    let token = UUID()
    let provider = self.makeProvider()
    let delay = self.responseDelaySeconds()
    page.snapshot.isLoading = true
    page.snapshot.error = nil
    let task = Task { [weak self, sleep] in
      guard let self else { return }
      defer {
        if page.request?.token == token {
          page.request = nil
          page.snapshot.isLoading = false
          if self.projectCollectionsByType[type] === page { self.publish(.loading(type, false)) }
        }
      }
      do {
        try Task.checkCancellation()
        guard self.sessionFeature.isCurrent(userID: userID, generation: generation) else { return }
        let result = try await provider.fetchProfileProjectsPage(type: type, cursor: cursor)
        try await sleep(delay)
        try Task.checkCancellation()
        guard self.projectCollectionsByType[type] === page, page.request?.token == token,
              self.sessionFeature.isCurrent(userID: userID, generation: generation) else { return }
        page.cursor = result.projects.isEmpty ? nil : result.cursor
        page.snapshot.projects = cursor == nil ? result.projects : page.snapshot.projects + result.projects
        self.publish(.projects(type, page.snapshot.projects))
      } catch {
        guard !Task.isCancelled, !(error is CancellationError), self.projectCollectionsByType[type] === page,
              page.request?.token == token,
              self.sessionFeature.isCurrent(userID: userID, generation: generation) else { return }
        page.snapshot.error = error
      }
    }
    page.request = (token, cursor, task)
    self.publish(.loading(type, true))
    return task
  }
}
