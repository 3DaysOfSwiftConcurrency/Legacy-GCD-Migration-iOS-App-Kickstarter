import FirebaseCrashlytics
import Foundation
import KsApi
import Prelude
import UIKit

/// Matches incoming URLs and owns the lifetime of their UIKit presentation.
/// AppModel resolves domain data before the router builds a destination controller.
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
    case notificationSettingsUpdated
    case emailVerificationCompleted(String, Bool)
    case openBrowser(URL)
    case showDiscovery(DiscoveryParams?)
    case showMessageThread(MessageThread)
    case showViewController(UINavigationController)
  }

  @MainActor
  struct Delivery {
    let action: Action
    private let validate: @MainActor () -> Bool

    fileprivate init(_ action: Action, validate: @escaping @MainActor () -> Bool = { true }) {
      self.action = action
      self.validate = validate
    }

    var isCurrent: Bool { self.validate() }
  }

  typealias ActionHandler = @MainActor (Delivery) -> Void

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
    perform: @escaping ActionHandler
  ) -> Bool {
    let match = Self.match(url, source: source, config: self.serverConfig())
    let openInBrowser = match.shouldOpenInBrowser(url)
    if let navigation = match.navigation {
      if navigation == .emailClick {
        self.cancelPresentation(route: route)
        if source == .application {
          self.resolveEmailRedirect(url, route: route, perform: perform)
        }
      } else {
        self.route(navigation, route: route, browserFallback: openInBrowser ? url : nil, perform: perform)
        if source == .application, navigation == .profile(.verifyEmail),
           let token = accessTokenFromUrl(url) {
          self.settingsLinks.verifyEmail(token: token) { message, success in
            perform(Delivery(.emailVerificationCompleted(message, success)))
          }
        }
      }
    } else if openInBrowser {
      self.release(route: route)
      self.makeDelivery(for: route, perform: perform)(.openBrowser(url))
    }
    return match.navigation != nil
  }

  func route(
    userActivity: NSUserActivity, route: UUID, perform: @escaping ActionHandler
  ) -> Bool? {
    guard userActivity.activityType == NSUserActivityTypeBrowsingWeb else { return nil }
    guard let url = userActivity.webpageURL else { return false }
    return self.route(url: url, route: route, perform: perform)
  }

  func routeLaunchShortcut(
    _ item: Any?, route: UUID, perform: @escaping ActionHandler
  ) -> Bool {
    if let shortcut = item as? UIApplicationShortcutItem {
      self.route(shortcut: shortcut, route: route, perform: perform)
    }
    return item == nil
  }

  func route(push envelope: PushEnvelope, route: UUID, perform: @escaping ActionHandler) {
    if let navigation = navigation(fromPushEnvelope: envelope, webBaseURL: self.serverConfig().webBaseUrl) {
      self.route(navigation, route: route, perform: perform)
    }
  }

  func route(
    shortcut item: UIApplicationShortcutItem, route: UUID, perform: @escaping ActionHandler
  ) {
    guard let shortcut = ShortcutItem(typeString: item.type) else { return }
    self.route(navigation(fromShortcutItem: shortcut), route: route, perform: perform)
  }

  private func route(
    _ navigation: Navigation, route: UUID, browserFallback: URL? = nil, perform: @escaping ActionHandler
  ) {
    self.cancelPresentation(route: route)
    let request = self.requestDestination(navigation, route: route)
    let deliver = self.makeDelivery(for: route, perform: perform)
    self.presentDestination(request, route: route) { [weak self] destination in
      guard let self else { return }
      switch destination {
      case let .discovery(params): deliver(.showDiscovery(params))
      case let .message(thread): deliver(.showMessageThread(thread))
      case .survey, .project:
        if let controller = destination.makeViewController(
          isLoggedIn: self.session.userID != nil,
          projectPageComposition: self.projectPageComposition
        ) {
          deliver(.showViewController(controller))
        }
      }
    }
    switch navigation {
    case let .settings(.notifications(name, enabled)):
      self.settingsLinks.saveNotificationPreference(name: name, enabled: enabled) {
        perform(Delivery(.notificationSettingsUpdated))
      }
    case .tab(.activity): deliver(.selectActivity)
    case .tab(.search): deliver(.selectSearch)
    case .tab(.me): deliver(.selectProfile)
    case .tab(.login): deliver(.showLogin(.generic))
    case .project(_, .pledge(.manage), _, _) where self.session.userID == nil:
      deliver(.showLogin(.erroredPledge))
    default: break
    }
    if let browserFallback { deliver(.openBrowser(browserFallback)) }
  }

  private struct Pending<Value: Sendable> {
    let id: UUID
    let session: DeepLinkSession
    let task: Task<Value, Error>
  }
  private let currentSession: () -> DeepLinkSession
  private let resolveDestination: (Navigation, TimeInterval) async throws -> DeepLinkDestination?
  private let firstRedirect: (URL, UUID) async throws -> URL?
  private let releaseRedirect: (UUID) -> Void
  private let settingsLinks: SettingsLinkPresentation
  private let serverConfig: () -> ServerConfigType
  private let discoveryResponseDelay: () -> TimeInterval
  private let projectPageComposition: ProjectPageComposition
  private var destinations: [UUID: (navigation: Navigation, request: Pending<DeepLinkDestination?>)] = [:]
  private var destinationTasks: [UUID: Task<DeepLinkDestination?, Error>] = [:]
  private var presentations: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]
  private var deliveryIDs: [UUID: UUID] = [:]
  private var redirects: [UUID: (url: URL, session: DeepLinkSession, id: UUID)] = [:]
  private var redirectTasks: [UUID: Task<Void, Never>] = [:]

  public init(
    currentSession: @escaping () -> DeepLinkSession,
    resolveDestination: @escaping (Navigation, TimeInterval) async throws -> DeepLinkDestination?,
    firstRedirect: @escaping (URL, UUID) async throws -> URL?,
    releaseRedirect: @escaping (UUID) -> Void,
    settingsLinks: SettingsLinkPresentation,
    projectPageComposition: ProjectPageComposition,
    serverConfig: @escaping () -> ServerConfigType,
    discoveryResponseDelay: @escaping () -> TimeInterval
  ) {
    self.currentSession = currentSession
    self.resolveDestination = resolveDestination
    self.firstRedirect = firstRedirect
    self.releaseRedirect = releaseRedirect
    self.settingsLinks = settingsLinks
    self.projectPageComposition = projectPageComposition
    self.serverConfig = serverConfig
    self.discoveryResponseDelay = discoveryResponseDelay
  }
  private var session: DeepLinkSession { self.currentSession() }
  private func requireCurrent(_ session: DeepLinkSession) throws {
    try Task.checkCancellation()
    guard self.session == session else { throw CancellationError() }
  }

  public func resolve(_ navigation: Navigation, route: UUID) async throws -> DeepLinkDestination? {
    try Task.checkCancellation()
    let result = try await self.requestDestination(navigation, route: route).value
    try Task.checkCancellation()
    return result
  }
  @discardableResult public func requestDestination(_ navigation: Navigation, route: UUID) -> Task<
    DeepLinkDestination?, Error
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
      let destination: DeepLinkDestination?
      do {
        destination = try await self.resolveDestination(navigation, delay)
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

  public func release(route: UUID) {
    self.deliveryIDs[route] = nil
    self.cancelPresentation(route: route)
    self.destinations.removeValue(forKey: route)?.request.task.cancel()
    if let redirect = self.redirects.removeValue(forKey: route) {
      self.redirectTasks[redirect.id]?.cancel()
    }
    self.releaseRedirect(route)
  }

  private func resolveEmailRedirect(
    _ url: URL, route: UUID, perform: @escaping ActionHandler
  ) {
    let session = self.session
    if let pending = self.redirects[route], pending.url == url, pending.session == session { return }
    self.release(route: route)
    let id = UUID()
    let releaseRedirect = self.releaseRedirect
    let firstRedirect = self.firstRedirect
    self.redirects[route] = (url, session, id)
    self.redirectTasks[id] = Task { [weak self] in
      defer {
        self?.redirectTasks[id] = nil
        if self?.redirects[route]?.id == id {
          self?.redirects[route] = nil
          releaseRedirect(route)
        }
      }
      do {
        let destination = try await firstRedirect(url, route)
        guard let self, self.redirects[route]?.id == id, let destination else { return }
        try self.requireCurrent(session)
        self.redirects[route] = nil
        releaseRedirect(route)
        self.route(url: destination, route: route, perform: perform)
      } catch { /* Failed or cancelled redirects do not navigate. */ }
    }
  }

  private func presentDestination(
    _ request: Task<DeepLinkDestination?, Error>, route: UUID,
    onDestination: @escaping @MainActor (DeepLinkDestination) -> Void
  ) {
    let session = self.session
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

  private func cancelPresentation(route: UUID) {
    self.presentations.removeValue(forKey: route)?.task.cancel()
  }

  private func makeDelivery(for route: UUID, perform: @escaping ActionHandler) -> @MainActor (Action) -> Void {
    let id = UUID()
    let session = self.session
    self.deliveryIDs[route] = id
    let validate: @MainActor () -> Bool = { [weak self] in
      guard let self else { return false }
      return self.deliveryIDs[route] == id && self.session == session
    }
    return { action in
      guard validate() else { return }
      perform(Delivery(action, validate: validate))
    }
  }

  public func reset() {
    let routes = Set(self.destinations.keys).union(self.presentations.keys)
      .union(self.redirects.keys).union(self.deliveryIDs.keys)
    for route in routes {
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

extension DeepLinkDestination {
  @MainActor
  func makeViewController(
    isLoggedIn: Bool,
    projectPageComposition: ProjectPageComposition
  ) -> UINavigationController? {
    switch self {
    case let .survey(url):
      let controller = PledgeManagerWebViewController.configuredWith(
        url: url,
        composition: projectPageComposition
      )
      let navigation = UINavigationController(rootViewController: controller)
      navigation.modalPresentationStyle = .pageSheet
      return navigation
    case let .project(project):
      return ProjectDeepLink.viewController(
        project,
        isLoggedIn: isLoggedIn,
        composition: projectPageComposition
      )
    case .discovery, .message:
      return nil
    }
  }
}

/// Pure UIKit composition from one fully resolved destination.
@MainActor
private enum ProjectDeepLink {
  static func viewController(
    _ destination: ProjectDetailsFeature.LinkContext,
    isLoggedIn: Bool,
    composition: ProjectPageComposition
  ) -> UINavigationController? {
    let project = destination.project
    let page = ProjectPageViewController.configuredWith(
      projectOrParam: .left(project), refInfo: destination.refInfo,
      secretRewardToken: destination.secretRewardToken,
      composition: composition
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
      let controller = ManagePledgeViewController.instantiate(
        composition: composition.managePledge
      )
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
