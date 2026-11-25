import Experimentation
import Foundation
import KsApi
import Prelude

extension ProjectDetailsFeature.Platform {
  @MainActor
  static func live() -> Self {
    Self(
      serverConfig: { AppEnvironment.current.apiService.serverConfig },
      prepareWebRequest: { AppEnvironment.current.apiService.preparedRequest(forURL: $0) },
      cookieStorage: { AppEnvironment.current.cookieStorage },
      dateType: { AppEnvironment.current.dateType },
      responseDelaySeconds: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds },
      recordThirdPartyEvent: { _ = AppEnvironment.current.apiService.prepareThirdPartyEvent(input: $0) }
    )
  }
}

extension RewardsFeature.Platform {
  @MainActor
  static func live() -> Self {
    Self(
      configuredCountry: { AppEnvironment.current.config?.countryCode },
      country: { AppEnvironment.current.countryCode },
      now: { AppEnvironment.current.dateType.init().timeIntervalSince1970 },
      responseDelaySeconds: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds },
      recordThirdPartyEvent: { _ = AppEnvironment.current.apiService.prepareThirdPartyEvent(input: $0) }
    )
  }
}

extension RecommendationsFeature.Platform {
  @MainActor
  static func live() -> Self {
    Self(
      promptStore: { AppEnvironment.current.userDefaults },
      responseDelaySeconds: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds },
      recordThirdPartyEvent: {
        _ = AppEnvironment.current.apiService.prepareThirdPartyEvent(input: $0)
      }
    )
  }
}

extension PledgeFeature.Platform {
  @MainActor
  static func live() -> Self {
    Self(
      serverConfig: { AppEnvironment.current.apiService.serverConfig },
      prepareWebRequest: { AppEnvironment.current.apiService.preparedRequest(forRequest: $0) },
      isPreparedWebRequest: { AppEnvironment.current.apiService.isPrepared(request: $0) },
      responseDelaySeconds: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds }
    )
  }
}

extension DiscussionFeature.Platform {
  @MainActor
  static func live() -> Self {
    Self(
      serverConfig: { AppEnvironment.current.apiService.serverConfig },
      prepareWebRequest: { AppEnvironment.current.apiService.preparedRequest(forRequest: $0) },
      optimisticCommentID: { AppEnvironment.current.uuidType.init().uuidString },
      now: { AppEnvironment.current.dateType.init().date },
      responseDelaySeconds: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds }
    )
  }
}

extension ProjectMediaFeature.SavePrompts {
  @MainActor
  static func live() -> Self {
    Self(
      tipState: {
        guard let environment = AppEnvironment.current else { return nil }
        return (
          environment.dateType.init().date,
          environment.ubiquitousStore.hasSeenSaveProjectAlert && environment.userDefaults.hasSeenSaveProjectAlert
        )
      },
      recordTip: {
        AppEnvironment.current.ubiquitousStore.hasSeenSaveProjectAlert = true
        AppEnvironment.current.userDefaults.hasSeenSaveProjectAlert = true
      },
      canShowNotification: { PushNotificationDialog.canShowDialog(for: .save) }
    )
  }
}

extension OnboardingFeature {
  static func live(
    trackingDelay: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }
  ) -> OnboardingFeature {
    OnboardingFeature(
      completionStore: { AppEnvironment.current.userDefaults },
      shouldRequestTracking: { AppEnvironment.current.appTrackingTransparency.shouldRequestAuthorizationStatus() },
      pushRegistration: { AppEnvironment.current.pushRegistrationType },
      tracking: { AppEnvironment.current.appTrackingTransparency },
      trackingDelay: trackingDelay,
      analytics: .init(
        pageViewed: { AppEnvironment.current.ksrAnalytics.trackOnboardingPageViewed(at: $0) },
        buttonTapped: { AppEnvironment.current.ksrAnalytics.trackOnboardingPageButtonTapped(context: $0, item: $1) },
        permissionsDialogViewed: { AppEnvironment.current.ksrAnalytics.trackSystemPermissionsDialogViewed(on: $0) },
        pushPermissionCompleted: {
          AppEnvironment.current.ksrAnalytics.trackPushNotificationPermissionsDialogInteraction($0, authStatus: $1)
        },
        trackingPermissionCompleted: {
          AppEnvironment.current.ksrAnalytics.trackAppTrackingTransparencyPermissionsDialogInteraction($0)
        }
      )
    )
  }
}

/// Application composition root. Features own shared state and directly awaitable workflows.
public struct ProjectPageComposition {
  public let projectDetailsFeature: ProjectDetailsFeature
  public let projectMediaFeature: ProjectMediaFeature
  public let projectReportingFeature: ProjectReportingFeature
  public let managePledge: ManagePledgeComposition

  public init(
    projectDetailsFeature: ProjectDetailsFeature,
    projectMediaFeature: ProjectMediaFeature,
    projectReportingFeature: ProjectReportingFeature,
    managePledge: ManagePledgeComposition
  ) {
    self.projectDetailsFeature = projectDetailsFeature
    self.projectMediaFeature = projectMediaFeature
    self.projectReportingFeature = projectReportingFeature
    self.managePledge = managePledge
  }
}

public struct PledgeCheckoutComposition {
  public let pledgeFeature: PledgeFeature
  public let authenticationFeature: AuthenticationFeature
  public let paymentsFeature: PaymentsFeature
  public let analytics: () -> KSRAnalytics
  public let responseDelay: @MainActor () -> TimeInterval
  public let advertisingContext: @MainActor () -> (id: String, platformVersion: String)?

  public init(
    pledgeFeature: PledgeFeature,
    authenticationFeature: AuthenticationFeature,
    paymentsFeature: PaymentsFeature,
    analytics: @escaping () -> KSRAnalytics,
    responseDelay: @escaping @MainActor () -> TimeInterval,
    advertisingContext: @escaping @MainActor () -> (id: String, platformVersion: String)?
  ) {
    self.pledgeFeature = pledgeFeature
    self.authenticationFeature = authenticationFeature
    self.paymentsFeature = paymentsFeature
    self.analytics = analytics
    self.responseDelay = responseDelay
    self.advertisingContext = advertisingContext
  }
}

public struct ActivityComposition {
  public let activityFeature: ActivityFeature
  public let friendsFeature: FriendsFeature
  public let projectPage: ProjectPageComposition

  public init(
    activityFeature: ActivityFeature,
    friendsFeature: FriendsFeature,
    projectPage: ProjectPageComposition
  ) {
    self.activityFeature = activityFeature
    self.friendsFeature = friendsFeature
    self.projectPage = projectPage
  }
}

public struct MessagingComposition {
  public let messagingFeature: MessagingFeature
  public let discussionFeature: DiscussionFeature
  public let projectPage: ProjectPageComposition

  public init(
    messagingFeature: MessagingFeature,
    discussionFeature: DiscussionFeature,
    projectPage: ProjectPageComposition
  ) {
    self.messagingFeature = messagingFeature
    self.discussionFeature = discussionFeature
    self.projectPage = projectPage
  }
}

public struct VideoFeedComposition {
  public let projectMediaFeature: ProjectMediaFeature
  public let messagingFeature: MessagingFeature
  public let projectPage: ProjectPageComposition
  public let analytics: () -> KSRAnalytics
  public let isPad: () -> Bool

  public init(
    projectMediaFeature: ProjectMediaFeature,
    messagingFeature: MessagingFeature,
    projectPage: ProjectPageComposition,
    analytics: @escaping () -> KSRAnalytics,
    isPad: @escaping () -> Bool
  ) {
    self.projectMediaFeature = projectMediaFeature
    self.messagingFeature = messagingFeature
    self.projectPage = projectPage
    self.analytics = analytics
    self.isPad = isPad
  }
}

public struct SearchComposition {
  public let searchFeature: SearchFeature
  public let sessionFeature: SessionFeature
  public let videoFeed: VideoFeedComposition

  public init(
    searchFeature: SearchFeature,
    sessionFeature: SessionFeature,
    videoFeed: VideoFeedComposition
  ) {
    self.searchFeature = searchFeature
    self.sessionFeature = sessionFeature
    self.videoFeed = videoFeed
  }
}

public struct DiscoveryComposition {
  public let discoveryFeature: DiscoveryFeature
  public let videoFeed: VideoFeedComposition
  public let curatedProjects: CuratedProjectsComposition
  public let findFriends: FindFriendsComposition
  public let cardPresentation: DiscoveryCardPresentation
  public let isPad: () -> Bool

  public init(
    discoveryFeature: DiscoveryFeature,
    videoFeed: VideoFeedComposition,
    curatedProjects: CuratedProjectsComposition,
    findFriends: FindFriendsComposition,
    cardPresentation: DiscoveryCardPresentation,
    isPad: @escaping () -> Bool
  ) {
    self.discoveryFeature = discoveryFeature
    self.videoFeed = videoFeed
    self.curatedProjects = curatedProjects
    self.findFriends = findFriends
    self.cardPresentation = cardPresentation
    self.isPad = isPad
  }
}

public struct DiscoveryCardPresentation {
  public let today: @MainActor () -> Date
  public let liveProjectDuration: @MainActor (TimeInterval) -> (duration: String, unit: String)

  public init(
    today: @escaping @MainActor () -> Date,
    liveProjectDuration: @escaping @MainActor (TimeInterval) -> (duration: String, unit: String)
  ) {
    self.today = today
    self.liveProjectDuration = liveProjectDuration
  }
}

public struct CuratedProjectsComposition {
  public let recommendationsFeature: RecommendationsFeature
  public let projectMediaFeature: ProjectMediaFeature
  public let cardPresentation: DiscoveryCardPresentation

  public init(
    recommendationsFeature: RecommendationsFeature,
    projectMediaFeature: ProjectMediaFeature,
    cardPresentation: DiscoveryCardPresentation
  ) {
    self.recommendationsFeature = recommendationsFeature
    self.projectMediaFeature = projectMediaFeature
    self.cardPresentation = cardPresentation
  }
}

public struct FindFriendsComposition {
  public let friendsFeature: FriendsFeature
  public let settingsFeature: SettingsFeature

  public init(friendsFeature: FriendsFeature, settingsFeature: SettingsFeature) {
    self.friendsFeature = friendsFeature
    self.settingsFeature = settingsFeature
  }
}

public struct SettingsComposition {
  public let settingsFeature: SettingsFeature
  public let findFriends: FindFriendsComposition
  public let notifications: SettingsNotificationsComposition

  public init(
    settingsFeature: SettingsFeature,
    findFriends: FindFriendsComposition,
    notifications: SettingsNotificationsComposition
  ) {
    self.settingsFeature = settingsFeature
    self.findFriends = findFriends
    self.notifications = notifications
  }
}

public struct SettingsNotificationsComposition {
  public let settingsFeature: SettingsFeature
  public let isVoiceOverRunning: () -> Bool

  public init(
    settingsFeature: SettingsFeature,
    isVoiceOverRunning: @escaping () -> Bool
  ) {
    self.settingsFeature = settingsFeature
    self.isVoiceOverRunning = isVoiceOverRunning
  }
}

public struct BackerDashboardComposition {
  public let profileFeature: ProfileFeature
  public let messaging: MessagingComposition
  public let settings: SettingsComposition

  public init(
    profileFeature: ProfileFeature,
    messaging: MessagingComposition,
    settings: SettingsComposition
  ) {
    self.profileFeature = profileFeature
    self.messaging = messaging
    self.settings = settings
  }
}

public struct RootTabComposition {
  public let sessionFeature: SessionFeature
  public let backerDashboard: BackerDashboardComposition
  public let activities: ActivityComposition
  public let search: SearchComposition
  public let discovery: DiscoveryComposition
  public let analytics: () -> KSRAnalytics
  public let badgePresentationDelay: () -> TimeInterval
  public let isVoiceOverRunning: () -> Bool
  public let pledgedProjects: PledgedProjectsComposition

  public init(
    sessionFeature: SessionFeature,
    backerDashboard: BackerDashboardComposition,
    activities: ActivityComposition,
    search: SearchComposition,
    discovery: DiscoveryComposition,
    analytics: @escaping () -> KSRAnalytics,
    badgePresentationDelay: @escaping () -> TimeInterval,
    isVoiceOverRunning: @escaping () -> Bool,
    pledgedProjects: PledgedProjectsComposition
  ) {
    self.sessionFeature = sessionFeature
    self.backerDashboard = backerDashboard
    self.activities = activities
    self.search = search
    self.discovery = discovery
    self.analytics = analytics
    self.badgePresentationDelay = badgePresentationDelay
    self.isVoiceOverRunning = isVoiceOverRunning
    self.pledgedProjects = pledgedProjects
  }
}

public struct ManagePledgeComposition {
  public let pledgeFeature: PledgeFeature
  public let paymentsFeature: PaymentsFeature
  public let rewardsFeature: RewardsFeature
  public let messagingFeature: MessagingFeature
  public let checkout: PledgeCheckoutComposition

  public init(
    pledgeFeature: PledgeFeature,
    paymentsFeature: PaymentsFeature,
    rewardsFeature: RewardsFeature,
    messagingFeature: MessagingFeature,
    checkout: PledgeCheckoutComposition
  ) {
    self.pledgeFeature = pledgeFeature
    self.paymentsFeature = paymentsFeature
    self.rewardsFeature = rewardsFeature
    self.messagingFeature = messagingFeature
    self.checkout = checkout
  }
}

public struct PledgedProjectsComposition {
  public let pledgedProjectsFeature: PledgedProjectsFeature
  public let activities: ActivityComposition

  public init(
    pledgedProjectsFeature: PledgedProjectsFeature,
    activities: ActivityComposition
  ) {
    self.pledgedProjectsFeature = pledgedProjectsFeature
    self.activities = activities
  }
}

@MainActor
public final class AppModel {
  public static let shared = AppModel.live()

  private var hasStartedLaunchWork: Bool

  public let developerExamplesFeature: DeveloperExamplesFeature
  public let onboardingFeature: OnboardingFeature
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
  public let helpFeature: HelpFeature
  public let searchFeature: SearchFeature
  public let discoveryFeature: DiscoveryFeature
  public let projectDetailsFeature: ProjectDetailsFeature
  public let rewardsFeature: RewardsFeature
  public let discussionFeature: DiscussionFeature
  public let projectMediaFeature: ProjectMediaFeature

  public var projectPageComposition: ProjectPageComposition {
    ProjectPageComposition(
      projectDetailsFeature: self.projectDetailsFeature,
      projectMediaFeature: self.projectMediaFeature,
      projectReportingFeature: self.projectReportingFeature,
      managePledge: self.managePledgeComposition
    )
  }

  public var activityComposition: ActivityComposition {
    ActivityComposition(
      activityFeature: self.activityFeature,
      friendsFeature: self.friendsFeature,
      projectPage: self.projectPageComposition
    )
  }

  public var messagingComposition: MessagingComposition {
    MessagingComposition(
      messagingFeature: self.messagingFeature,
      discussionFeature: self.discussionFeature,
      projectPage: self.projectPageComposition
    )
  }

  public var videoFeedComposition: VideoFeedComposition {
    VideoFeedComposition(
      projectMediaFeature: self.projectMediaFeature,
      messagingFeature: self.messagingFeature,
      projectPage: self.projectPageComposition,
      analytics: { AppEnvironment.current.ksrAnalytics },
      isPad: { AppEnvironment.current.device.userInterfaceIdiom == .pad }
    )
  }

  public var searchComposition: SearchComposition {
    SearchComposition(
      searchFeature: self.searchFeature,
      sessionFeature: self.sessionFeature,
      videoFeed: self.videoFeedComposition
    )
  }

  public var discoveryComposition: DiscoveryComposition {
    let cardPresentation = self.discoveryCardPresentation
    return DiscoveryComposition(
      discoveryFeature: self.discoveryFeature,
      videoFeed: self.videoFeedComposition,
      curatedProjects: CuratedProjectsComposition(
        recommendationsFeature: self.recommendationsFeature,
        projectMediaFeature: self.projectMediaFeature,
        cardPresentation: cardPresentation
      ),
      findFriends: self.findFriendsComposition,
      cardPresentation: cardPresentation,
      isPad: { AppEnvironment.current.device.userInterfaceIdiom == .pad }
    )
  }

  public var findFriendsComposition: FindFriendsComposition {
    FindFriendsComposition(
      friendsFeature: self.friendsFeature,
      settingsFeature: self.settingsFeature
    )
  }

  public var settingsComposition: SettingsComposition {
    SettingsComposition(
      settingsFeature: self.settingsFeature,
      findFriends: self.findFriendsComposition,
      notifications: self.settingsNotificationsComposition
    )
  }

  public var settingsNotificationsComposition: SettingsNotificationsComposition {
    SettingsNotificationsComposition(
      settingsFeature: self.settingsFeature,
      isVoiceOverRunning: { AppEnvironment.current.isVoiceOverRunning() }
    )
  }

  public var backerDashboardComposition: BackerDashboardComposition {
    BackerDashboardComposition(
      profileFeature: self.profileFeature,
      messaging: self.messagingComposition,
      settings: self.settingsComposition
    )
  }

  public var curatedProjectsComposition: CuratedProjectsComposition {
    CuratedProjectsComposition(
      recommendationsFeature: self.recommendationsFeature,
      projectMediaFeature: self.projectMediaFeature,
      cardPresentation: self.discoveryCardPresentation
    )
  }

  private var discoveryCardPresentation: DiscoveryCardPresentation {
    DiscoveryCardPresentation(
      today: { AppEnvironment.current.dateType.init().date },
      liveProjectDuration: { seconds in
        let formatted = Format.duration(
          secondsInUTC: seconds,
          abbreviate: false,
          useToGo: true,
          env: AppEnvironment.current
        )
        return (duration: formatted.time, unit: formatted.unit)
      }
    )
  }

  public var pledgeCheckoutComposition: PledgeCheckoutComposition {
    PledgeCheckoutComposition(
      pledgeFeature: self.pledgeFeature,
      authenticationFeature: self.authenticationFeature,
      paymentsFeature: self.paymentsFeature,
      analytics: { AppEnvironment.current.ksrAnalytics },
      responseDelay: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds },
      advertisingContext: {
        guard let environment = AppEnvironment.current else { return nil }
        environment.appTrackingTransparency.updateAdvertisingIdentifier()
        guard let id = environment.appTrackingTransparency.advertisingIdentifier else { return nil }
        return (id, environment.mainBundle.platformVersion)
      }
    )
  }

  public var rootTabComposition: RootTabComposition {
    RootTabComposition(
      sessionFeature: self.sessionFeature,
      backerDashboard: self.backerDashboardComposition,
      activities: self.activityComposition,
      search: self.searchComposition,
      discovery: self.discoveryComposition,
      analytics: { AppEnvironment.current.ksrAnalytics },
      badgePresentationDelay: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds },
      isVoiceOverRunning: { AppEnvironment.current.isVoiceOverRunning() },
      pledgedProjects: self.pledgedProjectsComposition
    )
  }

  public var managePledgeComposition: ManagePledgeComposition {
    ManagePledgeComposition(
      pledgeFeature: self.pledgeFeature,
      paymentsFeature: self.paymentsFeature,
      rewardsFeature: self.rewardsFeature,
      messagingFeature: self.messagingFeature,
      checkout: self.pledgeCheckoutComposition
    )
  }

  public var pledgedProjectsComposition: PledgedProjectsComposition {
    PledgedProjectsComposition(
      pledgedProjectsFeature: self.pledgedProjectsFeature,
      activities: self.activityComposition
    )
  }

  public init(
    developerExamplesFeature: DeveloperExamplesFeature,
    onboardingFeature: OnboardingFeature,
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
    helpFeature: HelpFeature,
    searchFeature: SearchFeature,
    discoveryFeature: DiscoveryFeature,
    projectDetailsFeature: ProjectDetailsFeature,
    rewardsFeature: RewardsFeature,
    discussionFeature: DiscussionFeature,
    projectMediaFeature: ProjectMediaFeature
  ) {
    self.developerExamplesFeature = developerExamplesFeature
    self.onboardingFeature = onboardingFeature
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
    self.helpFeature = helpFeature
    self.searchFeature = searchFeature
    self.discoveryFeature = discoveryFeature
    self.projectDetailsFeature = projectDetailsFeature
    self.rewardsFeature = rewardsFeature
    self.discussionFeature = discussionFeature
    self.projectMediaFeature = projectMediaFeature
    self.hasStartedLaunchWork = false
  }

  deinit {
    let settings = self.settingsFeature
    let discovery = self.discoveryFeature
    Task { @MainActor in
      settings.cancelScheduledAccountRefresh()
      settings.cancelAccountSetupRefresh()
      discovery.cancelRecommendationRefresh()
    }
  }

  /// Starts shared launch work once without making UI construction wait for it.
  @discardableResult
  public func applicationDidFinishLaunching() -> Task<Config, Error>? {
    guard !self.hasStartedLaunchWork else { return nil }
    self.hasStartedLaunchWork = true
    return self.settingsFeature.requestApplicationSettingsRefresh()
  }

  /// Synchronous permission preparation preserves the delegate's SDK setup order.
  func prepareNotificationAndTrackingPermissions() {
    self.onboardingFeature.preparePushNotificationsForLaunch()
    self.onboardingFeature.prepareTrackingConsent()
  }

  func setApplicationActive(_ isActive: Bool) {
    self.onboardingFeature.setApplicationActive(isActive)
  }

  func refreshNotificationAuthorization() {
    self.onboardingFeature.resetBadgeIfPushAuthorized()
  }

  func receiveDeviceToken(_ deviceToken: Data, onRegistered: @escaping @MainActor (String) -> Void) {
    self.sessionFeature.scheduleDeviceRegistration(for: deviceToken, onRegistered: onRegistered)
  }

  public func applicationWillEnterForeground() {
    self.settingsFeature.requestApplicationSettingsRefresh()
  }

  public func applicationDidEnterBackground(notificationCenter: NotificationCenter = .default) {
    notificationCenter.post(name: .ksr_applicationDidEnterBackground, object: nil)
  }

  public func synchronizeUbiquitousPreferences() {
    _ = AppEnvironment.current.ubiquitousStore.synchronize()
  }

  @discardableResult public func requestRemoteConfiguration(
    client: any RemoteConfigClientType
  ) -> Task<Void, Error> {
    self.settingsFeature.activateRemoteSettings(client: client)
  }

  public func resetFeaturesForSessionChange() {
    self.sessionFeature.sessionChanged()
    self.paymentsFeature.sessionChanged()
    self.settingsFeature.cancelScheduledAccountRefresh()
    self.authenticationFeature.cancelAllEmailRedirects()
    self.discoveryFeature.resetRecommendationAvailability()
    self.settingsFeature.resetApplicationSettings()
    self.developerExamplesFeature.reset()
    self.creatorDraftsFeature.reset()
    self.recommendationsFeature.reset()
    self.friendsFeature.reset()
    self.activityFeature.reset()
    self.profileFeature.reset()
    self.messagingFeature.resetMailboxState()
    self.pledgeFeature.reset()
    self.pledgedProjectsFeature.reset()
    self.settingsFeature.requestApplicationSettingsRefresh()
  }

  public static func live() -> AppModel {
    let connectivity = ConnectivityService(makeMonitor: { SystemReachabilityMonitor() })
    let searchProvider = AsyncSearchProjectsProvider(service: AppEnvironment.current.apiService)
    let sessionFeature = SessionFeature.live()
    let activityFeature = ActivityFeature(
      platform: .init(
        loadSurvey: { try await AppEnvironment.current.apiService.applicationSurvey(id: $0) },
        applicationBadgeNumber: { AppEnvironment.current.application.applicationIconBadgeNumber },
        responseDelaySeconds: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds },
        trackProjectCardClick: {
          AppEnvironment.current.ksrAnalytics.trackProjectCardClicked(page: .activities, project: $0)
        }
      ),
      sessionFeature: sessionFeature,
      makeProvider: { AsyncActivityProvider(service: AppEnvironment.current.apiService) }
    )
    let profileFeature = ProfileFeature(
      sessionFeature: sessionFeature,
      makeProvider: { AsyncProfileProvider(service: AppEnvironment.current.apiService) },
      responseDelaySeconds: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds }
    )
    let applicationConfiguration = ApplicationConfigurationService.live()
    let remoteConfiguration = RemoteConfigurationService(
      notificationCenter: .default, reportFailure: RemoteConfigClient.reportActivationFailure
    )
    let settingsFeature = SettingsFeature(
      sessionFeature: sessionFeature,
      applicationSettings: .live(configuration: applicationConfiguration, remoteConfiguration: remoteConfiguration),
      hasStoredCredentials: { AppEnvironment.current.apiService.isAuthenticated },
      applicationVersion: { AppEnvironment.current.mainBundle.appVersionString },
      responseDelaySeconds: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds },
      identifyUser: { AppEnvironment.current.identify(user: $0) },
      makeProvider: { AsyncAccountPreferencesProvider(service: AppEnvironment.current.apiService) }
    )
    let messagingFeature = MessagingFeature(
      sessionFeature: sessionFeature,
      makeProvider: { AsyncMessagingProvider(service: AppEnvironment.current.apiService) },
      responseDelaySeconds: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds }
    )
    let discussionFeature = DiscussionFeature(
      platform: .live(),
      sessionFeature: sessionFeature,
      makeProvider: { AsyncDiscussionProvider(service: AppEnvironment.current.apiService) }
    )
    let discoveryFeature = DiscoveryFeature(
      provider: AsyncDiscoveryProvider(service: AppEnvironment.current.apiService),
      analytics: .init(
        selectedSort: { previous, parameters, current in
          let context: KSRAnalytics.TypeContext.DiscoverySortContext
          switch current {
          case .endingSoon: context = .endingSoon
          case .magic: context = .magic
          case .newest: context = .newest
          case .popular: context = .popular
          default:
            assert(
              false,
              "The other sort types were added for GraphQL compatibility, and should never come up in V1 Discover."
            )
            context = .magic
          }
          AppEnvironment.current.ksrAnalytics.trackDiscoverySelectedSort(
            prevSort: previous,
            params: parameters,
            discoverySortContext: context
          )
        },
        discoveryViewed: { AppEnvironment.current.ksrAnalytics.trackDiscovery(params: $0) },
        projectCardClicked: {
          AppEnvironment.current.ksrAnalytics.trackProjectCardClicked(
            page: .discovery,
            project: $0,
            typeContext: .init(params: $1),
            location: .discoverAdvanced,
            params: $1
          )
        }
      ),
      loadCategories: { try await AppEnvironment.current.apiService.fetchSearchCategories() },
      categoryCache: { AppEnvironment.current.cache },
      localStore: { AppEnvironment.current.userDefaults },
      cloudStore: { AppEnvironment.current.ubiquitousStore },
      serverEnvironment: { AppEnvironment.current.apiService.serverConfig.environment },
      isDebugBuild: {
        let bundle = AppEnvironment.current.mainBundle
        return bundle.isAlpha || bundle.isBeta || bundle.isDebug
      },
      responseDelaySeconds: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds },
      sessionFeature: sessionFeature
    )
    let onboarding = OnboardingFeature.live()
    return AppModel(
      developerExamplesFeature: DeveloperExamplesFeature(sessionFeature: sessionFeature, makeProvider: {
        AsyncDeveloperExamplesProvider(service: AppEnvironment.current.apiService)
      }),
      onboardingFeature: onboarding,
      creatorDraftsFeature: CreatorDraftsFeature(
        sessionFeature: sessionFeature,
        makeProvider: { AsyncCreatorDraftsProvider(service: AppEnvironment.current.apiService) },
        responseDelaySeconds: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds }
      ),
      recommendationsFeature: RecommendationsFeature(platform: .live(), settingsFeature: settingsFeature, makeProvider: {
        AsyncRecommendationsProvider(service: AppEnvironment.current.apiService)
      }),
      projectReportingFeature: ProjectReportingFeature(sessionFeature: sessionFeature, makeProvider: {
        AsyncProjectReportingProvider(service: AppEnvironment.current.apiService)
      }),
      friendsFeature: FriendsFeature(
        sessionFeature: sessionFeature,
        makeProvider: { AsyncFriendsProvider(service: AppEnvironment.current.apiService) },
        responseDelaySeconds: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds }
      ),
      pledgedProjectsFeature: PledgedProjectsFeature(
        sessionFeature: sessionFeature, settingsFeature: settingsFeature, makeProvider: {
          AsyncPledgedProjectsProvider(service: AppEnvironment.current.apiService)
        }, locale: { AppEnvironment.current.locale }, analytics: .init(
          dashboardOpened: {
            AppEnvironment.current.ksrAnalytics.trackPPODashboardOpens(properties: $0)
          },
          cardEvent: { event, project, properties in
            switch event {
            case .authenticateCard:
              AppEnvironment.current.ksrAnalytics.trackPPOAuthenticateCard(
                project: project, properties: properties
              )
            case .confirmAddress:
              AppEnvironment.current.ksrAnalytics.trackPPOInitiateConfirmingAddress(
                project: project, properties: properties
              )
            case .editAddress:
              AppEnvironment.current.ksrAnalytics.trackPPOEditAddress(
                project: project, properties: properties
              )
            case .fixPayment:
              AppEnvironment.current.ksrAnalytics.trackPPOFixingPaymentFailure(
                project: project, properties: properties
              )
            case .manageLivePledge:
              AppEnvironment.current.ksrAnalytics.trackPPOManageLivePledge(
                project: project, properties: properties
              )
            case .openPledgeManager:
              AppEnvironment.current.ksrAnalytics.trackPPOOpenPledgeManager(
                project: project, properties: properties
              )
            case .sendMessage:
              AppEnvironment.current.ksrAnalytics.trackPPOMessagingCreator(
                from: project, properties: properties
              )
            case .updateRewardReceived(let isOn):
              AppEnvironment.current.ksrAnalytics.trackPPOUpdateRewardReceived(
                toggleOn: isOn, project: project, properties: properties
              )
            case .viewProjectDetails:
              AppEnvironment.current.ksrAnalytics.trackPPOViewProjectDetails(
                project: project, properties: properties
              )
            case .completeSurvey:
              AppEnvironment.current.ksrAnalytics.trackPPOOpeningSurvey(
                project: project, properties: properties
              )
            }
          },
          addressConfirmed: {
            AppEnvironment.current.ksrAnalytics.trackPPOSubmitAddressConfirmation(
              project: $0, properties: $1
            )
          }
        )
      ),
      pledgeFeature: PledgeFeature(
        platform: .live(),
        sessionFeature: sessionFeature,
        settingsFeature: settingsFeature,
        makeProvider: { AsyncPledgeProvider(service: AppEnvironment.current.apiService) },
        trackRewardReceivedToggle: { isOn, project in
          AppEnvironment.current.ksrAnalytics.trackRewardReceivedToggled(
            toggleOn: isOn, project: project, context: .managePledgeScreen
          )
        },
        trackManagePledgePageView: { project, reward, checkoutData in
          AppEnvironment.current.ksrAnalytics.trackManagePledgePageViewed(
            project: project, reward: reward, checkoutData: checkoutData
          )
        }
      ),
      paymentsFeature: PaymentsFeature(
        sessionFeature: sessionFeature,
        makeProvider: { AsyncPaymentsProvider(service: AppEnvironment.current.apiService) },
        trackThirdPartyEvent: { _ = AppEnvironment.current.apiService.prepareThirdPartyEvent(input: $0) },
        supportedApplePayNetworks: {
          AppEnvironment.current.applePayCapabilities.supportedNetworks(
            for: $0, launchedCountries: AppEnvironment.current.launchedCountries
          )
        },
        stripePublishableKey: { AppEnvironment.current.environmentType.stripePublishableKey },
        currencyContext: { .live() },
        launchedCountries: { AppEnvironment.current.launchedCountries },
        hasEligibleApplePayCard: {
          AppEnvironment.current.applePayCapabilities.canMakeApplePayPayment(
            for: $0, launchedCountries: AppEnvironment.current.launchedCountries
          )
        },
        responseDelaySeconds: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds }
      ),
      messagingFeature: messagingFeature,
      sessionFeature: sessionFeature,
      authenticationFeature: AuthenticationFeature(
        sessionFeature: sessionFeature,
        platform: .init(
          webBaseURL: { AppEnvironment.current.apiService.serverConfig.webBaseUrl },
          oauthClientID: { AppEnvironment.current.apiService.serverConfig.apiClientAuth.clientId },
          appleAppID: { AppEnvironment.current.apiService.appId },
          responseDelaySeconds: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds },
          trackLoginPageViewed: { AppEnvironment.current.ksrAnalytics.trackLoginPageViewed() },
          trackLoginSubmitButtonClicked: {
            AppEnvironment.current.ksrAnalytics.trackLoginSubmitButtonClicked()
          },
          trackLoginToutPageViewed: { AppEnvironment.current.ksrAnalytics.trackLoginTOutPageViewed() },
          trackLoginInitiateButtonClicked: {
            AppEnvironment.current.ksrAnalytics.trackLoginInitiateButtonClicked()
          }
        ),
        makeProvider: { AsyncAuthenticationProvider(service: AppEnvironment.current.apiService) }
      ),
      settingsFeature: settingsFeature,
      activityFeature: activityFeature,
      profileFeature: profileFeature,
      helpFeature: HelpFeature(
        webBaseURL: { AppEnvironment.current.apiService.serverConfig.webBaseUrl },
        prepareRequest: { AppEnvironment.current.apiService.preparedRequest(forURL: $0) }
      ),
      searchFeature: SearchFeature(
        platform: .init(
          responseDelaySeconds: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds },
          debounceSeconds: { AppEnvironment.current.debounceInterval.searchDelaySeconds }
        ),
        provider: searchProvider,
        lookupProvider: AsyncSearchLookupProvider(
          service: AppEnvironment.current.apiService,
          cache: AppEnvironment.current.cache
        ),
        analytics: .init(
          projectCardClicked: {
            AppEnvironment.current.ksrAnalytics.trackProjectCardClicked(
              page: .search,
              project: $0,
              typeContext: .results,
              location: .searchResults,
              params: $1
            )
          },
          searchViewed: {
            AppEnvironment.current.ksrAnalytics.trackProjectSearchView(params: $0, results: $1)
          }
        )
      ),
      discoveryFeature: discoveryFeature,
      projectDetailsFeature: ProjectDetailsFeature(
        platform: .live(),
        sessionFeature: sessionFeature,
        settingsFeature: settingsFeature,
        discussionFeature: discussionFeature,
        makeProvider: { AsyncProjectDetailsProvider(service: AppEnvironment.current.apiService) },
        useFastLoading: {
          InstantPledgeButtonExperiment().boolValue(forKey: .instant_pledge_enabled) == true
        },
        analytics: .init(
          projectViewed: {
            AppEnvironment.current.ksrAnalytics.trackProjectViewed(
              $0, refTag: $1, sectionContext: .overview
            )
          },
          blockInitiated: {
            AppEnvironment.current.ksrAnalytics.trackBlockedUser(
              $0, page: .project, sectionContext: .overview,
              locationContext: .creatorDetailsMenu, typeContext: .initiate,
              targetUserId: $1
            )
          },
          blockConfirmed: {
            AppEnvironment.current.ksrAnalytics.trackBlockedUser(
              $0, page: .project, sectionContext: .overview,
              locationContext: .creatorDetailsMenu, typeContext: .confirm,
              targetUserId: $1
            )
          },
          pledgeCTATapped: {
            AppEnvironment.current.ksrAnalytics.trackPledgeCTAButtonClicked(
              stateType: $0, project: $1
            )
          }
        ),
        projectViewContext: {
          let tracking = AppEnvironment.current.appTrackingTransparency
          tracking.updateAdvertisingIdentifier()
          guard let advertisingID = tracking.advertisingIdentifier else { return nil }
          return (advertisingID, AppEnvironment.current.mainBundle.platformVersion)
        }
      ),
      rewardsFeature: RewardsFeature(
        platform: .live(),
        sessionFeature: sessionFeature,
        makeProvider: { AsyncRewardsProvider(service: AppEnvironment.current.apiService) },
        hasEligibleApplePayCard: {
          AppEnvironment.current.applePayCapabilities.canMakeApplePayPayment(
            for: $0, launchedCountries: AppEnvironment.current.launchedCountries
          )
        },
        analytics: .init(
          rewardsViewed: {
            AppEnvironment.current.ksrAnalytics.trackRewardsViewed(
              project: $0, checkoutPropertiesData: $1, refTag: $2
            )
          },
          rewardClicked: {
            AppEnvironment.current.ksrAnalytics.trackRewardClicked(
              project: $0, reward: $1, checkoutPropertiesData: $2, refTag: $3
            )
          },
          addOnsPageViewed: {
            AppEnvironment.current.ksrAnalytics.trackAddOnsPageViewed(
              project: $0, reward: $1, checkoutData: $2, refTag: $3
            )
          },
          addOnsContinue: {
            AppEnvironment.current.ksrAnalytics.trackAddOnsContinueButtonClicked(
              project: $0, reward: $1, checkoutData: $2, refTag: $3
            )
          }
        ),
        rewardSelectionContext: {
          AppEnvironment.current.appTrackingTransparency.updateAdvertisingIdentifier()
          guard let advertisingID = AppEnvironment.current.appTrackingTransparency.advertisingIdentifier else {
            return nil
          }
          return (advertisingID, AppEnvironment.current.mainBundle.platformVersion)
        }
      ),
      discussionFeature: discussionFeature,
      projectMediaFeature: ProjectMediaFeature(
        sessionFeature: sessionFeature,
        settingsFeature: settingsFeature,
        connectivity: connectivity,
        webBaseURL: { AppEnvironment.current.apiService.serverConfig.webBaseUrl },
        analytics: { AppEnvironment.current.ksrAnalytics },
        watchResponseDelaySeconds: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds },
        savePrompts: .live(),
        makeProvider: { AsyncProjectMediaProvider(service: AppEnvironment.current.apiService) }
      )
    )
  }
}
