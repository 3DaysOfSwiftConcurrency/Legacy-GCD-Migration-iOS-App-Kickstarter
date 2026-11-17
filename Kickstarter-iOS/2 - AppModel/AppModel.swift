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
      trackingDelay: trackingDelay
    )
  }
}

/// Application composition root. Features own shared state and directly awaitable workflows.
@MainActor
public final class AppModel {
  public static let shared = AppModel.live()

  private var hasLaunched: Bool

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
  public let searchFeature: SearchFeature
  public let discoveryFeature: DiscoveryFeature
  public let projectDetailsFeature: ProjectDetailsFeature
  public let rewardsFeature: RewardsFeature
  public let discussionFeature: DiscussionFeature
  public let projectMediaFeature: ProjectMediaFeature

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
    self.searchFeature = searchFeature
    self.discoveryFeature = discoveryFeature
    self.projectDetailsFeature = projectDetailsFeature
    self.rewardsFeature = rewardsFeature
    self.discussionFeature = discussionFeature
    self.projectMediaFeature = projectMediaFeature
    self.hasLaunched = false
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
  public func applicationDidFinishLaunching() async {
    guard !self.hasLaunched else { return }
    self.hasLaunched = true
    _ = try? await self.settingsFeature.requestApplicationSettingsRefresh().value
  }

  /// Synchronous permission preparation preserves the delegate's SDK setup order.
  func preparePermissions() {
    self.onboardingFeature.prepareNotificationAuthorization()
    self.onboardingFeature.prepareTrackingConsent()
  }

  func applicationActive(state: Bool) {
    self.onboardingFeature.setApplicationActive(state)
  }

  func refreshNotificationAuthorization() {
    self.onboardingFeature.refreshNotificationAuthorization()
  }

  func receiveDeviceToken(_ deviceToken: Data, onRegistered: @escaping @MainActor (String) -> Void) {
    self.sessionFeature.receiveDeviceToken(deviceToken, onRegistered: onRegistered)
  }

  public func applicationWillEnterForeground() {
    self.settingsFeature.requestApplicationSettingsRefresh()
  }

  public func applicationDidEnterBackground(notificationCenter: NotificationCenter = .default) {
    notificationCenter.post(name: .ksr_applicationDidEnterBackground, object: nil)
  }

  public func synchronizePreferences() {
    _ = AppEnvironment.current.ubiquitousStore.synchronize()
  }

  @discardableResult public func requestRemoteConfiguration(
    client: any RemoteConfigClientType
  ) -> Task<Void, Error> {
    self.settingsFeature.activateRemoteSettings(client: client)
  }

  public func sessionChanged() {
    self.sessionFeature.sessionChanged()
    self.paymentsFeature.sessionChanged()
    self.settingsFeature.cancelScheduledAccountRefresh()
    self.authenticationFeature.resetEmailRedirects()
    self.discoveryFeature.resetRecommendationAvailability()
    self.settingsFeature.resetApplicationSettings()
    self.developerExamplesFeature.reset()
    self.creatorDraftsFeature.reset()
    self.recommendationsFeature.reset()
    self.friendsFeature.reset()
    self.activityFeature.reset()
    self.profileFeature.reset()
    self.messagingFeature.reset()
    self.pledgeFeature.reset()
    self.pledgedProjectsFeature.reset()
    self.settingsFeature.requestApplicationSettingsRefresh()
  }

  public static func live() -> AppModel {
    let connectivity = ConnectivityService(makeMonitor: { SystemReachabilityMonitor() })
    let searchProvider = AsyncSearchProjectsProvider()
    let sessionFeature = SessionFeature.live()
    let activityFeature = ActivityFeature(
      platform: .init(
        loadSurvey: { try await AppEnvironment.current.apiService.applicationSurvey(id: $0) },
        applicationBadgeNumber: { AppEnvironment.current.application.applicationIconBadgeNumber },
        responseDelaySeconds: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds }
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
      responseDelaySeconds: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds },
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
      provider: AsyncDiscoveryProvider(), sessionFeature: sessionFeature
    )
    let onboarding = OnboardingFeature.live()
    return AppModel(
      developerExamplesFeature: DeveloperExamplesFeature(sessionFeature: sessionFeature, makeProvider: {
        AsyncDeveloperExamplesProvider(service: AppEnvironment.current.apiService)
      }),
      onboardingFeature: onboarding,
      creatorDraftsFeature: CreatorDraftsFeature(sessionFeature: sessionFeature, makeProvider: {
        AsyncCreatorDraftsProvider(service: AppEnvironment.current.apiService)
      }),
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
        }
      ),
      pledgeFeature: PledgeFeature(
        platform: .live(),
        sessionFeature: sessionFeature,
        settingsFeature: settingsFeature,
        makeProvider: { AsyncPledgeProvider(service: AppEnvironment.current.apiService) }
      ),
      paymentsFeature: PaymentsFeature(
        sessionFeature: sessionFeature,
        makeProvider: { AsyncPaymentsProvider(service: AppEnvironment.current.apiService) },
        trackThirdPartyEvent: { _ = AppEnvironment.current.apiService.prepareThirdPartyEvent(input: $0) }
      ),
      messagingFeature: messagingFeature,
      sessionFeature: sessionFeature,
      authenticationFeature: AuthenticationFeature(
        sessionFeature: sessionFeature,
        platform: .init(
          webBaseURL: { AppEnvironment.current.apiService.serverConfig.webBaseUrl },
          appleAppID: { AppEnvironment.current.apiService.appId },
          trackLoginPageViewed: { AppEnvironment.current.ksrAnalytics.trackLoginPageViewed() },
          trackLoginSubmitButtonClicked: {
            AppEnvironment.current.ksrAnalytics.trackLoginSubmitButtonClicked()
          }
        ),
        makeProvider: { AsyncAuthenticationProvider(service: AppEnvironment.current.apiService) }
      ),
      settingsFeature: settingsFeature,
      activityFeature: activityFeature,
      profileFeature: profileFeature,
      searchFeature: SearchFeature(
        platform: .init(
          responseDelaySeconds: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds },
          debounceSeconds: { AppEnvironment.current.debounceInterval.searchDelaySeconds }
        ),
        provider: searchProvider,
        lookupProvider: AsyncSearchLookupProvider()
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
        }
      ),
      rewardsFeature: RewardsFeature(
        platform: .live(),
        sessionFeature: sessionFeature,
        makeProvider: { AsyncRewardsProvider(service: AppEnvironment.current.apiService) }
      ),
      discussionFeature: discussionFeature,
      projectMediaFeature: ProjectMediaFeature(
        sessionFeature: sessionFeature,
        settingsFeature: settingsFeature,
        connectivity: connectivity,
        webBaseURL: { AppEnvironment.current.apiService.serverConfig.webBaseUrl },
        analytics: { AppEnvironment.current.ksrAnalytics },
        savePrompts: .live(),
        makeProvider: { AsyncProjectMediaProvider(service: AppEnvironment.current.apiService) }
      )
    )
  }
}
