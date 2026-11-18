import AppTrackingTransparency
@testable import Kickstarter_iOS
import GraphAPI
@testable import KsApi

import Prelude
import UserNotifications
import XCTest

@MainActor
final class AppModelTests: XCTestCase {
  func testDeviceRegistrationUsesInjectedSessionAndStopsAfterModelSessionChange() async throws {
    let debounce = AccountRequestGate<Void>()
    defer { debounce.releaseAll() }
    let session = SessionFeature(
      makeProvider: { NoDeviceRegistrationProvider() },
      deviceRegistrationDebounce: { try await debounce.request() }, currentUser: { .template }
    )
    let model = makeTestAppModel(sessionFeature: session)
    model.receiveDeviceToken(Data([0x01])) { _ in XCTFail("Obsolete registration delivered") }
    await debounce.waitFor(1)
    model.sessionChanged()
    try debounce.finish(0, .success(()))
    await session.waitForDeviceRegistration()
  }

  func testPermissionEventsUseTheInjectedOnboardingFeature() async {
    let oldAuthorization = MockPushRegistration.authorizedValue
    let oldRegistration = MockPushRegistration.registerValue
    defer {
      MockPushRegistration.authorizedValue = oldAuthorization
      MockPushRegistration.registerValue = oldRegistration
    }
    MockPushRegistration.authorizedValue = true
    MockPushRegistration.registerValue = nil
    let store = MockKeyValueStore()
    store.hasSeenOnboarding = true
    let tracking = MockAppTrackingTransparency()
    var badgeResets = 0
    let onboarding = OnboardingFeature(
      completionStore: { store }, pushRegistration: { MockPushRegistration.self },
      tracking: { tracking }, trackingDelay: {}
    )
    onboarding.onBadgeReset = { badgeResets += 1 }
    let model = makeTestAppModel(
      sessionFeature: SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) }),
      onboardingFeature: onboarding
    )

    model.applicationActive(state: true)
    await onboarding.waitForTrackingChecks()
    XCTAssertEqual(tracking.requestCount, 0)
    model.preparePermissions()
    model.refreshNotificationAuthorization()
    await onboarding.waitForTrackingChecks()

    XCTAssertEqual(tracking.requestCount, 1)
    XCTAssertEqual(badgeResets, 2)
  }

  func testSurveyLinkRejectsLateFailureAfterSessionReplacementAndCanResolveAgain() async throws {
    let session = SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) })
    let surveys = AccountRequestGate<SurveyResponse>()
    defer { surveys.releaseAll() }
    let model = makeTestAppModel(
      sessionFeature: session,
      activityFeature: ActivityFeature(
        sessionFeature: session, makeProvider: { AsyncActivityProvider(service: MockService()) },
        loadSurvey: { _ in try await surveys.request() }
      )
    )
    let first = Task { try await model.resolveDeepLink(.user(.id(1), .survey(2)), discoveryResponseDelay: 0) }
    await surveys.waitFor(1)
    session.sessionChanged()
    try surveys.finish(0, .failure(ErrorEnvelope.couldNotParseJSON))
    guard case .failure(is CancellationError) = await first.result else {
      return XCTFail("An obsolete survey result escaped the AppModel boundary")
    }

    let current = Task { try await model.resolveDeepLink(.user(.id(1), .survey(2)), discoveryResponseDelay: 0) }
    await surveys.waitFor(2)
    try surveys.finish(1, .success(.template))
    guard case let .survey(url)? = try await current.value else { return XCTFail("Expected the survey URL") }
    XCTAssertEqual(url, SurveyResponse.template.urls.web.survey)
  }

  func testCancelledDeepLinkCallerDoesNotStartFeatureWork() async {
    let session = SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) })
    var surveyRequests = 0
    let model = makeTestAppModel(
      sessionFeature: session,
      activityFeature: ActivityFeature(
        sessionFeature: session, makeProvider: { AsyncActivityProvider(service: MockService()) },
        loadSurvey: { _ in surveyRequests += 1; return .template }
      )
    )
    let task = Task { try await model.resolveDeepLink(.user(.id(1), .survey(2)), discoveryResponseDelay: 0) }
    task.cancel()
    guard case .failure(is CancellationError) = await task.result else {
      return XCTFail("Cancelled link resolution must throw cancellation")
    }
    XCTAssertEqual(surveyRequests, 0)
  }

  func testAccountUpdateCannotStartRecommendationsAfterSynchronousSessionReplacement() async {
    let user = User.template
    let session = SessionFeature(
      makeProvider: { AsyncSessionProvider(service: MockService(fetchUserSelfResponse: user)) },
      currentUser: { user }, updateUser: { _ in }
    )
    let settings = SettingsFeature(
      sessionFeature: session, refreshDebounce: {},
      makeProvider: { AsyncAccountPreferencesProvider(service: MockService()) }
    )
    let discovery = DiscoveryFeature(provider: NoRequestDiscoveryProvider(), sessionFeature: session)
    let model = makeTestAppModel(sessionFeature: session, settingsFeature: settings, discoveryFeature: discovery)
    var userUpdates = 0

    model.refreshAccount { update in
      switch update {
      case let .user(updated):
        XCTAssertEqual(updated.id, user.id)
        userUpdates += 1
        session.sessionChanged()
      default: XCTFail("An obsolete account refresh delivered another event")
      }
    }
    await settings.waitForScheduledAccountRefresh()
    await discovery.waitForRecommendationRefresh()
    XCTAssertEqual(userUpdates, 1)
  }

  func testEnteringBackgroundPublishesTheApplicationNotification() {
    let notificationCenter = NotificationCenter()
    let received = self.expectation(description: "Application entered background")
    let observer = notificationCenter.addObserver(
      forName: .ksr_applicationDidEnterBackground, object: nil, queue: nil
    ) { notification in
      XCTAssertNil(notification.object)
      received.fulfill()
    }
    defer { notificationCenter.removeObserver(observer) }

    AppModel.live().applicationDidEnterBackground(notificationCenter: notificationCenter)

    self.wait(for: [received], timeout: 0)
  }

  func testLaunchForegroundAndSessionChangesApplyConfigurationAndInstallVisitorCookies() async throws {
    let model = AppModel.live()
    var publishedCountries: [String] = []
    let observer = MainActorNotificationObservation(name: .ksr_configUpdated) { _ in
      if let country = AppEnvironment.current.config?.countryCode {
        publishedCountries.append(country)
      }
    }
    defer { observer.cancel() }

    func verifyRefresh(
      country: String, user: User? = nil, preserveExistingCookie: Bool = true,
      perform: @MainActor () async -> Void
    ) async throws {
      let config = Config.template |> Config.lens.countryCode .~ country
      let service = MockService(fetchConfigResponse: config)
      let apiHost = try XCTUnwrap(service.serverConfig.apiBaseUrl.host)
      let webHost = try XCTUnwrap(service.serverConfig.webBaseUrl.host)
      let storage = MockCookieStorage()
      let existingCookie = try XCTUnwrap(HTTPCookie(properties: [
        .name: "existing-cookie", .value: "existing-cookie-value", .domain: apiHost, .path: "/"
      ]))
      if preserveExistingCookie { storage.setCookie(existingCookie) }

      await withEnvironment(apiService: service, cookieStorage: storage, currentUser: user, device: MockDevice()) {
        await perform()
      }

      let cookies = try XCTUnwrap(storage.cookies)
      let visitorCookies = cookies.filter { $0.name == "vis" }
      XCTAssertEqual(visitorCookies.map(\.domain).sorted(), [apiHost, webHost].sorted())
      XCTAssertEqual(visitorCookies.map(\.value), Array(repeating: "DEADBEEF-DEAD-BEEF-DEAD-DEADBEEFBEEF", count: 2))
      XCTAssertEqual(cookies.filter { $0.name != "vis" }, preserveExistingCookie ? [existingCookie] : [])
    }

    try await verifyRefresh(country: "US", preserveExistingCookie: false) {
      await model.applicationDidFinishLaunching()
      await model.applicationDidFinishLaunching()
    }
    XCTAssertEqual(publishedCountries, ["US"])

    try await verifyRefresh(country: "GB") {
      model.applicationWillEnterForeground()
      _ = await model.settingsFeature.requestApplicationSettings().result
    }

    try await verifyRefresh(country: "CA", user: .template) {
      model.sessionChanged()
      _ = await model.settingsFeature.requestApplicationSettings().result
    }

    try await verifyRefresh(country: "CZ") {
      model.sessionChanged()
      _ = await model.settingsFeature.requestApplicationSettings().result
    }
    XCTAssertEqual(publishedCountries, ["US", "GB", "CA", "CZ"])
  }

  func testGraphsRetainTheirInjectedFeaturesWithoutSharingState() async {
    let firstProvider = NoRequestSearchProvider()
    let secondProvider = NoRequestSearchProvider()
    let firstFeature = SearchFeature(provider: firstProvider)
    let secondFeature = SearchFeature(provider: secondProvider)
    let firstSession = SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) })
    let secondSession = SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) })
    let firstDiscussion = DiscussionFeature(platform: .live(), sessionFeature: firstSession, makeProvider: { AsyncDiscussionProvider(service: MockService()) })
    let firstDetails =
      ProjectDetailsFeature(platform: .live(), sessionFeature: firstSession,
      discussionFeature: firstDiscussion,
      makeProvider: { AsyncProjectDetailsProvider(service: MockService()) },
      useFastLoading: { false }, includeRichText: { false })
    let secondDiscussion = DiscussionFeature(platform: .live(), sessionFeature: secondSession, makeProvider: { AsyncDiscussionProvider(service: MockService()) })
    let secondDetails =
      ProjectDetailsFeature(platform: .live(), sessionFeature: secondSession,
      discussionFeature: secondDiscussion,
      makeProvider: { AsyncProjectDetailsProvider(service: MockService()) },
      useFastLoading: { false }, includeRichText: { false })
    let firstSettings = SettingsFeature(sessionFeature: firstSession, makeProvider: {
        AsyncAccountPreferencesProvider(service: MockService())
      })
    let firstMessaging = MessagingFeature(sessionFeature: firstSession, makeProvider: { AsyncMessagingProvider(service: MockService()) })
    let firstActivity = ActivityFeature(
      sessionFeature: firstSession,
      makeProvider: { AsyncActivityProvider(service: MockService()) }
    )
    let firstDiscovery = DiscoveryFeature(
      provider: NoRequestDiscoveryProvider(),
      sessionFeature: firstSession
    )
    let firstOnboarding = OnboardingFeature(completionStore: { [store = MockKeyValueStore()] in store })
    let first = AppModel(
      developerExamplesFeature: DeveloperExamplesFeature(sessionFeature: firstSession, makeProvider: {
        XCTFail("Composition must not load developer examples")
        return AsyncDeveloperExamplesProvider(service: MockService())
      }),
      onboardingFeature: firstOnboarding,
      creatorDraftsFeature: CreatorDraftsFeature(sessionFeature: firstSession, makeProvider: {
        XCTFail("Composition must not load creator drafts")
        return AsyncCreatorDraftsProvider(service: MockService())
      }),
      recommendationsFeature: RecommendationsFeature(platform: .test(), settingsFeature: firstSettings, makeProvider: {
        XCTFail("Composition must not perform recommendation requests")
        return AsyncRecommendationsProvider(service: MockService())
      }),
      projectReportingFeature: ProjectReportingFeature(sessionFeature: firstSession, makeProvider: { AsyncProjectReportingProvider(service: MockService()) }),
      friendsFeature: FriendsFeature(sessionFeature: firstSession, makeProvider: { AsyncFriendsProvider(service: MockService()) }),
      pledgedProjectsFeature: PledgedProjectsFeature(
        sessionFeature: firstSession, settingsFeature: firstSettings,
        makeProvider: { AsyncPledgedProjectsProvider(service: MockService()) },
        locale: { Locale(identifier: "en_US") }
      ),
      pledgeFeature: PledgeFeature(platform: .live(), sessionFeature: firstSession, makeProvider: { AsyncPledgeProvider(service: MockService()) }),
      paymentsFeature: PaymentsFeature(sessionFeature: firstSession, makeProvider: { AsyncPaymentsProvider(service: MockService()) }),
      messagingFeature: firstMessaging,
      sessionFeature: firstSession,
      authenticationFeature: AuthenticationFeature(sessionFeature: firstSession, makeProvider: {
        AsyncAuthenticationProvider(service: MockService())
      }),
      settingsFeature: firstSettings,
      activityFeature: firstActivity,
      profileFeature: ProfileFeature(
        sessionFeature: firstSession,
        makeProvider: { AsyncProfileProvider(service: MockService()) }
      ),
      helpFeature: HelpFeature(
        webBaseURL: { ServerConfig.production.webBaseUrl },
        prepareRequest: { URLRequest(url: $0) }
      ),
      searchFeature: firstFeature,
      discoveryFeature: firstDiscovery,
      projectDetailsFeature: firstDetails,
      rewardsFeature: RewardsFeature(platform: .live(), sessionFeature: firstSession, makeProvider: { AsyncRewardsProvider(service: MockService()) }),
      discussionFeature: firstDiscussion,
      projectMediaFeature: ProjectMediaFeature(sessionFeature: firstSession, makeProvider: {
        AsyncProjectMediaProvider(service: MockService())
      })
    )
    XCTAssertTrue(first.projectDetailsFeature.discussionFeature === first.discussionFeature)
    let secondSettings = SettingsFeature(sessionFeature: secondSession, makeProvider: {
        AsyncAccountPreferencesProvider(service: MockService())
      })
    let secondMessaging = MessagingFeature(sessionFeature: secondSession, makeProvider: { AsyncMessagingProvider(service: MockService()) })
    let secondActivity = ActivityFeature(
      sessionFeature: secondSession,
      makeProvider: { AsyncActivityProvider(service: MockService()) }
    )
    let secondDiscovery = DiscoveryFeature(
      provider: NoRequestDiscoveryProvider(),
      sessionFeature: secondSession
    )
    let secondOnboarding = OnboardingFeature(completionStore: { [store = MockKeyValueStore()] in store })
    let second = AppModel(
      developerExamplesFeature: DeveloperExamplesFeature(sessionFeature: secondSession, makeProvider: {
        XCTFail("Composition must not load developer examples")
        return AsyncDeveloperExamplesProvider(service: MockService())
      }),
      onboardingFeature: secondOnboarding,
      creatorDraftsFeature: CreatorDraftsFeature(sessionFeature: secondSession, makeProvider: {
        XCTFail("Composition must not load creator drafts")
        return AsyncCreatorDraftsProvider(service: MockService())
      }),
      recommendationsFeature: RecommendationsFeature(platform: .test(), settingsFeature: secondSettings, makeProvider: {
        XCTFail("Composition must not perform recommendation requests")
        return AsyncRecommendationsProvider(service: MockService())
      }),
      projectReportingFeature: ProjectReportingFeature(sessionFeature: secondSession, makeProvider: { AsyncProjectReportingProvider(service: MockService()) }),
      friendsFeature: FriendsFeature(sessionFeature: secondSession, makeProvider: { AsyncFriendsProvider(service: MockService()) }),
      pledgedProjectsFeature: PledgedProjectsFeature(
        sessionFeature: secondSession, settingsFeature: secondSettings,
        makeProvider: { AsyncPledgedProjectsProvider(service: MockService()) },
        locale: { Locale(identifier: "en_US") }
      ),
      pledgeFeature: PledgeFeature(platform: .live(), sessionFeature: secondSession, makeProvider: { AsyncPledgeProvider(service: MockService()) }),
      paymentsFeature: PaymentsFeature(sessionFeature: secondSession, makeProvider: { AsyncPaymentsProvider(service: MockService()) }),
      messagingFeature: secondMessaging,
      sessionFeature: secondSession,
      authenticationFeature: AuthenticationFeature(sessionFeature: secondSession, makeProvider: {
        AsyncAuthenticationProvider(service: MockService())
      }),
      settingsFeature: secondSettings,
      activityFeature: secondActivity,
      profileFeature: ProfileFeature(
        sessionFeature: secondSession,
        makeProvider: { AsyncProfileProvider(service: MockService()) }
      ),
      helpFeature: HelpFeature(
        webBaseURL: { ServerConfig.production.webBaseUrl },
        prepareRequest: { URLRequest(url: $0) }
      ),
      searchFeature: secondFeature,
      discoveryFeature: secondDiscovery,
      projectDetailsFeature: secondDetails,
      rewardsFeature: RewardsFeature(platform: .live(), sessionFeature: secondSession, makeProvider: { AsyncRewardsProvider(service: MockService()) }),
      discussionFeature: secondDiscussion,
      projectMediaFeature: ProjectMediaFeature(sessionFeature: secondSession, makeProvider: {
        AsyncProjectMediaProvider(service: MockService())
      })
    )

    XCTAssertTrue(first.developerExamplesFeature.sessionFeature === first.sessionFeature)
    XCTAssertFalse(first.developerExamplesFeature === second.developerExamplesFeature)
    XCTAssertTrue(first.creatorDraftsFeature.sessionFeature === first.sessionFeature)
    XCTAssertFalse(first.creatorDraftsFeature === second.creatorDraftsFeature)
    XCTAssertTrue(first.recommendationsFeature.settingsFeature === first.settingsFeature)
    XCTAssertTrue(first.recommendationsFeature.sessionFeature === first.sessionFeature)
    XCTAssertFalse(first.recommendationsFeature === second.recommendationsFeature)
    XCTAssertTrue(first.projectReportingFeature.sessionFeature === first.sessionFeature)
    XCTAssertFalse(first.projectReportingFeature === second.projectReportingFeature)
    XCTAssertTrue(first.friendsFeature.sessionFeature === first.sessionFeature)
    XCTAssertFalse(first.friendsFeature === second.friendsFeature)
    XCTAssertFalse(first.pledgedProjectsFeature === second.pledgedProjectsFeature)
    XCTAssertFalse(first.pledgeFeature === second.pledgeFeature)
    XCTAssertFalse(first.paymentsFeature === second.paymentsFeature)
    XCTAssertTrue(
      first.pledgedProjectsComposition.pledgedProjectsFeature === first.pledgedProjectsFeature
    )
    XCTAssertTrue(
      first.pledgedProjectsComposition.activities.activityFeature === first.activityFeature
    )
    XCTAssertTrue(
      first.pledgedProjectsComposition.activities.projectPage.managePledge.pledgeFeature
        === first.pledgeFeature
    )
    XCTAssertTrue(
      first.pledgedProjectsComposition.activities.projectPage.managePledge.paymentsFeature
        === first.paymentsFeature
    )
    XCTAssertTrue(
      first.pledgedProjectsComposition.activities.projectPage.managePledge.rewardsFeature
        === first.rewardsFeature
    )
    XCTAssertTrue(
      first.rootTabComposition.pledgedProjects.pledgedProjectsFeature
        === first.pledgedProjectsFeature
    )
    XCTAssertTrue(first.messagingFeature.sessionFeature === first.sessionFeature)
    XCTAssertFalse(first.messagingFeature === second.messagingFeature)
    XCTAssertTrue(first.activityFeature.sessionFeature === first.sessionFeature)
    XCTAssertTrue(first.profileFeature.sessionFeature === first.sessionFeature)
    XCTAssertFalse(first.sessionFeature === second.sessionFeature)
    XCTAssertFalse(first.authenticationFeature === second.authenticationFeature)
    XCTAssertFalse(first.settingsFeature === second.settingsFeature)
    XCTAssertFalse(first.activityFeature === second.activityFeature)
    XCTAssertFalse(first.profileFeature === second.profileFeature)
    XCTAssertFalse(first.helpFeature === second.helpFeature)
    XCTAssertTrue(first.searchFeature === firstFeature)
    XCTAssertTrue(second.searchFeature === secondFeature)
    XCTAssertFalse(first.searchFeature === second.searchFeature)
    XCTAssertFalse(first.discoveryFeature === second.discoveryFeature)
    XCTAssertTrue(first.projectDetailsFeature.sessionFeature === first.sessionFeature)
    XCTAssertTrue(first.projectDetailsFeature === firstDetails)
    XCTAssertTrue(second.projectDetailsFeature === secondDetails)
    XCTAssertFalse(first.projectDetailsFeature === second.projectDetailsFeature)
    XCTAssertFalse(first.rewardsFeature === second.rewardsFeature)
    XCTAssertFalse(first.discussionFeature === second.discussionFeature)
    XCTAssertFalse(first.projectMediaFeature === second.projectMediaFeature)
    XCTAssertTrue(first.projectMediaFeature.sessionFeature === first.sessionFeature)
    XCTAssertTrue(
      first.projectPageComposition.projectDetailsFeature === first.projectDetailsFeature
    )
    XCTAssertTrue(first.projectPageComposition.projectMediaFeature === first.projectMediaFeature)
    XCTAssertTrue(
      first.projectPageComposition.projectReportingFeature === first.projectReportingFeature
    )
    XCTAssertTrue(
      first.projectPageComposition.managePledge.pledgeFeature === first.pledgeFeature
    )
    XCTAssertTrue(
      first.projectPageComposition.managePledge.paymentsFeature === first.paymentsFeature
    )
    XCTAssertTrue(
      first.projectPageComposition.managePledge.rewardsFeature === first.rewardsFeature
    )
    XCTAssertTrue(
      first.projectPageComposition.managePledge.messagingFeature === first.messagingFeature
    )
    XCTAssertTrue(first.pledgeCheckoutComposition.pledgeFeature === first.pledgeFeature)
    XCTAssertTrue(
      first.pledgeCheckoutComposition.authenticationFeature === first.authenticationFeature
    )
    XCTAssertTrue(first.pledgeCheckoutComposition.paymentsFeature === first.paymentsFeature)
    XCTAssertTrue(first.rootTabComposition.sessionFeature === first.sessionFeature)
    XCTAssertTrue(first.rootTabComposition.profileFeature === first.profileFeature)
    XCTAssertTrue(first.activityComposition.activityFeature === first.activityFeature)
    XCTAssertTrue(
      first.activityComposition.projectPage.managePledge.pledgeFeature === first.pledgeFeature
    )
    XCTAssertTrue(
      first.rootTabComposition.activities.activityFeature === first.activityFeature
    )
    XCTAssertTrue(
      first.rootTabComposition.messaging.messagingFeature === first.messagingFeature
    )
    XCTAssertTrue(
      first.messagingComposition.discussionFeature === first.discussionFeature
    )
    XCTAssertTrue(
      first.messagingComposition.projectPage.managePledge.pledgeFeature === first.pledgeFeature
    )
    XCTAssertTrue(first.rootTabComposition.settingsFeature === first.settingsFeature)
    XCTAssertTrue(first.managePledgeComposition.pledgeFeature === first.pledgeFeature)
    XCTAssertTrue(first.managePledgeComposition.paymentsFeature === first.paymentsFeature)
    XCTAssertTrue(first.managePledgeComposition.rewardsFeature === first.rewardsFeature)
    XCTAssertTrue(first.managePledgeComposition.messagingFeature === first.messagingFeature)
    XCTAssertTrue(
      first.managePledgeComposition.checkout.pledgeFeature === first.pledgeFeature
    )
    XCTAssertTrue(first.discoveryFeature.snapshot(for: .magic).projects.isEmpty)
    XCTAssertEqual(firstProvider.requestCount, 0)
    XCTAssertEqual(secondProvider.requestCount, 0)
    XCTAssertNil(first.searchFeature.parameters)
    XCTAssertNil(second.searchFeature.parameters)
    let secondPledgeSession = second.pledgeFeature.sessionIdentity
    let secondPaymentsSession = second.paymentsFeature.sessionIdentity
    first.sessionChanged()
    _ = await first.settingsFeature.requestApplicationSettings().result
    XCTAssertEqual(first.sessionFeature.generation, 1)
    XCTAssertEqual(second.sessionFeature.generation, 0)
    XCTAssertEqual(first.pledgeFeature.sessionIdentity.generation, first.sessionFeature.generation)
    XCTAssertNotEqual(first.pledgeFeature.sessionIdentity, secondPledgeSession)
    XCTAssertEqual(second.pledgeFeature.sessionIdentity, secondPledgeSession)
    XCTAssertEqual(first.paymentsFeature.sessionIdentity.generation, first.sessionFeature.generation)
    XCTAssertNotEqual(first.paymentsFeature.sessionIdentity, secondPaymentsSession)
    XCTAssertEqual(second.paymentsFeature.sessionIdentity, secondPaymentsSession)
  }
}

@MainActor
private final class NoRequestSearchProvider: SearchProjectsProvider {
  private(set) var requestCount = 0

  func fetchPage(
    parameters _: DiscoveryParams, cursor _: String?
  ) async throws -> SearchPageResponse {
    self.requestCount += 1
    throw CancellationError()
  }
}

@MainActor
private struct NoRequestDiscoveryProvider: DiscoveryProvider {
  func page(parameters _: DiscoveryParams, cursor _: String?) async throws -> DiscoveryEnvelope {
    XCTFail("Composition must not perform requests")
    throw CancellationError()
  }

  func activitySample() async throws -> ActivityEnvelope? {
    XCTFail("Composition must not perform requests")
    throw CancellationError()
  }
}

@MainActor
private struct NoDeviceRegistrationProvider: SessionProvider {
  func setup() async throws -> GraphUserSetup { throw CancellationError() }
  func user() async throws -> User { throw CancellationError() }
  func graphUser() async throws -> User { throw CancellationError() }
  func clearActivityIndicator() async throws -> Int { throw CancellationError() }
  func registerDeviceToken(_: String) async throws {
    XCTFail("Obsolete device registration reached the transport")
    throw CancellationError()
  }
}
