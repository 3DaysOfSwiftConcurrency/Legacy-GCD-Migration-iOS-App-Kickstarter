import AppTrackingTransparency
@testable import Kickstarter_iOS
import GraphAPI
@testable import KsApi

import Prelude
import UserNotifications
import XCTest

@MainActor
final class AppModelTests: XCTestCase {
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

  func testShortcutRefreshDropsResultAfterSameUserSessionReplacement() async throws {
    let user = User.template
    let session = SessionFeature(
      makeProvider: { AsyncSessionProvider(service: MockService()) },
      currentUser: { user }
    )
    let gate = AccountRequestGate<Bool>()
    defer { gate.releaseAll() }
    let shortcuts = ApplicationShortcutService(session: session, hasRecommendations: { _ in
      try await gate.request()
    })
    var results: [Bool] = []

    shortcuts.refresh(for: user) { results.append($0) }
    await gate.waitFor(1)
    session.sessionChanged()
    try gate.finish(0, .success(true))
    await shortcuts.waitForRefresh()
    XCTAssertEqual(results, [])

    shortcuts.refresh(for: user) { results.append($0) }
    await gate.waitFor(2)
    try gate.finish(1, .success(false))
    await shortcuts.waitForRefresh()
    XCTAssertEqual(results, [false])
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
      _ = await model.applicationConfigurationService.requestConfiguration().result
    }

    try await verifyRefresh(country: "CA", user: .template) {
      model.sessionChanged()
      _ = await model.applicationConfigurationService.requestConfiguration().result
    }

    try await verifyRefresh(country: "CZ") {
      model.sessionChanged()
      _ = await model.applicationConfigurationService.requestConfiguration().result
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
      currentUser: { firstSession.currentUser }
    )
    let firstOnboarding = OnboardingFeature(completionStore: { [store = MockKeyValueStore()] in store })
    let first = AppModel(
      developerExamplesFeature: DeveloperExamplesFeature(sessionFeature: firstSession, makeProvider: {
        XCTFail("Composition must not load developer examples")
        return AsyncDeveloperExamplesProvider(service: MockService())
      }),
      onboardingFeature: firstOnboarding,
      remoteConfigurationService: RemoteConfigurationService(notificationCenter: NotificationCenter()),
      applicationConfigurationService: ApplicationConfigurationService(load: { .template }),
      devicePushRegistrationService: DevicePushRegistrationService(register: { _ in
        XCTFail("Composition must not register for push")
      }),
      creatorDraftsFeature: CreatorDraftsFeature(sessionFeature: firstSession, makeProvider: {
        XCTFail("Composition must not load creator drafts")
        return AsyncCreatorDraftsProvider(service: MockService())
      }),
      recommendationsFeature: RecommendationsFeature(settingsFeature: firstSettings, makeProvider: {
        XCTFail("Composition must not perform recommendation requests")
        return AsyncRecommendationsProvider(service: MockService())
      }),
      projectReportingFeature: ProjectReportingFeature(sessionFeature: firstSession, makeProvider: { AsyncProjectReportingProvider(service: MockService()) }),
      friendsFeature: FriendsFeature(sessionFeature: firstSession, makeProvider: { AsyncFriendsProvider(service: MockService()) }),
      pledgedProjectsFeature: PledgedProjectsFeature(sessionFeature: firstSession, makeProvider: { AsyncPledgedProjectsProvider(service: MockService()) }),
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
      currentUser: { secondSession.currentUser }
    )
    let secondOnboarding = OnboardingFeature(completionStore: { [store = MockKeyValueStore()] in store })
    let second = AppModel(
      developerExamplesFeature: DeveloperExamplesFeature(sessionFeature: secondSession, makeProvider: {
        XCTFail("Composition must not load developer examples")
        return AsyncDeveloperExamplesProvider(service: MockService())
      }),
      onboardingFeature: secondOnboarding,
      remoteConfigurationService: RemoteConfigurationService(notificationCenter: NotificationCenter()),
      applicationConfigurationService: ApplicationConfigurationService(load: { .template }),
      devicePushRegistrationService: DevicePushRegistrationService(register: { _ in
        XCTFail("Composition must not register for push")
      }),
      creatorDraftsFeature: CreatorDraftsFeature(sessionFeature: secondSession, makeProvider: {
        XCTFail("Composition must not load creator drafts")
        return AsyncCreatorDraftsProvider(service: MockService())
      }),
      recommendationsFeature: RecommendationsFeature(settingsFeature: secondSettings, makeProvider: {
        XCTFail("Composition must not perform recommendation requests")
        return AsyncRecommendationsProvider(service: MockService())
      }),
      projectReportingFeature: ProjectReportingFeature(sessionFeature: secondSession, makeProvider: { AsyncProjectReportingProvider(service: MockService()) }),
      friendsFeature: FriendsFeature(sessionFeature: secondSession, makeProvider: { AsyncFriendsProvider(service: MockService()) }),
      pledgedProjectsFeature: PledgedProjectsFeature(sessionFeature: secondSession, makeProvider: { AsyncPledgedProjectsProvider(service: MockService()) }),
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
    XCTAssertTrue(first.messagingFeature.sessionFeature === first.sessionFeature)
    XCTAssertFalse(first.messagingFeature === second.messagingFeature)
    XCTAssertTrue(first.activityFeature.sessionFeature === first.sessionFeature)
    XCTAssertTrue(first.profileFeature.sessionFeature === first.sessionFeature)
    XCTAssertFalse(first.sessionFeature === second.sessionFeature)
    XCTAssertFalse(first.authenticationFeature === second.authenticationFeature)
    XCTAssertFalse(first.settingsFeature === second.settingsFeature)
    XCTAssertFalse(first.activityFeature === second.activityFeature)
    XCTAssertFalse(first.profileFeature === second.profileFeature)
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
    XCTAssertTrue(first.discoveryFeature.snapshot(for: .magic).projects.isEmpty)
    XCTAssertEqual(firstProvider.requestCount, 0)
    XCTAssertEqual(secondProvider.requestCount, 0)
    XCTAssertNil(first.searchFeature.parameters)
    XCTAssertNil(second.searchFeature.parameters)
    let secondPledgeSession = second.pledgeFeature.sessionIdentity
    let secondPaymentsSession = second.paymentsFeature.sessionIdentity
    first.sessionChanged()
    _ = await first.applicationConfigurationService.requestConfiguration().result
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
final class RemoteConfigurationServiceTests: XCTestCase {
  func testSharedActivationReportsFailureOnceAndPublishesSuccessAfterRetry() async throws {
    let center = NotificationCenter()
    var reportedErrors: [URLError.Code] = []
    let service = RemoteConfigurationService(notificationCenter: center) { error in
      if let error = error as? URLError { reportedErrors.append(error.code) }
    }
    var notifications: [Notification.Name] = []
    let observers = [
      MainActorNotificationObservation(center: center, name: .ksr_remoteConfigClientConfigured) {
        notifications.append($0.name)
      },
      MainActorNotificationObservation(center: center, name: .ksr_remoteConfigClientConfigurationFailed) {
        notifications.append($0.name)
      }
    ]
    defer { observers.forEach { $0.cancel() } }

    let gate = AccountRequestGate<Void>()
    let client = GatedRemoteConfigClient(gate: gate)
    defer { gate.releaseAll() }
    let first = service.activate(client: client)
    let second = service.activate(client: client)
    await gate.waitFor(1)
    try gate.finish(0, .failure(URLError(.notConnectedToInternet)))
    for request in [first, second] {
      if case .success = await request.result { XCTFail("Failure was swallowed") }
    }
    XCTAssertEqual(notifications, [.ksr_remoteConfigClientConfigurationFailed])
    XCTAssertEqual(reportedErrors, [.notConnectedToInternet])

    let retry = service.activate(client: client)
    await gate.waitFor(2)
    try gate.finish(1, .success(()))
    try await retry.value
    XCTAssertEqual(gate.count, 2)
    XCTAssertEqual(notifications, [.ksr_remoteConfigClientConfigurationFailed, .ksr_remoteConfigClientConfigured])
    XCTAssertEqual(reportedErrors, [.notConnectedToInternet])
  }

  func testReplacingClientSuppressesBothLateSuccessAndLateFailure() async throws {
    let center = NotificationCenter()
    let service = RemoteConfigurationService(notificationCenter: center) { _ in
      XCTFail("Obsolete client error was reported")
    }
    var publishedSuccesses = 0
    let configured = MainActorNotificationObservation(center: center, name: .ksr_remoteConfigClientConfigured) {
      _ in publishedSuccesses += 1
    }
    let failed = MainActorNotificationObservation(center: center, name: .ksr_remoteConfigClientConfigurationFailed) {
      _ in XCTFail("Obsolete client failure was published")
    }
    defer { configured.cancel(); failed.cancel() }

    for obsoleteResult: Result<Void, Error> in [.success(()), .failure(URLError(.notConnectedToInternet))] {
      let gate = AccountRequestGate<Void>()
      defer { gate.releaseAll() }
      let old = service.activate(client: GatedRemoteConfigClient(gate: gate))
      await gate.waitFor(1)
      let replacement = service.activate(client: GatedRemoteConfigClient(gate: gate))
      await gate.waitFor(2)
      try gate.finish(1, .success(()))
      try await replacement.value
      try gate.finish(0, obsoleteResult)
      if case .success = await old.result { XCTFail("Replaced activation completed") }
    }
    XCTAssertEqual(publishedSuccesses, 2)
  }
}

private final class GatedRemoteConfigClient: MockRemoteConfigClient {
  private let gate: AccountRequestGate<Void>

  init(gate: AccountRequestGate<Void>) {
    self.gate = gate
    super.init()
  }

  override func fetchAndActivateAsync() async throws {
    try await self.gate.request()
  }
}

@MainActor
final class ApplicationConfigurationServiceTests: XCTestCase {
  func testLiveRefreshPreservesDebugOverridesAndUsesServerFlagsInRelease() async {
    let stored = Config.template |> Config.lens.features .~ [
      "enabled_flag": true, "disabled_flag": false, "removed_flag": true
    ]
    let incoming = Config.template |> Config.lens.features .~ [
      "enabled_flag": false, "disabled_flag": true, "new_flag": true
    ]
    let apiService = MockService(fetchConfigResponse: incoming)
    let debugBundle = MockBundle(bundleIdentifier: KickstarterBundleIdentifier.beta.rawValue)

    await withEnvironment(apiService: apiService, config: stored, cookieStorage: MockCookieStorage(),
                          mainBundle: debugBundle) {
      _ = await ApplicationConfigurationService.live().refresh().result
      XCTAssertEqual(AppEnvironment.current.config?.features, [
        "enabled_flag": true, "disabled_flag": false, "new_flag": true
      ])
    }

    let releaseBundle = MockBundle(bundleIdentifier: KickstarterBundleIdentifier.release.rawValue)
    await withEnvironment(apiService: apiService, config: stored, cookieStorage: MockCookieStorage(),
                          mainBundle: releaseBundle) {
      _ = await ApplicationConfigurationService.live().refresh().result
      XCTAssertEqual(AppEnvironment.current.config?.features, incoming.features)
    }
  }

  func testEquivalentPrefetchesShareWithoutApplyingConfiguration() async throws {
    let gate = AccountRequestGate<Config>()
    defer { gate.releaseAll() }
    let service = ApplicationConfigurationService(
      load: { try await gate.request() },
      applyConfiguration: { _ in XCTFail("Prefetch applied configuration") }
    )
    let first = service.requestConfiguration()
    let second = service.requestConfiguration()
    await gate.waitFor(1)
    try gate.finish(0, .success(.template))
    _ = try await first.value
    _ = try await second.value
    let next = service.requestConfiguration()
    await gate.waitFor(2)
    try gate.finish(1, .success(.template))
    _ = try await next.value
    XCTAssertEqual(gate.count, 2)
  }

  func testResetRejectsAnOldConfiguration() async throws {
    let gate = AccountRequestGate<Config>()
    defer { gate.releaseAll() }
    var applied: [Config] = []
    let service = ApplicationConfigurationService(
      load: { try await gate.request() },
      applyConfiguration: { applied.append($0) }
    )
    let old = service.refresh()
    await gate.waitFor(1)
    service.reset()
    let current = service.refresh()
    await gate.waitFor(2)
    try gate.finish(0, .success(.template))
    try gate.finish(1, .success(.template))
    if case .success = await old.result { XCTFail("Reset configuration completed") }
    let config = try await current.value
    XCTAssertEqual(applied, [config])
  }

  func testConcurrentRefreshesApplyASharedPrefetchOnce() async throws {
    let gate = AccountRequestGate<Config>()
    defer { gate.releaseAll() }
    var applied: [Config] = []
    let service = ApplicationConfigurationService(
      load: { try await gate.request() },
      applyConfiguration: { applied.append($0) }
    )
    let prefetch = service.requestConfiguration()
    await gate.waitFor(1)
    let first = service.refresh()
    let second = service.refresh()
    try gate.finish(0, .success(.template))
    _ = try await first.value
    _ = try await second.value
    let config = try await prefetch.value
    XCTAssertEqual(gate.count, 1)
    XCTAssertEqual(applied, [config])
  }
}

@MainActor
final class DevicePushRegistrationServiceTests: XCTestCase {
  func testReceivesRawTokensInOrderAndDebouncesHexServerRegistration() async {
    let first = Data([0x01, 0xff])
    let latest = Data([0x00, 0x0a, 0xbe])
    var forwarded: [Data] = []
    var registered: [String] = []
    var delivered: [String] = []
    let service = DevicePushRegistrationService(
      register: { registered.append($0) }, debounce: { try Task.checkCancellation() }
    )

    service.receive(deviceToken: first, registerWithMessagingSDK: { forwarded.append($0) }) {
      delivered.append($0)
    }
    service.receive(deviceToken: latest, registerWithMessagingSDK: { forwarded.append($0) }) {
      delivered.append($0)
    }

    XCTAssertEqual(forwarded, [first, latest])
    XCTAssertTrue(registered.isEmpty)
    await service.waitForScheduledDelivery()
    XCTAssertEqual(registered, ["000abe"])
    XCTAssertEqual(delivered, registered)
  }

  func testSessionChangePreventsDebouncedRegistration() async throws {
    let gate = AccountRequestGate<Void>()
    defer { gate.releaseAll() }
    var registeredTokens: [String] = []
    let service = DevicePushRegistrationService(
      register: { registeredTokens.append($0) },
      debounce: { try await gate.request() }
    )
    service.receive(deviceToken: Data([0x01]), registerWithMessagingSDK: { _ in }) { _ in
      XCTFail("Unexpected registration delivery")
    }
    await gate.waitFor(1)
    service.sessionChanged()
    try gate.finish(0, .success(()))
    await service.waitForScheduledDelivery()
    XCTAssertTrue(registeredTokens.isEmpty)
  }

  func testDuplicatesShareAndChangedTokensExecuteInOrderAfterFailure() async throws {
    let gate = AccountRequestGate<Void>()
    var tokens: [String] = []
    let service = DevicePushRegistrationService(register: { token in
      tokens.append(token)
      try await gate.request()
    })
    defer { gate.releaseAll() }
    let first = service.request(token: "synthetic-a")
    let duplicate = service.request(token: "synthetic-a")
    let second = service.request(token: "synthetic-b")
    await gate.waitFor(1)
    XCTAssertEqual(tokens, ["synthetic-a"])
    try gate.finish(0, .failure(ErrorEnvelope.couldNotParseJSON))
    await gate.waitFor(2)
    try gate.finish(1, .success(()))
    if case .success = await first.result { XCTFail("Failure was swallowed") }
    if case .success = await duplicate.result { XCTFail("Failure was swallowed") }
    let registeredToken = try await second.value
    XCTAssertEqual(registeredToken, "synthetic-b")
    XCTAssertEqual(tokens, ["synthetic-a", "synthetic-b"])
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
