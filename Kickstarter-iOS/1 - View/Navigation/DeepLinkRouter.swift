import FirebaseCrashlytics
import Foundation
import KsApi
import Prelude
import UIKit

/// Matches incoming URLs and resolves deep-link destinations before UIKit presents them.
/// Project links publish only after the complete project, update and reply chain loads.
@MainActor
public final class DeepLinkRouter {
  enum URLSource {
    case application
    case braze
  }

  enum Action: Equatable {
    case selectActivity
    case selectSearch
    case selectProfile
    case showLogin(LoginIntent)
    case updateNotification(name: String, enabled: Bool)
    case verifyEmail(String)
    case openBrowser(URL)
    case resolveDestination(Navigation)
  }

  private struct URLMatch {
    let navigation: Navigation?
    let hasDeepLinkMatch: Bool

    func shouldOpenInBrowser(_ url: URL) -> Bool {
      guard !self.hasDeepLinkMatch else { return false }
      guard url.scheme != "ksr" else {
        print(
          "Error: Unable to open 'ksr' deeplink. Please doublecheck that the url "
            + "is included in the list of deeplinks and that you're not trying to "
            + "use a staging url in prod (or vice versa)."
        )
        let error = NSError(domain: "Kickstarter.Deeplink", code: 0, userInfo: [
          NSLocalizedDescriptionKey: "Unable to open unsupported ksr deeplink."
        ])
        Crashlytics.crashlytics().record(error: error)
        return false
      }
      return true
    }
  }

  private static func match(_ url: URL, source: URLSource, config: ServerConfigType) -> URLMatch {
    let deepLink = Navigation.deepLinkMatch(url, apiBaseURL: config.apiBaseUrl, webBaseURL: config.webBaseUrl)
    switch source {
    case .application:
      let navigation = Navigation.match(url, apiBaseURL: config.apiBaseUrl, webBaseURL: config.webBaseUrl)
      return URLMatch(navigation: navigation, hasDeepLinkMatch: deepLink != nil)
    case .braze:
      return URLMatch(navigation: deepLink, hasDeepLinkMatch: deepLink != nil)
    }
  }

  @discardableResult
  func route(
    url: URL, route: UUID, source: URLSource = .application,
    perform: @escaping @MainActor (Action) -> Void
  ) -> Bool {
    let match = Self.match(url, source: source, config: self.serverConfig())
    if let navigation = match.navigation {
      if navigation == .emailClick {
        self.cancelPresentation(route: route)
        if source == .application {
          self.resolveEmailRedirect(url, route: route, perform: perform)
        }
      } else {
        self.route(navigation, perform: perform)
        if source == .application, navigation == .profile(.verifyEmail),
           let token = accessTokenFromUrl(url) {
          perform(.verifyEmail(token))
        }
      }
    }
    if match.shouldOpenInBrowser(url) { perform(.openBrowser(url)) }
    return match.navigation != nil
  }

  func route(push envelope: PushEnvelope, perform: (Action) -> Void) {
    if let navigation = navigation(fromPushEnvelope: envelope, webBaseURL: self.serverConfig().webBaseUrl) {
      self.route(navigation, perform: perform)
    }
  }

  func route(shortcut: ShortcutItem, perform: (Action) -> Void) {
    self.route(navigation(fromShortcutItem: shortcut), perform: perform)
  }

  private func route(_ navigation: Navigation, perform: (Action) -> Void) {
    switch navigation {
    case let .settings(.notifications(name, enabled)):
      perform(.updateNotification(name: name, enabled: enabled))
    case .tab(.activity): perform(.selectActivity)
    case .tab(.search): perform(.selectSearch)
    case .tab(.me): perform(.selectProfile)
    case .tab(.login): perform(.showLogin(.generic))
    case .project(_, .pledge(.manage), _, _) where self.sessionFeature.currentUser == nil:
      perform(.showLogin(.erroredPledge))
    default: break
    }
    perform(.resolveDestination(navigation))
  }

  public let sessionFeature: SessionFeature
  public let messagingFeature: MessagingFeature
  public struct ProjectDestination: Sendable {
    public let project: Project
    public let subpage: Navigation.Project
    public let refInfo: RefInfo?
    public let secretRewardToken: String?
    public let update: Update?
    public let replies: CommentRepliesEnvelope?
  }
  public enum Destination: Sendable {
    case discovery(DiscoveryParams?)
    case project(ProjectDestination)
    case survey(String)
    case message(MessageThread)
  }
  private struct Session: Equatable {
    let userID: Int?
    let generation: Int
  }
  private struct Pending<Value: Sendable> {
    let id: UUID
    let session: Session
    let task: Task<Value, Error>
  }
  private let discussionFeature: DiscussionFeature
  private let discoveryFeature: DiscoveryFeature
  private let activityFeature: ActivityFeature
  private let authenticationFeature: AuthenticationFeature
  private let serverConfig: () -> ServerConfigType
  private let discoveryResponseDelay: () -> TimeInterval
  private let sleep: (TimeInterval) async throws -> Void
  private var destinations: [UUID: (navigation: Navigation, request: Pending<Destination?>)] = [:]
  private var destinationTasks: [UUID: Task<Destination?, Error>] = [:]
  private var presentations: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]
  private var redirects: [UUID: (url: URL, session: Session, id: UUID)] = [:]
  private var redirectTasks: [UUID: Task<Void, Never>] = [:]

  public init(
    sessionFeature: SessionFeature, messagingFeature: MessagingFeature,
    discussionFeature: DiscussionFeature,
    discoveryFeature: DiscoveryFeature, activityFeature: ActivityFeature,
    authenticationFeature: AuthenticationFeature,
    serverConfig: @escaping () -> ServerConfigType,
    discoveryResponseDelay: @escaping () -> TimeInterval,
    sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
      if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
    }
  ) {
    self.sessionFeature = sessionFeature
    self.messagingFeature = messagingFeature
    self.discussionFeature = discussionFeature
    self.discoveryFeature = discoveryFeature
    self.activityFeature = activityFeature
    self.authenticationFeature = authenticationFeature
    self.serverConfig = serverConfig
    self.discoveryResponseDelay = discoveryResponseDelay
    self.sleep = sleep
  }
  private var session: Session {
    Session(userID: self.sessionFeature.currentUser?.id, generation: self.sessionFeature.generation)
  }
  private func requireCurrent(_ session: Session) throws {
    try Task.checkCancellation()
    guard self.session == session else { throw CancellationError() }
  }

  public func resolve(_ navigation: Navigation, route: UUID) async throws -> Destination? {
    try Task.checkCancellation()
    let result = try await self.requestDestination(navigation, route: route).value
    try Task.checkCancellation()
    return result
  }
  @discardableResult public func requestDestination(_ navigation: Navigation, route: UUID) -> Task<
    Destination?, Error
  > {
    let session = self.session
    if let pending = self.destinations[route], pending.navigation == navigation,
      pending.request.session == session
    {
      return pending.request.task
    }
    self.release(route: route)
    let id = UUID()
    let delay = self.discoveryResponseDelay()
    let task = Task { [self] in
      defer {
        self.destinationTasks[id] = nil
        if self.destinations[route]?.request.id == id { self.destinations[route] = nil }
      }
      try self.requireCurrent(session)
      let destination: Destination?
      do {
        destination = try await self.load(
          navigation, session: session, delay: delay)
      } catch {
        try self.requireCurrent(session)
        throw error
      }
      try self.requireCurrent(session)
      guard self.destinations[route]?.request.id == id else { throw CancellationError() }
      return destination
    }
    self.destinations[route] = (navigation, Pending(id: id, session: session, task: task))
    self.destinationTasks[id] = task
    return task
  }

  private func load(
    _ navigation: Navigation, session: Session,
    delay: TimeInterval
  ) async throws -> Destination? {
    switch navigation {
    case .tab(.discovery(let rawParams)):
      guard let rawParams, let params = DiscoveryParams.decodeJSONDictionary(rawParams) else {
        return .discovery(nil)
      }
      let (category, subcategory) = deepLinkCategories(rawParams: rawParams)
      guard let category else { return .discovery(params) }
      let envelope = try await self.discoveryFeature.rootCategories()
      try self.requireCurrent(session)
      let matched = findCategoryFromRootCategories(
        envelope: envelope, categoryParam: category, subcategoryParam: subcategory)
      try await self.sleep(delay)
      return .discovery(params |> DiscoveryParams.lens.category .~ matched)
    case .user(_, .survey(let id)):
      let url = try await self.activityFeature.surveyURL(id: id)
      return .survey(url)
    case .messages(let id):
      return try await self.messagingFeature.thread(id: id).map { .message($0.messageThread) }
    case .project(_, .pledgeManagerWebview(let url), _, _):
      return .survey(url)
    case .project(let param, let subpage, let refInfo, let token):
      let project = try await self.discussionFeature.projectContext(param: param)
      try self.requireCurrent(session)
      // Prelaunch projects only expose their root, as before.
      guard project.displayPrelaunch != true || subpage == .root else { return nil }
      var update: Update?
      var replies: CommentRepliesEnvelope?
      switch subpage {
      case .commentThread(let id?, _):
        replies = try await self.discussionFeature.initialReplies(id: id)
      case .update(let id, let child):
        update = try await self.discussionFeature.updateContext(id: id, project: .id(project.id))
        try self.requireCurrent(session)
        if case .commentThread(let commentID?, _) = child {
          replies = try await self.discussionFeature.initialReplies(id: commentID)
        }
      default: break
      }
      return .project(
        ProjectDestination(
          project: project, subpage: subpage, refInfo: refInfo, secretRewardToken: token,
          update: update, replies: replies))
    default: return nil  // Synchronous destinations still invalidate an earlier async link.
    }
  }

  public func release(route: UUID) {
    self.cancelPresentation(route: route)
    self.destinations.removeValue(forKey: route)?.request.task.cancel()
    if let redirect = self.redirects.removeValue(forKey: route) {
      self.redirectTasks[redirect.id]?.cancel()
    }
    self.authenticationFeature.releaseEmailRedirect(route: route)
  }

  private func resolveEmailRedirect(
    _ url: URL, route: UUID, perform: @escaping @MainActor (Action) -> Void
  ) {
    let session = self.session
    if let pending = self.redirects[route], pending.url == url, pending.session == session { return }
    self.release(route: route)
    let id = UUID()
    let authentication = self.authenticationFeature
    self.redirects[route] = (url, session, id)
    self.redirectTasks[id] = Task { [weak self] in
      defer {
        self?.redirectTasks[id] = nil
        if self?.redirects[route]?.id == id {
          self?.redirects[route] = nil
          authentication.releaseEmailRedirect(route: route)
        }
      }
      do {
        let destination = try await authentication.firstRedirect(url, route: route)
        guard let self, self.redirects[route]?.id == id, let destination else { return }
        try self.requireCurrent(session)
        self.redirects[route] = nil
        authentication.releaseEmailRedirect(route: route)
        self.route(url: destination, route: route, perform: perform)
      } catch { /* Failed or cancelled redirects do not navigate. */ }
    }
  }

  func presentDestination(
    _ navigation: Navigation, route: UUID,
    onDestination: @escaping @MainActor (Destination) -> Void
  ) {
    self.cancelPresentation(route: route)
    let session = self.session
    let request = self.requestDestination(navigation, route: route)
    let id = UUID()
    let task = Task { [weak self] in
      defer {
        if self?.presentations[route]?.id == id { self?.presentations[route] = nil }
      }
      do {
        let destination = try await request.value
        guard let self, let destination else { return }
        try self.requireCurrent(session)
        onDestination(destination)
      } catch { /* Failed or cancelled links do not navigate. */ }
    }
    self.presentations[route] = (id, task)
  }

  func cancelPresentation(route: UUID) {
    self.presentations.removeValue(forKey: route)?.task.cancel()
  }

  func waitForPresentation(route: UUID) async {
    await self.presentations[route]?.task.value
  }
  public func reset() {
    for route in Set(self.destinations.keys).union(self.presentations.keys).union(self.redirects.keys) {
      self.release(route: route)
    }
  }
  public func waitForOperations() async {
    while !self.destinationTasks.isEmpty || !self.presentations.isEmpty || !self.redirectTasks.isEmpty
    {
      for task in Array(self.destinationTasks.values) { _ = await task.result }
      for presentation in Array(self.presentations.values) { await presentation.task.value }
      for redirect in Array(self.redirectTasks.values) { await redirect.value }
    }
  }

}

extension DeepLinkRouter.Destination {
  @MainActor
  func makeViewController(isLoggedIn: Bool) -> UINavigationController? {
    switch self {
    case let .survey(url):
      let controller = PledgeManagerWebViewController.configuredWith(url: url)
      let navigation = UINavigationController(rootViewController: controller)
      navigation.modalPresentationStyle = .pageSheet
      return navigation
    case let .project(project):
      return ProjectDeepLink.viewController(project, isLoggedIn: isLoggedIn)
    case .discovery, .message:
      return nil
    }
  }
}

/// Pure UIKit composition from one fully resolved destination.
@MainActor
private enum ProjectDeepLink {
  static func viewController(
    _ destination: DeepLinkRouter.ProjectDestination, isLoggedIn: Bool
  ) -> UINavigationController? {
    let project = destination.project
    let page = ProjectPageViewController.configuredWith(
      projectOrParam: .left(project), refInfo: destination.refInfo,
      secretRewardToken: destination.secretRewardToken
    )
    var controllers: [UIViewController] = [page]
    switch destination.subpage {
    case .root: break
    case .comments:
      controllers.append(commentsViewController(for: project, update: nil))
    case let .commentThread(_, replyID):
      guard let replies = destination.replies else { return nil }
      controllers += [commentsViewController(for: project, update: nil),
        CommentRepliesViewController.configuredWith(comment: replies.comment, project: project, update: nil,
          inputAreaBecomeFirstResponder: false, replyId: replyID)]
    case .updates:
      controllers.append(ProjectUpdatesViewController.configuredWith(project: project))
    case let .update(_, subpage):
      guard let update = destination.update else { return nil }
      controllers.append(UpdateViewController.configuredWith(project: project, update: update, context: .deepLink))
      switch subpage {
      case .root: break
      case .comments: controllers.append(commentsViewController(update: update))
      case let .commentThread(_, replyID):
        guard let replies = destination.replies else { return nil }
        controllers += [commentsViewController(for: nil, update: update),
          CommentRepliesViewController.configuredWith(comment: replies.comment, project: project, update: update,
            inputAreaBecomeFirstResponder: false, replyId: replyID)]
      }
    case .pledge(.manage):
      guard isLoggedIn,
            let backingID = project.personalization.backing?.id else { return nil }
      let controller = ManagePledgeViewController.instantiate()
      controller.configureWith(params: (.id(project.id), .id(backingID)))
      controllers.append(controller)
      let navigation = RewardPledgeNavigationController(nibName: nil, bundle: nil)
      navigation.viewControllers = controllers
      navigation.modalPresentationStyle = .pageSheet
      return navigation
    default: return nil
    }
    return ProjectPageViewController.navigationController(withViewControllers: controllers)
  }
}

@MainActor
private func navigation(fromPushEnvelope envelope: PushEnvelope, webBaseURL: URL) -> Navigation? {
  if let activity = envelope.activity {
    switch activity.category {
    case .backing:
      guard let projectId = activity.projectId else { return nil }
      return .project(.id(projectId), .root, refInfo: RefInfo(.push))
    case .failure, .launch, .success, .cancellation, .suspension:
      guard let projectId = activity.projectId else { return nil }
      return .project(.id(projectId), .root, refInfo: RefInfo(.push))

    case .update:
      guard let projectId = activity.projectId, let updateId = activity.updateId else { return nil }
      return .project(.id(projectId), .update(updateId, .root), refInfo: RefInfo(.push))

    case .commentPost:
      guard let projectId = activity.projectId, let updateId = activity.updateId else { return nil }

      if let commentId = activity.commentId {
        return .project(
          .id(projectId),
          .update(updateId, .commentThread(commentId, activity.replyId)),
          refInfo: RefInfo(.push)
        )
      }
      return .project(.id(projectId), .update(updateId, .comments), refInfo: RefInfo(.push))

    case .commentProject:
      guard let projectId = activity.projectId else { return nil }

      if let commentId = activity.commentId {
        return .project(.id(projectId), .commentThread(commentId, activity.replyId), refInfo: RefInfo(.push))
      }
      return .project(.id(projectId), .comments, refInfo: RefInfo(.push))

    case .follow:
      return .tab(.activity)

    case .funding, .shipped, .unknown, .watch:
      return nil
    }
  }

  if let order = envelope.order {
    let path = order.pledgeManagerPath
    let url = webBaseURL.absoluteString + path
    return .project(.id(order.projectId), .pledgeManagerWebview(url), refInfo: RefInfo(.push))
  }

  if let project = envelope.project {
    return .project(.id(project.id), .root, refInfo: RefInfo(.push))
  }

  if let message = envelope.message {
    return .messages(messageThreadId: message.messageThreadId)
  }

  if let survey = envelope.survey {
    let path = survey.urls.web.survey
    let url = webBaseURL.absoluteString + path
    return .project(.id(survey.projectId), .pledgeManagerWebview(url), refInfo: RefInfo(.push))
  }

  if let update = envelope.update {
    return .project(.id(update.projectId), .update(update.id, .root), refInfo: RefInfo(.push))
  }

  if let erroredPledge = envelope.erroredPledge {
    return .project(.id(erroredPledge.projectId), .pledge(.manage), refInfo: RefInfo(.push))
  }

  return nil
}

// Figures out a `Navigation` to route the user to from a shortcut item.
private func navigation(fromShortcutItem shortcutItem: ShortcutItem) -> Navigation {
  switch shortcutItem {
  case .recommendedForYou:
    let params = .defaults
      |> DiscoveryParams.lens.recommended .~ true
      |> DiscoveryParams.lens.sort .~ .magic
    return .tab(.discovery(params.queryParams))

  case .projectsWeLove:
    let params = .defaults
      |> DiscoveryParams.lens.staffPicks .~ true
      |> DiscoveryParams.lens.sort .~ .magic
    return .tab(.discovery(params.queryParams))

  case .search:
    return .tab(.search)
  }
}

private func accessTokenFromUrl(_ url: URL?) -> String? {
  return url.flatMap { url in
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
  }?
    .first { item in item.name == "at" }?
    .value
}
