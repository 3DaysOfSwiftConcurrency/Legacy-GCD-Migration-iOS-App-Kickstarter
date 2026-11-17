@testable import Kickstarter_iOS
import Foundation
@testable import KsApi

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
    remoteConfigurationService: RemoteConfigurationService(notificationCenter: NotificationCenter()),
    applicationConfigurationService: ApplicationConfigurationService(load: { .template }),
    creatorDraftsFeature: CreatorDraftsFeature(sessionFeature: sessionFeature, makeProvider: {
      AsyncCreatorDraftsProvider(service: MockService())
    }),
    recommendationsFeature: RecommendationsFeature(settingsFeature: settingsFeature, makeProvider: {
      AsyncRecommendationsProvider(service: MockService())
    }),
    projectReportingFeature: ProjectReportingFeature(sessionFeature: sessionFeature, makeProvider: {
      AsyncProjectReportingProvider(service: MockService())
    }),
    friendsFeature: FriendsFeature(sessionFeature: sessionFeature, makeProvider: {
      AsyncFriendsProvider(service: MockService())
    }),
    pledgedProjectsFeature: PledgedProjectsFeature(sessionFeature: sessionFeature, makeProvider: {
      AsyncPledgedProjectsProvider(service: MockService())
    }),
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

@MainActor
private struct UnusedDeepLinkSearchProvider: SearchProjectsProvider {
  func fetchPage(parameters: DiscoveryParams, cursor: String?) async throws -> SearchPageResponse {
    throw CancellationError()
  }
}
