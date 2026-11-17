import Foundation
import KsApi

/// Retains one remote-configuration activation at a time for the active SDK client.
///
/// This is application infrastructure rather than a product feature. `AppModel` receives
/// the application lifecycle signal and owns this service at the composition boundary.
@MainActor
public final class RemoteConfigurationService {
  private var request: (client: ObjectIdentifier, id: UUID, task: Task<Void, Error>)?

  public init() {}

  @discardableResult public func activate(
    client: AnyObject, operation: @escaping @MainActor () async throws -> Void
  ) -> Task<Void, Error> {
    let clientID = ObjectIdentifier(client)
    if let request = self.request, request.client == clientID { return request.task }
    self.request?.task.cancel()
    let id = UUID()
    let task = Task { [self] in
      defer { if self.request?.id == id { self.request = nil } }
      try Task.checkCancellation()
      try await operation()
      try Task.checkCancellation()
      guard self.request?.id == id else { throw CancellationError() }
    }
    self.request = (clientID, id, task)
    return task
  }
}

/// Owns the application-configuration read triggered by launch and foreground signals.
///
/// Configuration is shared application infrastructure: it is not a screen concern and
/// it is not a product feature. A session reset replaces any in-flight read.
@MainActor
public final class ApplicationConfigurationService {
  private let load: @MainActor () async throws -> Config
  private var request: (id: UUID, task: Task<Config, Error>)?

  public init(load: @escaping @MainActor () async throws -> Config) {
    self.load = load
  }

  public func configuration() async throws -> Config {
    try Task.checkCancellation()
    let value = try await self.requestConfiguration().value
    try Task.checkCancellation()
    return value
  }

  @discardableResult public func requestConfiguration() -> Task<Config, Error> {
    if let request = self.request { return request.task }
    let id = UUID()
    let load = self.load
    let task = Task { [self] in
      defer { if self.request?.id == id { self.request = nil } }
      try Task.checkCancellation()
      let value = try await load()
      try Task.checkCancellation()
      guard self.request?.id == id else { throw CancellationError() }
      return value
    }
    self.request = (id, task)
    return task
  }

  public func reset() {
    self.request?.task.cancel()
    self.request = nil
  }
}

/// Serializes device-token registration admitted by the application boundary.
@MainActor
public final class DevicePushRegistrationService {
  private let register: @MainActor (String) async throws -> Void
  private var generation = 0
  private var tail: (token: String, generation: Int, id: UUID, task: Task<String, Error>)?

  public init(register: @escaping @MainActor (String) async throws -> Void) {
    self.register = register
  }

  @discardableResult public func request(token: String) -> Task<String, Error> {
    let generation = self.generation
    if let tail = self.tail, tail.token == token, tail.generation == generation { return tail.task }
    let previous = self.tail?.task
    let id = UUID()
    let register = self.register
    let task = Task { [self] in
      defer { if self.tail?.id == id { self.tail = nil } }
      if let previous { _ = await previous.result }
      try Task.checkCancellation()
      guard self.generation == generation else { throw CancellationError() }
      try await register(token)
      try Task.checkCancellation()
      guard self.generation == generation, self.tail?.id == id else { throw CancellationError() }
      return token
    }
    self.tail = (token, generation, id, task)
    return task
  }

  public func sessionChanged() { self.generation += 1 }
}

/// Application composition root. Features own shared state and directly awaitable workflows.
@MainActor
public final class AppModel {
  public static let shared = AppModel.live()

  private var hasLaunched: Bool

  public let developerExamplesFeature: DeveloperExamplesFeature
  public let onboardingFeature: OnboardingFeature
  public let connectivityService: ConnectivityService
  public let remoteConfigurationService: RemoteConfigurationService
  public let applicationConfigurationService: ApplicationConfigurationService
  public let devicePushRegistrationService: DevicePushRegistrationService
  public let appLifecycleFeature: AppLifecycleFeature
  public let creatorDraftsFeature: CreatorDraftsFeature
  public let recommendationsFeature: RecommendationsFeature
  public let projectReportingFeature: ProjectReportingFeature
  public let friendsFeature: FriendsFeature
  public let pledgedProjectsFeature: PledgedProjectsFeature
  public let pledgeFeature: PledgeFeature
  public let paymentsFeature: PaymentsFeature
  public let messagingFeature: MessagingFeature
  public let sessionFeature: SessionFeature
  public let authenticationFeature: AuthenticationFeature
  public let settingsFeature: SettingsFeature
  public let activityFeature: ActivityFeature
  public let profileFeature: ProfileFeature
  public let searchFeature: SearchFeature
  public let discoveryFeature: DiscoveryFeature
  public let projectDetailsFeature: ProjectDetailsFeature
  public let rewardsFeature: RewardsFeature
  public let discussionFeature: DiscussionFeature
  public let projectMediaFeature: ProjectMediaFeature

  public init(
    developerExamplesFeature: DeveloperExamplesFeature,
    onboardingFeature: OnboardingFeature,
    connectivityService: ConnectivityService = ConnectivityService(),
    remoteConfigurationService: RemoteConfigurationService = RemoteConfigurationService(),
    applicationConfigurationService: ApplicationConfigurationService = ApplicationConfigurationService(
      load: { try await AppEnvironment.current.apiService.applicationConfiguration() }
    ),
    devicePushRegistrationService: DevicePushRegistrationService = DevicePushRegistrationService(
      register: { try await AppEnvironment.current.apiService.registerApplicationPushToken($0) }
    ),
    appLifecycleFeature: AppLifecycleFeature,
    creatorDraftsFeature: CreatorDraftsFeature,
    recommendationsFeature: RecommendationsFeature,
    projectReportingFeature: ProjectReportingFeature,
    friendsFeature: FriendsFeature,
    pledgedProjectsFeature: PledgedProjectsFeature,
    pledgeFeature: PledgeFeature,
    paymentsFeature: PaymentsFeature,
    messagingFeature: MessagingFeature,
    sessionFeature: SessionFeature,
    authenticationFeature: AuthenticationFeature,
    settingsFeature: SettingsFeature,
    activityFeature: ActivityFeature,
    profileFeature: ProfileFeature,
    searchFeature: SearchFeature,
    discoveryFeature: DiscoveryFeature,
    projectDetailsFeature: ProjectDetailsFeature,
    rewardsFeature: RewardsFeature,
    discussionFeature: DiscussionFeature,
    projectMediaFeature: ProjectMediaFeature
  ) {
    self.developerExamplesFeature = developerExamplesFeature
    self.onboardingFeature = onboardingFeature
    self.connectivityService = connectivityService
    self.remoteConfigurationService = remoteConfigurationService
    self.applicationConfigurationService = applicationConfigurationService
    self.devicePushRegistrationService = devicePushRegistrationService
    self.appLifecycleFeature = appLifecycleFeature
    self.creatorDraftsFeature = creatorDraftsFeature
    self.recommendationsFeature = recommendationsFeature
    self.projectReportingFeature = projectReportingFeature
    self.friendsFeature = friendsFeature
    self.pledgedProjectsFeature = pledgedProjectsFeature
    self.pledgeFeature = pledgeFeature
    self.paymentsFeature = paymentsFeature
    self.messagingFeature = messagingFeature
    self.sessionFeature = sessionFeature
    self.authenticationFeature = authenticationFeature
    self.settingsFeature = settingsFeature
    self.activityFeature = activityFeature
    self.profileFeature = profileFeature
    self.searchFeature = searchFeature
    self.discoveryFeature = discoveryFeature
    self.projectDetailsFeature = projectDetailsFeature
    self.rewardsFeature = rewardsFeature
    self.discussionFeature = discussionFeature
    self.projectMediaFeature = projectMediaFeature
    self.hasLaunched = false
  }

  /// Starts shared launch work once without making UI construction wait for it.
  public func applicationDidFinishLaunching() async {
    guard !self.hasLaunched else { return }
    self.hasLaunched = true
    _ = try? await self.applicationConfigurationService.configuration()
  }

  @discardableResult public func requestApplicationConfiguration() -> Task<Config, Error> {
    self.applicationConfigurationService.requestConfiguration()
  }

  @discardableResult public func requestDevicePushRegistration(token: String) -> Task<String, Error> {
    self.devicePushRegistrationService.request(token: token)
  }

  @discardableResult public func requestRemoteConfiguration(
    client: AnyObject, activate: @escaping @MainActor () async throws -> Void
  ) -> Task<Void, Error> {
    self.remoteConfigurationService.activate(client: client, operation: activate)
  }

  public func sessionChanged() {
    self.sessionFeature.sessionChanged()
    self.authenticationFeature.resetEmailRedirects()
    self.discoveryFeature.resetRecommendationAvailability()
    self.applicationConfigurationService.reset()
    self.devicePushRegistrationService.sessionChanged()
    self.developerExamplesFeature.reset()
    self.appLifecycleFeature.reset()
    self.creatorDraftsFeature.reset()
    self.recommendationsFeature.reset()
    self.friendsFeature.reset()
    self.activityFeature.reset()
    self.profileFeature.reset()
    self.messagingFeature.reset()
    self.pledgeFeature.reset()
    self.pledgedProjectsFeature.reset()
  }

  /// Installs the device visitor identity for both web and API domains.
  public func installVisitorCookies() {
    let uuidString = (AppEnvironment.current.device.identifierForVendor ?? UUID()).uuidString
    let server = AppEnvironment.current.apiService.serverConfig
    [HTTPCookie?](arrayLiteral:
      HTTPCookie(properties: [
        .name: "vis", .value: uuidString, .domain: server.webBaseUrl.host as Any,
        .path: "/", .version: 0, .expires: Date.distantFuture, .secure: true
      ]),
      HTTPCookie(properties: [
        .name: "vis", .value: uuidString, .domain: server.apiBaseUrl.host as Any,
        .path: "/", .version: 0, .expires: Date.distantFuture, .secure: true
      ])
    ).compact().forEach(AppEnvironment.current.cookieStorage.setCookie)
  }

  public static func live() -> AppModel {
    let searchProvider = AsyncSearchProjectsProvider()
    let sessionFeature =
      SessionFeature(makeProvider: { AsyncSessionProvider(service: AppEnvironment.current.apiService) })
    let activityFeature = ActivityFeature(
      sessionFeature: sessionFeature,
      makeProvider: { AsyncActivityProvider(service: AppEnvironment.current.apiService) }
    )
    let profileFeature = ProfileFeature(
      sessionFeature: sessionFeature,
      makeProvider: { AsyncProfileProvider(service: AppEnvironment.current.apiService) }
    )
    let settingsFeature = SettingsFeature(sessionFeature: sessionFeature, makeProvider: {
        AsyncAccountPreferencesProvider(service: AppEnvironment.current.apiService)
      })
    let messagingFeature = MessagingFeature(sessionFeature: sessionFeature, makeProvider: {
      AsyncMessagingProvider(service: AppEnvironment.current.apiService)
    })
    let discussionFeature = DiscussionFeature(sessionFeature: sessionFeature, makeProvider: {
      AsyncDiscussionProvider(service: AppEnvironment.current.apiService)
    })
    return AppModel(
      developerExamplesFeature: DeveloperExamplesFeature(sessionFeature: sessionFeature, makeProvider: {
        AsyncDeveloperExamplesProvider(service: AppEnvironment.current.apiService)
      }),
      onboardingFeature: OnboardingFeature(),
      connectivityService: ConnectivityService(makeMonitor: { SystemReachabilityMonitor() }),
      appLifecycleFeature: AppLifecycleFeature(sessionFeature: sessionFeature,
        messagingFeature: messagingFeature, makeProvider: { AsyncAppLifecycleProvider(service: AppEnvironment.current.apiService) }),
      creatorDraftsFeature: CreatorDraftsFeature(sessionFeature: sessionFeature, makeProvider: {
        AsyncCreatorDraftsProvider(service: AppEnvironment.current.apiService)
      }),
      recommendationsFeature: RecommendationsFeature(settingsFeature: settingsFeature, makeProvider: {
        AsyncRecommendationsProvider(service: AppEnvironment.current.apiService)
      }),
      projectReportingFeature: ProjectReportingFeature(sessionFeature: sessionFeature, makeProvider: {
        AsyncProjectReportingProvider(service: AppEnvironment.current.apiService)
      }),
      friendsFeature: FriendsFeature(sessionFeature: sessionFeature, makeProvider: {
        AsyncFriendsProvider(service: AppEnvironment.current.apiService)
      }),
      pledgedProjectsFeature: PledgedProjectsFeature(sessionFeature: sessionFeature, makeProvider: {
        AsyncPledgedProjectsProvider(service: AppEnvironment.current.apiService)
      }),
      pledgeFeature: PledgeFeature(sessionFeature: sessionFeature, makeProvider: {
        AsyncPledgeProvider(service: AppEnvironment.current.apiService)
      }),
      paymentsFeature: PaymentsFeature(sessionFeature: sessionFeature, makeProvider: {
        AsyncPaymentsProvider(service: AppEnvironment.current.apiService)
      }),
      messagingFeature: messagingFeature,
      sessionFeature: sessionFeature,
      authenticationFeature: AuthenticationFeature(sessionFeature: sessionFeature, makeProvider: {
        AsyncAuthenticationProvider(service: AppEnvironment.current.apiService)
      }),
      settingsFeature: settingsFeature,
      activityFeature: activityFeature,
      profileFeature: profileFeature,
      searchFeature: SearchFeature(provider: searchProvider, lookupProvider: AsyncSearchLookupProvider()),
      discoveryFeature: DiscoveryFeature(
        provider: AsyncDiscoveryProvider(),
        currentUser: { sessionFeature.currentUser }
      ),
      projectDetailsFeature: ProjectDetailsFeature(sessionFeature: sessionFeature, discussionFeature: discussionFeature, makeProvider: {
        AsyncProjectDetailsProvider(service: AppEnvironment.current.apiService)
      }),
      rewardsFeature: RewardsFeature(sessionFeature: sessionFeature, makeProvider: {
        AsyncRewardsProvider(service: AppEnvironment.current.apiService)
      }),
      discussionFeature: discussionFeature,
      projectMediaFeature: ProjectMediaFeature(sessionFeature: sessionFeature, makeProvider: {
        AsyncProjectMediaProvider(service: AppEnvironment.current.apiService)
      })
    )
  }
}
