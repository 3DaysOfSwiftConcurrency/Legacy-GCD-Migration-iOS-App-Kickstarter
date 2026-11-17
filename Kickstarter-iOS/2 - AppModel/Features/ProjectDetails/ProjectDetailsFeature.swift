import Foundation
import GraphAPI
import KsApi

/// The API substitution boundary; one instance captures the service for a whole load.
@MainActor
public protocol ProjectDetailsProvider: Sendable {
  func recordAttribution(input: GraphAPI.CreateAttributionEventInput) async throws
  func relatedProjects(projectID: String) async throws -> [ProjectCardProperties]
  func enroll(token: String, param: Param) async throws
  func project(param: Param, richText: Bool) async throws -> Project.ProjectPamphletData
  func backing(id: Int) async throws -> ProjectAndBackingEnvelope
  func rewards(projectID: Int) async throws -> [Reward]
  func base(param: Param) async throws -> Project
  func extras(param: Param, richText: Bool) async throws -> ProjectPageExtraProperties
}

@MainActor
public struct AsyncProjectDetailsProvider: ProjectDetailsProvider {
  private let service: any ServiceType

  public init(service: any ServiceType) { self.service = service }
  public func recordAttribution(input: GraphAPI.CreateAttributionEventInput) async throws {
    try await self.service.recordProjectAttribution(input: input)
  }
  public func relatedProjects(projectID: String) async throws -> [ProjectCardProperties] {
    let response = try await self.service.relatedProjects(projectID: projectID)
    return response.compactMap { ProjectCardProperties($0) }
  }

  public func enroll(token: String, param: Param) async throws {
    try await self.service.enrollProjectSecretReward(token: token, param: param)
  }

  public func project(param: Param, richText: Bool) async throws -> Project.ProjectPamphletData {
    try await self.service.projectDetails(param: param, includeStoryRichText: richText)
  }

  public func backing(id: Int) async throws -> ProjectAndBackingEnvelope {
    try await self.service.projectDetailsBacking(id: id)
  }

  public func rewards(projectID: Int) async throws -> [Reward] {
    try await self.service.projectDetailsRewards(projectID: projectID)
  }

  public func base(param: Param) async throws -> Project {
    try await self.service.projectDetailsBase(param: param)
  }

  public func extras(param: Param, richText: Bool) async throws -> ProjectPageExtraProperties {
    try await self.service.projectDetailsExtras(param: param, includeStoryRichText: richText)
  }
}

/// Owns complete project-detail loading, including enrollment, backing and rewards.
/// Routes are independent (a related project may open above an existing page).
/// Within a route, equivalent loads share work; refresh after a mutation replaces
/// it. Cancellation invalidates publication even if a provider completes late.
@MainActor
public final class ProjectDetailsFeature {
  public struct Analytics {
    let projectViewed: @MainActor (Project, RefTag?) -> Void
    let blockInitiated: @MainActor (Project, String) -> Void
    let blockConfirmed: @MainActor (Project, String) -> Void
    let pledgeCTATapped: @MainActor (PledgeStateCTAType, Project) -> Void

    public init(
      projectViewed: @escaping @MainActor (Project, RefTag?) -> Void = { _, _ in },
      blockInitiated: @escaping @MainActor (Project, String) -> Void = { _, _ in },
      blockConfirmed: @escaping @MainActor (Project, String) -> Void = { _, _ in },
      pledgeCTATapped: @escaping @MainActor (PledgeStateCTAType, Project) -> Void = { _, _ in }
    ) {
      self.projectViewed = projectViewed
      self.blockInitiated = blockInitiated
      self.blockConfirmed = blockConfirmed
      self.pledgeCTATapped = pledgeCTATapped
    }
  }

  public struct Platform {
    let serverConfig: @MainActor () -> any ServerConfigType
    let prepareWebRequest: @MainActor (URL) -> URLRequest
    let cookieStorage: @MainActor () -> any HTTPCookieStorageProtocol
    let dateType: @MainActor () -> DateProtocol.Type
    let responseDelaySeconds: @MainActor () -> TimeInterval
    let recordThirdPartyEvent: @MainActor (KsApi.TriggerThirdPartyEventInput) -> Void

    public init(
      serverConfig: @escaping @MainActor () -> any ServerConfigType,
      prepareWebRequest: @escaping @MainActor (URL) -> URLRequest,
      cookieStorage: @escaping @MainActor () -> any HTTPCookieStorageProtocol,
      dateType: @escaping @MainActor () -> DateProtocol.Type,
      responseDelaySeconds: @escaping @MainActor () -> TimeInterval,
      recordThirdPartyEvent: @escaping @MainActor (KsApi.TriggerThirdPartyEventInput) -> Void
    ) {
      self.serverConfig = serverConfig
      self.prepareWebRequest = prepareWebRequest
      self.cookieStorage = cookieStorage
      self.dateType = dateType
      self.responseDelaySeconds = responseDelaySeconds
      self.recordThirdPartyEvent = recordThirdPartyEvent
    }
  }

  let platform: Platform

  /// Project-page links use the same configured web host as project detail requests.
  public var webBaseURL: URL { self.platform.serverConfig().webBaseUrl }
  public func helpType(for url: URL) -> HelpType? {
    HelpType.helpType(from: url, baseURL: self.webBaseURL)
  }
  public func helpURL(_ type: HelpType) -> String? {
    type.url(withBaseUrl: self.webBaseURL)?.absoluteString
  }
  public func recordThirdPartyEvent(_ input: KsApi.TriggerThirdPartyEventInput) {
    self.platform.recordThirdPartyEvent(input)
  }
  public func redemptionURL(for project: Project) -> String {
    self.webBaseURL.absoluteString + project.redemptionPageUrl
  }
  public let discussionFeature: DiscussionFeature
  public let sessionFeature: SessionFeature
  private let analytics: Analytics
  private let projectViewContext: @MainActor () -> (advertisingID: String, platformVersion: String)?
  private var attributionRoutes: [UUID: Task<Void, Error>] = [:]
  private var attributionOperations: [UUID: Task<Void, Error>] = [:]

  public func storeReferral(for project: Project, fallback: RefTag?) {
    let storage = self.platform.cookieStorage()
    guard let tag = cookieRefTagFor(project: project, cookies: storage.cookies) ?? fallback,
          let cookie = cookieFrom(refTag: tag, project: project, dateType: self.platform.dateType()) else { return }
    storage.setCookie(cookie)
  }

  /// One admitted page-view event per route, including after failure. Repeated
  /// callbacks share its task; there is no automatic retry or global deduplication.
  /// Once sent, the event settles independently of the screen's lifetime.
  @discardableResult
  public func recordAttribution(
    route: UUID, projectID: String, properties: String?
  ) -> Task<Void, Error> {
    if let existing = self.attributionRoutes[route] { return existing }
    let userID = self.sessionFeature.currentUser?.id
    let generation = self.sessionFeature.generation
    let provider = self.makeProvider()
    let id = UUID()
    let input = GraphAPI.CreateAttributionEventInput(
      eventName: AttributionTracking.AttributionEvent.projectPageViewed.rawValue,
      eventProperties: .someOrNil(properties), projectId: .someOrNil(projectID)
    )
    let task = Task { [self] in
      defer { self.attributionOperations[id] = nil }
      guard self.sessionFeature.isCurrent(userID: userID, generation: generation) else {
        throw CancellationError()
      }
      try await provider.recordAttribution(input: input)
    }
    self.attributionRoutes[route] = task
    self.attributionOperations[id] = task
    return task
  }

  public func waitForAttribution() async {
    while !self.attributionOperations.isEmpty {
      for task in Array(self.attributionOperations.values) { _ = await task.result }
    }
  }

  public struct RelatedSnapshot {
    public fileprivate(set) var projectID: String?
    public fileprivate(set) var projects: [ProjectCardProperties] = []
    public fileprivate(set) var isLoading = false
    public fileprivate(set) var hasLoaded = false
    public fileprivate(set) var error: ErrorEnvelope?
  }

  private struct RequestSession: Equatable {
    let userID: Int?
    let generation: Int

    @MainActor init(_ session: SessionFeature) {
      self.userID = session.currentUser?.id
      self.generation = session.generation
    }

    @MainActor func isCurrent(in session: SessionFeature) -> Bool {
      session.isCurrent(userID: self.userID, generation: self.generation)
    }
  }

  private final class RelatedPage {
    let session: RequestSession
    var snapshot = RelatedSnapshot()
    var request: (id: UUID, projectID: String, task: Task<Void, Never>)?

    init(session: RequestSession) { self.session = session }
  }

  private var relatedPages: [UUID: RelatedPage] = [:]

  public func relatedSnapshot(for route: UUID) -> RelatedSnapshot {
    guard let page = self.relatedPages[route], page.session.isCurrent(in: self.sessionFeature) else {
      return RelatedSnapshot()
    }
    return page.snapshot
  }

  public func loadRelated(route: UUID, projectID: String) async {
    guard !Task.isCancelled else { return }
    await self.requestRelated(route: route, projectID: projectID).value
  }

  func waitForRelatedProjects(route: UUID) async {
    await self.relatedPages[route]?.request?.task.value
  }

  /// Recommendations are independent of the project's required dependencies.
  /// Equivalent requests share work; a changed project replaces only this route.
  @discardableResult
  public func requestRelated(route: UUID, projectID: String) -> Task<Void, Never> {
    let sessionFeature = self.sessionFeature
    let session = RequestSession(sessionFeature)
    if let old = self.relatedPages[route], old.session != session { self.releaseRelated(route: route) }
    let page = self.relatedPages[route] ?? RelatedPage(session: session)
    self.relatedPages[route] = page
    if let request = page.request, request.projectID == projectID {
      return request.task
    }
    page.request?.task.cancel()
    let requestID = UUID()
    let provider = self.makeProvider()
    if page.snapshot.projectID != projectID { page.snapshot = RelatedSnapshot(projectID: projectID) }
    page.snapshot.isLoading = true
    page.snapshot.error = nil
    let task = Task { [weak self] in
      defer {
        if page.request?.id == requestID {
          page.request = nil
          page.snapshot.isLoading = false
          if !Task.isCancelled, session.isCurrent(in: sessionFeature),
             let self, self.relatedPages[route] === page {
            self.emit(.relatedChanged(route))
          }
        }
      }
      do {
        try Self.checkSession(session, sessionFeature: sessionFeature)
        let projects = try await provider.relatedProjects(projectID: projectID)
        try Self.checkSession(session, sessionFeature: sessionFeature)
        guard let self, self.relatedPages[route]?.request?.id == requestID else { return }
        page.snapshot.projects = projects
        page.snapshot.hasLoaded = true
      } catch is CancellationError {
        // Keep cancellation distinct from the existing visible error state.
      } catch {
        guard !Task.isCancelled, session.isCurrent(in: sessionFeature),
              let self, self.relatedPages[route]?.request?.id == requestID else { return }
        let failure = (error as? ErrorEnvelope) ?? ErrorEnvelope.couldNotParseJSON
        page.snapshot.error = failure
      }
    }
    page.request = (requestID, projectID, task)
    return task
  }

  public func releaseRelated(route: UUID) {
    let page = self.relatedPages.removeValue(forKey: route)
    page?.request?.task.cancel()
    page?.request = nil
  }

  public struct Snapshot {
    public fileprivate(set) var project: Project?
    public fileprivate(set) var isLoading = false
    public fileprivate(set) var error: ErrorEnvelope?
  }

  private struct Identity: Equatable {
    let param: Param
    let token: String?
    let session: RequestSession
    let fast: Bool
    let richText: Bool
  }

  private final class Page {
    let session: RequestSession
    var snapshot = Snapshot()
    var request: (id: UUID, identity: Identity, task: Task<Void, Never>)?

    init(session: RequestSession) { self.session = session }
  }

  private enum ProjectPart: Sendable {
    case base(Project)
    case extras(ProjectPageExtraProperties)
  }

  private var pages: [UUID: Page] = [:]
  private let makeProvider: @MainActor () -> any ProjectDetailsProvider
  private let settingsFeature: SettingsFeature
  private let useFastLoading: @MainActor () -> Bool
  private let sleep: @MainActor (TimeInterval) async throws -> Void
  internal enum Update {
    case loading(UUID, Bool)
    case completion(UUID, Result<Project, ErrorEnvelope>)
    case relatedChanged(UUID)
  }
  private var observers: [(id: UUID, callback: (Update) -> Void)] = []
  internal func observe(_ callback: @escaping (Update) -> Void) -> MainActorObservation {
    let id = UUID()
    self.observers.append((id, callback))
    return MainActorObservation { [weak self] in self?.observers.removeAll { $0.id == id } }
  }
  private func emit(_ update: Update) {
    for observer in self.observers { observer.callback(update) }
  }

  var includesRichTextStory: Bool { self.settingsFeature.isStatsigEnabled(.projectStoryRichText) }

  public init(
    platform: Platform,
    sessionFeature: SessionFeature,
    settingsFeature: SettingsFeature,
    discussionFeature: DiscussionFeature,
    makeProvider: @escaping @MainActor () -> any ProjectDetailsProvider,
    useFastLoading: @escaping @MainActor () -> Bool,
    analytics: Analytics = Analytics(),
    projectViewContext: @escaping @MainActor () -> (advertisingID: String, platformVersion: String)? = { nil },
    sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { seconds in
      if seconds.isInfinite { try await Task.sleep(nanoseconds: UInt64.max) }
      else if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
      try Task.checkCancellation()
    }
  ) {
    self.platform = platform
    self.discussionFeature = discussionFeature
    self.sessionFeature = sessionFeature
    self.settingsFeature = settingsFeature
    self.makeProvider = makeProvider
    self.useFastLoading = useFastLoading
    self.analytics = analytics
    self.projectViewContext = projectViewContext
    self.sleep = sleep
  }

  public func recordProjectViewed(_ project: Project, refTag: RefTag?) {
    self.analytics.projectViewed(project, refTag)
    guard let context = self.projectViewContext() else { return }
    var extInfo = Array(repeating: "", count: 16)
    extInfo[0] = "i2"
    extInfo[4] = context.platformVersion
    self.recordThirdPartyEvent(.init(
      deviceId: context.advertisingID,
      eventName: ThirdPartyEventInputName.ProjectPageViewed.rawValue,
      projectId: String(project.id),
      pledgeAmount: nil,
      shipping: nil,
      transactionId: nil,
      userId: self.sessionFeature.currentUser.map { String($0.id) } ?? "",
      appData: .init(
        advertiserTrackingEnabled: true,
        applicationTrackingEnabled: true,
        extinfo: extInfo
      ),
      clientMutationId: ""
    ))
  }

  public func trackBlockInitiated(project: Project, targetUserID: String) {
    self.analytics.blockInitiated(project, targetUserID)
  }

  public func trackBlockConfirmed(project: Project, targetUserID: String) {
    self.analytics.blockConfirmed(project, targetUserID)
  }

  public var currentUser: User? { self.sessionFeature.currentUser }

  public func trackPledgeCTATapped(state: PledgeStateCTAType, project: Project) {
    self.analytics.pledgeCTATapped(state, project)
  }

  public func snapshot(for route: UUID) -> Snapshot {
    guard let page = self.pages[route], page.session.isCurrent(in: self.sessionFeature) else {
      return Snapshot()
    }
    return page.snapshot
  }

  public func load(route: UUID, param: Param, secretRewardToken: String? = nil, force: Bool = false) async {
    guard !Task.isCancelled else { return }
    await self.requestLoad(route: route, param: param, secretRewardToken: secretRewardToken, force: force)
      .value
  }

  @discardableResult
  public func requestLoad(
    route: UUID, param: Param, secretRewardToken: String? = nil, force: Bool = false
  ) -> Task<Void, Never> {
    let identity = Identity(
      param: param, token: secretRewardToken, session: RequestSession(self.sessionFeature),
      fast: self.useFastLoading(), richText: self.includesRichTextStory
    )
    if let old = self.pages[route], old.session != identity.session {
      old.request?.task.cancel()
      self.pages[route] = nil
    }
    let page = self.pages[route] ?? Page(session: identity.session)
    self.pages[route] = page
    if !force, let request = page.request, request.identity == identity { return request.task }
    page.request?.task.cancel()
    let requestID = UUID()
    let provider = self.makeProvider()
    let sessionFeature = self.sessionFeature
    let delay = self.platform.responseDelaySeconds()
    let sleep = self.sleep
    page.snapshot.isLoading = true
    page.snapshot.error = nil
    let task = Task { [weak self] in
      defer {
        if let self, self.pages[route]?.request?.id == requestID {
          page.request = nil
          page.snapshot.isLoading = false
          self.emit(.loading(route, false))
        }
      }
      do {
        try Self.checkSession(identity.session, sessionFeature: sessionFeature)
        // Keep enrollment before reads, including its existing configured delay.
        if identity.session.userID != nil, let token = identity.token, !token.isEmpty {
          try await provider.enroll(token: token, param: param)
          try await sleep(delay)
          try Self.checkSession(identity.session, sessionFeature: sessionFeature)
        }
        let project: Project
        if identity.fast {
          // Observe whichever dependency finishes first, so either failure
          // cancels its sibling rather than waiting in a fixed await order.
          project = try await withThrowingTaskGroup(of: ProjectPart.self) { group in
            group.addTask { .base(try await provider.base(param: param)) }
            group.addTask { .extras(try await provider.extras(param: param, richText: identity.richText)) }
            var base: Project?
            var extras: ProjectPageExtraProperties?
            for try await part in group {
              switch part {
              case let .base(project): base = project
              case let .extras(properties): extras = properties
              }
            }
            guard let base, let extras else { throw ErrorEnvelope.couldNotParseJSON }
            return extras.addExtraProperties(toProject: base)
          }
        } else {
          let pamphlet = try await provider.project(param: param, richText: identity.richText)
          try Self.checkSession(identity.session, sessionFeature: sessionFeature)
          var loaded = pamphlet.project
          if let backingID = pamphlet.backingId {
            let envelope = try await provider.backing(id: backingID)
            try Self.checkSession(identity.session, sessionFeature: sessionFeature)
            loaded.personalization.backing = envelope.backing
            loaded.personalization.isBacking = true
          }
          let rewards = try await provider.rewards(projectID: loaded.id)
          try Self.checkSession(identity.session, sessionFeature: sessionFeature)
          // Preserve the synthetic no-reward entry and shipping-rule data.
          loaded.rewardData.rewards = Array(loaded.rewardData.rewards.prefix(1)) + rewards
          project = loaded
        }
        try await sleep(delay)
        try Self.checkSession(identity.session, sessionFeature: sessionFeature)
        guard let self, self.pages[route]?.request?.id == requestID else { return }
        page.snapshot.project = project
        self.emit(.completion(route, .success(project)))
      } catch is CancellationError {
        // Cancellation is not a product failure and never publishes stale data.
      } catch {
        guard !Task.isCancelled, identity.session.isCurrent(in: sessionFeature),
              let self, self.pages[route]?.request?.id == requestID else { return }
        let failure = (error as? ErrorEnvelope) ?? ErrorEnvelope.couldNotParseJSON
        page.snapshot.error = failure
        self.emit(.completion(route, .failure(failure)))
      }
    }
    page.request = (requestID, identity, task)
    self.emit(.loading(route, true))
    return task
  }

  public func cancel(route: UUID) {
    guard let page = self.pages[route] else { return }
    let task = page.request?.task
    page.request = nil
    page.snapshot.isLoading = false
    task?.cancel()
    self.emit(.loading(route, false))
  }

  public func release(route: UUID) {
    self.releaseRelated(route: route)
    self.attributionRoutes[route] = nil
    self.cancel(route: route)
    self.pages.removeValue(forKey: route)
  }

  private static func checkSession(_ session: RequestSession, sessionFeature: SessionFeature) throws {
    try Task.checkCancellation()
    guard session.isCurrent(in: sessionFeature) else { throw CancellationError() }
  }
}
