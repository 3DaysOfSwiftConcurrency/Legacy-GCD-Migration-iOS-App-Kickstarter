@testable import Kickstarter_iOS
import Experimentation
import Foundation
@testable import KsApi
import UIKit

/// Isolated application composition; unrelated capabilities use inert mock services.
@MainActor
func makeTestAppModel(
  sessionFeature: SessionFeature,
  onboardingFeature: OnboardingFeature? = nil,
  settingsFeature: SettingsFeature? = nil,
  messagingFeature: MessagingFeature? = nil,
  discussionFeature: DiscussionFeature? = nil,
  discoveryFeature: DiscoveryFeature? = nil,
  activityFeature: ActivityFeature? = nil,
  authenticationFeature: AuthenticationFeature? = nil
) -> AppModel {
  let settingsFeature = settingsFeature ?? SettingsFeature(
    sessionFeature: sessionFeature, makeProvider: { AsyncAccountPreferencesProvider(service: MockService()) }
  )
  let messagingFeature = messagingFeature ?? MessagingFeature(
    sessionFeature: sessionFeature, makeProvider: { AsyncMessagingProvider(service: MockService()) }
  )
  let discussionFeature = discussionFeature ?? DiscussionFeature(
    platform: .live(), sessionFeature: sessionFeature,
    makeProvider: { AsyncDiscussionProvider(service: MockService()) }
  )
  let discoveryFeature = discoveryFeature ?? DiscoveryFeature(
    provider: AsyncDiscoveryProvider(), loadCategories: { .template }, sessionFeature: sessionFeature
  )
  let activityFeature = activityFeature ?? ActivityFeature(
    sessionFeature: sessionFeature, makeProvider: { AsyncActivityProvider(service: MockService()) }
  )
  let authenticationFeature = authenticationFeature ?? AuthenticationFeature(
    sessionFeature: sessionFeature, makeProvider: { AsyncAuthenticationProvider(service: MockService()) }
  )
  let onboarding = onboardingFeature ?? OnboardingFeature(completionStore: { [store = MockKeyValueStore()] in store })
  return AppModel(
    developerExamplesFeature: DeveloperExamplesFeature(sessionFeature: sessionFeature, makeProvider: {
      AsyncDeveloperExamplesProvider(service: MockService())
    }),
    onboardingFeature: onboarding,
    creatorDraftsFeature: CreatorDraftsFeature(sessionFeature: sessionFeature, makeProvider: {
      AsyncCreatorDraftsProvider(service: MockService())
    }),
    recommendationsFeature: RecommendationsFeature(platform: .test(), settingsFeature: settingsFeature, makeProvider: {
      AsyncRecommendationsProvider(service: MockService())
    }),
    projectReportingFeature: ProjectReportingFeature(sessionFeature: sessionFeature, makeProvider: {
      AsyncProjectReportingProvider(service: MockService())
    }),
    friendsFeature: FriendsFeature(sessionFeature: sessionFeature, makeProvider: {
      AsyncFriendsProvider(service: MockService())
    }),
    pledgedProjectsFeature: PledgedProjectsFeature(
      sessionFeature: sessionFeature, settingsFeature: settingsFeature, makeProvider: {
        AsyncPledgedProjectsProvider(service: MockService())
      }
    ),
    pledgeFeature: PledgeFeature(platform: .live(), sessionFeature: sessionFeature, makeProvider: {
      AsyncPledgeProvider(service: MockService())
    }),
    paymentsFeature: PaymentsFeature(sessionFeature: sessionFeature, makeProvider: {
      AsyncPaymentsProvider(service: MockService())
    }),
    messagingFeature: messagingFeature,
    sessionFeature: sessionFeature,
    authenticationFeature: authenticationFeature,
    settingsFeature: settingsFeature,
    activityFeature: activityFeature,
    profileFeature: ProfileFeature(sessionFeature: sessionFeature, makeProvider: {
      AsyncProfileProvider(service: MockService())
    }),
    searchFeature: SearchFeature(provider: UnusedDeepLinkSearchProvider()),
    discoveryFeature: discoveryFeature,
    projectDetailsFeature: ProjectDetailsFeature(
      platform: .live(), sessionFeature: sessionFeature, discussionFeature: discussionFeature,
      makeProvider: { AsyncProjectDetailsProvider(service: MockService()) },
      useFastLoading: { false }, includeRichText: { false }
    ),
    rewardsFeature: RewardsFeature(platform: .live(), sessionFeature: sessionFeature, makeProvider: {
      AsyncRewardsProvider(service: MockService())
    }),
    discussionFeature: discussionFeature,
    projectMediaFeature: ProjectMediaFeature(sessionFeature: sessionFeature, makeProvider: {
      AsyncProjectMediaProvider(service: MockService())
    })
  )
}

extension RecommendationsFeature.Platform {
  static func test(
    promptStore: (@MainActor () -> any KeyValueStoreType)? = nil,
    responseDelaySeconds: @escaping @MainActor () -> TimeInterval = { 0 },
    recordThirdPartyEvent: @escaping @MainActor (TriggerThirdPartyEventInput) -> Void = { _ in }
  ) -> Self {
    let defaultPromptStore = MockKeyValueStore()
    return Self(
      promptStore: promptStore ?? { defaultPromptStore },
      responseDelaySeconds: responseDelaySeconds,
      recordThirdPartyEvent: recordThirdPartyEvent
    )
  }
}

extension SettingsFeature.ApplicationSettings {
  @MainActor
  static func test(
    readConfiguration: @escaping @MainActor () -> Config? = { nil },
    currentCountryCode: @escaping @MainActor () -> String? = { nil },
    userDefaults: @escaping @MainActor () -> any KeyValueStoreType = { MockKeyValueStore() },
    remoteClient: @escaping @MainActor () -> (any RemoteConfigClientType)? = { nil },
    statsigClient: @escaping @MainActor () -> (any StatsigClientType)? = { nil }
  ) -> Self {
    Self(
      configuration: ApplicationConfigurationService(load: { throw CancellationError() }),
      remoteConfiguration: RemoteConfigurationService(notificationCenter: NotificationCenter()),
      readConfiguration: readConfiguration,
      currentCountryCode: currentCountryCode,
      saveConfigurationOverride: { _ in },
      userDefaults: userDefaults,
      remoteClient: remoteClient,
      statsigClient: statsigClient,
      notificationCenter: NotificationCenter()
    )
  }
}

extension PledgeFeature {
  convenience init(
    platform: Platform,
    sessionFeature: SessionFeature,
    makeProvider: @escaping () -> any PledgeProvider
  ) {
    self.init(
      platform: platform,
      sessionFeature: sessionFeature,
      settingsFeature: SettingsFeature(
        sessionFeature: sessionFeature,
        applicationSettings: .test(),
        makeProvider: { AsyncAccountPreferencesProvider(service: MockService()) }
      ),
      makeProvider: makeProvider
    )
  }
}

extension ProjectMediaFeature {
  convenience init(
    sessionFeature: SessionFeature,
    connectivity: ConnectivityService = ConnectivityService(),
    isVideoFeedEnabled: @escaping @MainActor () -> Bool = { false },
    webBaseURL: @escaping @MainActor () -> URL = { ServerConfig.production.webBaseUrl },
    analytics: @escaping @MainActor () -> KSRAnalytics? = { nil },
    savePrompts: SavePrompts? = nil,
    loadImage: (@MainActor (URL) async throws -> UIImage)? = nil,
    preparePlayback: (@MainActor (URL, URL?) async throws -> PreparedProjectMedia)? = nil,
    makeProvider: @escaping () -> any ProjectMediaProvider
  ) {
    let settingsFeature = SettingsFeature(
      sessionFeature: sessionFeature,
      applicationSettings: .test(statsigClient: {
        let client = MockStatsigWrapper()
        client.features[.videoFeed] = isVideoFeedEnabled()
        return client
      }),
      makeProvider: { AsyncAccountPreferencesProvider(service: MockService()) }
    )
    self.init(
      sessionFeature: sessionFeature,
      settingsFeature: settingsFeature,
      connectivity: connectivity,
      webBaseURL: webBaseURL,
      analytics: analytics,
      savePrompts: savePrompts,
      loadImage: loadImage,
      preparePlayback: preparePlayback,
      makeProvider: makeProvider
    )
  }
}

extension ProjectDetailsFeature {
  convenience init(
    platform: Platform,
    sessionFeature: SessionFeature,
    discussionFeature: DiscussionFeature,
    makeProvider: @escaping @MainActor () -> any ProjectDetailsProvider,
    useFastLoading: @escaping @MainActor () -> Bool,
    includeRichText: @escaping @MainActor () -> Bool,
    sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { seconds in
      if seconds.isInfinite { try await Task.sleep(nanoseconds: UInt64.max) }
      else if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
      try Task.checkCancellation()
    }
  ) {
    let settingsFeature = SettingsFeature(
      sessionFeature: sessionFeature,
      applicationSettings: .test(statsigClient: {
        let client = MockStatsigWrapper()
        client.features[.projectStoryRichText] = includeRichText()
        return client
      }),
      makeProvider: { AsyncAccountPreferencesProvider(service: MockService()) }
    )
    self.init(
      platform: platform,
      sessionFeature: sessionFeature,
      settingsFeature: settingsFeature,
      discussionFeature: discussionFeature,
      makeProvider: makeProvider,
      useFastLoading: useFastLoading,
      sleep: sleep
    )
  }
}

extension AuthenticationFeature {
  convenience init(
    sessionFeature: SessionFeature,
    makeProvider: @escaping () -> any AuthenticationProvider,
    trackOAuthLogin: @escaping @MainActor () -> Void = {
      AppEnvironment.current.ksrAnalytics.trackLoginSubmitButtonClicked()
    },
    resolveRedirect: @escaping (URL) async throws -> URL? = { try await FirstRedirectResolver.resolve($0) },
    appleAppID: @escaping @MainActor () -> String = { AppEnvironment.current.apiService.appId },
    webBaseURL: @escaping @MainActor () -> URL = {
      AppEnvironment.current.apiService.serverConfig.webBaseUrl
    },
    trackLoginPageViewed: @escaping @MainActor () -> Void = {
      AppEnvironment.current.ksrAnalytics.trackLoginPageViewed()
    }
  ) {
    self.init(
      sessionFeature: sessionFeature,
      platform: .init(
        webBaseURL: webBaseURL,
        appleAppID: appleAppID,
        trackLoginPageViewed: trackLoginPageViewed,
        trackLoginSubmitButtonClicked: trackOAuthLogin
      ),
      makeProvider: makeProvider,
      resolveRedirect: resolveRedirect
    )
  }
}

extension MessagingFeature {
  convenience init(
    sessionFeature: SessionFeature,
    makeProvider: @escaping () -> any MessagingProvider,
    sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
      if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
    }
  ) {
    self.init(
      sessionFeature: sessionFeature,
      makeProvider: makeProvider,
      responseDelaySeconds: { 0 },
      sleep: sleep
    )
  }
}

extension FriendsFeature {
  convenience init(
    sessionFeature: SessionFeature,
    makeProvider: @escaping () -> any FriendsProvider,
    sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
      if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
    }
  ) {
    self.init(
      sessionFeature: sessionFeature,
      makeProvider: makeProvider,
      responseDelaySeconds: { 0 },
      sleep: sleep
    )
  }
}

extension ProfileFeature {
  convenience init(
    sessionFeature: SessionFeature,
    makeProvider: @escaping () -> any ProfileProvider,
    loadAvatar: (@MainActor (URL) async throws -> Data)? = nil,
    sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
      if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
    }
  ) {
    self.init(
      sessionFeature: sessionFeature,
      makeProvider: makeProvider,
      responseDelaySeconds: { 0 },
      loadAvatar: loadAvatar,
      sleep: sleep
    )
  }
}

@MainActor
private struct UnusedDeepLinkSearchProvider: SearchProjectsProvider {
  func fetchPage(parameters: DiscoveryParams, cursor: String?) async throws -> SearchPageResponse {
    throw CancellationError()
  }
}
