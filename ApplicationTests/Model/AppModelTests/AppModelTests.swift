@testable import Kickstarter_iOS
import GraphAPI
@testable import KsApi

import XCTest

@MainActor
final class AppModelTests: XCTestCase {
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

  func testGraphsRetainTheirInjectedFeaturesWithoutSharingState() {
    let firstProvider = NoRequestSearchProvider()
    let secondProvider = NoRequestSearchProvider()
    let firstFeature = SearchFeature(provider: firstProvider)
    let secondFeature = SearchFeature(provider: secondProvider)
    let firstSession = SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) })
    let secondSession = SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) })
    let firstDiscussion = DiscussionFeature(sessionFeature: firstSession, makeProvider: { AsyncDiscussionProvider(service: MockService()) })
    let firstDetails =
      ProjectDetailsFeature(sessionFeature: firstSession,
      discussionFeature: firstDiscussion,
      makeProvider: { AsyncProjectDetailsProvider(service: MockService()) })
    let secondDiscussion = DiscussionFeature(sessionFeature: secondSession, makeProvider: { AsyncDiscussionProvider(service: MockService()) })
    let secondDetails =
      ProjectDetailsFeature(sessionFeature: secondSession,
      discussionFeature: secondDiscussion,
      makeProvider: { AsyncProjectDetailsProvider(service: MockService()) })
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
    let first = AppModel(
      developerExamplesFeature: DeveloperExamplesFeature(sessionFeature: firstSession, makeProvider: {
        XCTFail("Composition must not load developer examples")
        return AsyncDeveloperExamplesProvider(service: MockService())
      }),
      onboardingFeature: OnboardingFeature(completionStore: { [store = MockKeyValueStore()] in store }),
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
      pledgeFeature: PledgeFeature(sessionFeature: firstSession, makeProvider: { AsyncPledgeProvider(service: MockService()) }),
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
      rewardsFeature: RewardsFeature(sessionFeature: firstSession, makeProvider: { AsyncRewardsProvider(service: MockService()) }),
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
    let second = AppModel(
      developerExamplesFeature: DeveloperExamplesFeature(sessionFeature: secondSession, makeProvider: {
        XCTFail("Composition must not load developer examples")
        return AsyncDeveloperExamplesProvider(service: MockService())
      }),
      onboardingFeature: OnboardingFeature(completionStore: { [store = MockKeyValueStore()] in store }),
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
      pledgeFeature: PledgeFeature(sessionFeature: secondSession, makeProvider: { AsyncPledgeProvider(service: MockService()) }),
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
      rewardsFeature: RewardsFeature(sessionFeature: secondSession, makeProvider: { AsyncRewardsProvider(service: MockService()) }),
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
    XCTAssertTrue(first.pledgeFeature.sessionFeature === first.sessionFeature)
    XCTAssertFalse(first.pledgeFeature === second.pledgeFeature)
    XCTAssertTrue(first.paymentsFeature.sessionFeature === first.sessionFeature)
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
    first.sessionChanged()
    XCTAssertEqual(first.sessionFeature.generation, 1)
    XCTAssertEqual(second.sessionFeature.generation, 0)
  }
}

@MainActor
final class RemoteConfigurationServiceTests: XCTestCase {
  func testActivationSharesClientAndRetriesAfterFailure() async throws {
    let service = RemoteConfigurationService()
    let client = NSObject()
    let gate = AccountRequestGate<Void>()
    defer { gate.releaseAll() }
    let first = service.activate(client: client) { try await gate.request() }
    let second = service.activate(client: client) { XCTFail("Duplicate activation") }
    await gate.waitFor(1)
    try gate.finish(0, .failure(URLError(.notConnectedToInternet)))
    for request in [first, second] {
      if case .success = await request.result { XCTFail("Failure was swallowed") }
    }
    let retry = service.activate(client: client) { try await gate.request() }
    await gate.waitFor(2)
    try gate.finish(1, .success(()))
    try await retry.value
    XCTAssertEqual(gate.count, 2)
  }

  func testReplacingClientRejectsLateOldClientCompletion() async throws {
    let service = RemoteConfigurationService()
    let oldClient = NSObject(), newClient = NSObject()
    let gate = AccountRequestGate<Void>()
    defer { gate.releaseAll() }
    let old = service.activate(client: oldClient) { try await gate.request() }
    await gate.waitFor(1)
    let new = service.activate(client: newClient) { try await gate.request() }
    await gate.waitFor(2)
    try gate.finish(1, .success(()))
    try await new.value
    try gate.finish(0, .success(()))
    if case .success = await old.result { XCTFail("Replaced activation completed") }
  }
}

@MainActor
final class ApplicationConfigurationServiceTests: XCTestCase {
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
  func testSessionChangePreventsDebouncedRegistration() async throws {
    let gate = AccountRequestGate<Void>()
    defer { gate.releaseAll() }
    var registeredTokens: [String] = []
    let service = DevicePushRegistrationService(
      register: { registeredTokens.append($0) },
      debounce: { try await gate.request() }
    )
    service.schedule(token: "previous-session") { _ in XCTFail("Unexpected registration delivery") }
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
