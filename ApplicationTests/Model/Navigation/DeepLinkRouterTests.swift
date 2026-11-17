@testable import Kickstarter_iOS
import UserNotifications
import AppTrackingTransparency
import Prelude
import XCTest
import SystemConfiguration

@testable import KsApi

@MainActor
final class DeepLinkRouterTests: XCTestCase {
  private var provider: ControlledLifecycleProvider!
  private var feature: DeepLinkRouter!
  private var connectivityService: ConnectivityService!
  private let route = UUID()
  private var connectivityMonitor: ControlledReachabilityMonitor!
  private var monitorStarts = 0
  private var discoveryDelay: TimeInterval = 0
  private var discoverySleeps: [TimeInterval] = []
  private let redirects = AccountRequestGate<URL?>()
  private var settingsLinks: SettingsLinkPresentation!

  override func setUp() async throws {
    try await super.setUp()
    let provider = ControlledLifecycleProvider()
    self.provider = provider
    let session = SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) })
    let messaging = MessagingFeature(
      sessionFeature: session, makeProvider: { AsyncMessagingProvider(service: MockService()) })
    self.connectivityMonitor = ControlledReachabilityMonitor()
    self.monitorStarts = 0
    self.connectivityService = ConnectivityService(makeMonitor: { [weak self] in
      self?.monitorStarts += 1
      return self?.connectivityMonitor
    })
    let settings = SettingsFeature(sessionFeature: session, makeProvider: {
      AsyncAccountPreferencesProvider(service: MockService(
        verifyEmailResult: .success(EmailVerificationResponseEnvelope(message: "Verified"))
      ))
    })
    self.settingsLinks = SettingsLinkPresentation(settingsFeature: settings, responseDelay: { 0 })
    self.feature = DeepLinkRouter(
      sessionFeature: session, messagingFeature: messaging,
      discussionFeature: DiscussionFeature(platform: .live(), sessionFeature: session, makeProvider: { provider }),
      discoveryFeature: DiscoveryFeature(
        provider: AsyncDiscoveryProvider(), loadCategories: { try await provider.categories() },
        currentUser: { session.currentUser }
      ),
      activityFeature: ActivityFeature(
        sessionFeature: session, makeProvider: { AsyncActivityProvider(service: MockService()) },
        loadSurvey: { try await provider.survey(id: $0) }
      ),
      authenticationFeature: AuthenticationFeature(
        sessionFeature: session,
        makeProvider: { AsyncAuthenticationProvider(service: MockService()) },
        resolveRedirect: { [redirects = self.redirects] _ in try await redirects.request() }
      ),
      settingsLinks: self.settingsLinks,
      serverConfig: { ServerConfig.local },
      discoveryResponseDelay: { [weak self] in self?.discoveryDelay ?? 0 },
      sleep: { [weak self] seconds in
        try Task.checkCancellation()
        self?.discoverySleeps.append(seconds)
      }
    )
  }
  override func tearDown() async throws {
    self.feature?.reset()
    self.provider.releaseAll()
    self.redirects.releaseAll()
    await self.feature?.waitForOperations()
    try await super.tearDown()
  }
  private func link(_ id: Int = 1, _ subpage: Navigation.Project = .root) -> Navigation {
    .project(.id(id), subpage, refInfo: nil)
  }
  private func assertCancelled<T>(
    _ task: Task<T, Error>, file: StaticString = #filePath, line: UInt = #line
  ) async {
    if case .failure(is CancellationError) = await task.result {
    } else {
      XCTFail("Obsolete result escaped its owner", file: file, line: line)
    }
  }

  func testVerificationLinkUsesConfiguredHostAndOnlyApplicationRunsVerification() async throws {
    let url = try XCTUnwrap(URL(string: "http://ksr.test/profile/verify_email?at=fixture"))
    var actions: [DeepLinkRouter.Action] = []

    XCTAssertTrue(self.feature.route(url: url, route: self.route) { actions.append($0.action) })
    XCTAssertTrue(actions.isEmpty)
    await self.settingsLinks.waitForOperations()
    XCTAssertEqual(actions, [.emailVerificationCompleted("Verified", true)])

    actions.removeAll()
    XCTAssertTrue(self.feature.route(url: url, route: self.route, source: .braze) { actions.append($0.action) })
    await self.settingsLinks.waitForOperations()
    XCTAssertTrue(actions.isEmpty)
  }

  func testDuplicateEmailClicksShareRedirectAndOnlyDeliverTheResolvedRouteOnce() async throws {
    let url = try XCTUnwrap(URL(string: "https://clicks.kickstarter.com/?qs=fixture"))
    let destination = try XCTUnwrap(URL(string: "http://ksr.test/activity"))
    var actions: [DeepLinkRouter.Action] = []

    XCTAssertTrue(self.feature.route(url: url, route: self.route) { actions.append($0.action) })
    await self.redirects.waitFor(1)
    XCTAssertTrue(self.feature.route(url: url, route: self.route) { actions.append($0.action) })
    XCTAssertTrue(actions.isEmpty)

    try self.redirects.finish(0, .success(destination))
    await self.feature.waitForOperations()
    XCTAssertEqual(self.redirects.count, 1)
    XCTAssertEqual(actions, [.selectActivity])
  }

  func testNewDestinationDiscardsLateEmailRedirect() async throws {
    let url = try XCTUnwrap(URL(string: "https://clicks.kickstarter.com/?qs=fixture"))
    let destination = try XCTUnwrap(URL(string: "http://ksr.test/activity"))
    var actions: [DeepLinkRouter.Action] = []

    XCTAssertTrue(self.feature.route(url: url, route: self.route) { actions.append($0.action) })
    await self.redirects.waitFor(1)
    _ = try await self.feature.resolve(.tab(.discovery(nil)), route: self.route)

    try self.redirects.finish(0, .success(destination))
    await self.feature.waitForOperations()
    XCTAssertTrue(actions.isEmpty)
  }

  func testNewDestinationCanReplaceAnEmailClickBeforeRedirectStarts() async throws {
    let url = try XCTUnwrap(URL(string: "https://clicks.kickstarter.com/?qs=fixture"))
    XCTAssertTrue(self.feature.route(url: url, route: self.route) { _ in
      XCTFail("A replaced email click delivered an action")
    })
    _ = try await self.feature.resolve(.tab(.discovery(nil)), route: self.route)

    await self.feature.waitForOperations()
    XCTAssertEqual(self.redirects.count, 0)
  }

  func testReplacingSessionDiscardsLateEmailRedirect() async throws {
    let url = try XCTUnwrap(URL(string: "https://clicks.kickstarter.com/?qs=fixture"))
    let destination = try XCTUnwrap(URL(string: "http://ksr.test/activity"))
    var actions: [DeepLinkRouter.Action] = []

    XCTAssertTrue(self.feature.route(url: url, route: self.route) { actions.append($0.action) })
    await self.redirects.waitFor(1)
    self.feature.sessionFeature.sessionChanged()

    try self.redirects.finish(0, .success(destination))
    await self.feature.waitForOperations()
    XCTAssertTrue(actions.isEmpty)
  }

  func testDiscoveryTimingUsesTheDelayAtRequestAdmission() async throws {
    self.discoveryDelay = 0.25
    let task = self.feature.requestDestination(
      .tab(.discovery(["category_id": "art"])), route: self.route
    )
    await self.provider.categoriesGate.waitFor(1)
    self.discoveryDelay = 0.5
    try self.provider.categoriesGate.finish(0, .success(.template))

    guard case .discovery? = try await task.value else { return XCTFail("Expected Discovery") }
    XCTAssertEqual(self.discoverySleeps, [0.25])
  }

  func testNewLinkInvalidatesDeliveredActionBeforeItsReadCompletes() async throws {
    let activity = try XCTUnwrap(URL(string: "http://ksr.test/activity"))
    let discovery = try XCTUnwrap(URL(string: "http://ksr.test/discover/categories/art"))
    var earlier: DeepLinkRouter.Delivery?
    var later: DeepLinkRouter.Delivery?
    XCTAssertTrue(self.feature.route(url: activity, route: self.route) { earlier = $0 })
    let delivery = try XCTUnwrap(earlier)
    XCTAssertEqual(delivery.action, .selectActivity)

    self.feature.route(url: activity, route: UUID()) { _ in }
    XCTAssertTrue(delivery.isCurrent)

    XCTAssertTrue(self.feature.route(url: discovery, route: self.route) { later = $0 })
    XCTAssertFalse(delivery.isCurrent)
    await self.provider.categoriesGate.waitFor(1)
    XCTAssertNil(later)

    try self.provider.categoriesGate.finish(0, .success(.template))
    await self.feature.waitForOperations()
    XCTAssertTrue(try XCTUnwrap(later).isCurrent)
    XCTAssertFalse(delivery.isCurrent)
  }

  func testSessionReplacementAndReleaseInvalidateDeliveredActions() throws {
    let activity = try XCTUnwrap(URL(string: "http://ksr.test/activity"))
    var latest: DeepLinkRouter.Delivery?
    XCTAssertTrue(self.feature.route(url: activity, route: self.route) { latest = $0 })
    let beforeSessionChange = try XCTUnwrap(latest)
    XCTAssertTrue(beforeSessionChange.isCurrent)

    self.feature.sessionFeature.sessionChanged()
    XCTAssertFalse(beforeSessionChange.isCurrent)

    XCTAssertTrue(self.feature.route(url: activity, route: self.route) { latest = $0 })
    let beforeRelease = try XCTUnwrap(latest)
    XCTAssertTrue(beforeRelease.isCurrent)
    self.feature.release(route: self.route)
    XCTAssertFalse(beforeRelease.isCurrent)
  }

  func testConnectivitySharesNativeMonitorAndSurvivesSessionReset() async {
    XCTAssertEqual(self.monitorStarts, 0)
    XCTAssertEqual(self.connectivityService.connectivity, .wifi)
    var first: [Reachability] = []
    var second: [Reachability] = []
    let delivered = expectation(description: "both observers received offline")
    delivered.expectedFulfillmentCount = 2
    let a = self.connectivityService.source.observe {
      first.append($0)
      if $0 == .none { delivered.fulfill() }
    }
    let b = self.connectivityService.source.observe {
      second.append($0)
      if $0 == .none { delivered.fulfill() }
    }
    XCTAssertEqual(first, [.wifi])
    XCTAssertEqual(second, [.wifi])
    self.feature.reset()
    self.connectivityMonitor.continuation.yield(.wwan)
    self.connectivityMonitor.continuation.yield(.none)
    await fulfillment(of: [delivered], timeout: 2)
    XCTAssertEqual(first, [.wifi, .wwan, .none])
    XCTAssertEqual(second, first)
    XCTAssertEqual(self.monitorStarts, 1)
    withExtendedLifetime((a, b)) {}
  }

  func testConnectivityDisposalDoesNotStopOtherObserverAndFeatureReleaseStopsStream() async {
    let monitor = self.connectivityMonitor!
    let stopped = expectation(description: "stream cancelled")
    monitor.continuation.onTermination = { _ in stopped.fulfill() }
    var stoppedValues: [Reachability] = []
    let a = self.connectivityService.source.observe { stoppedValues.append($0) }
    a.stop()
    let delivered = expectation(description: "remaining observer")
    let b = self.connectivityService.source.observe { if $0 == .wwan { delivered.fulfill() } }
    monitor.continuation.yield(.wwan)
    await fulfillment(of: [delivered], timeout: 2)
    XCTAssertEqual(stoppedValues, [.wifi])
    b.stop()
    weak var released = self.connectivityService
    self.connectivityService = nil
    XCTAssertNil(released)
    await fulfillment(of: [stopped], timeout: 2)
  }

  func testConnectivityObserverReceivesInitialValueSynchronously() {
    var values: [Reachability] = []
    let observation = self.connectivityService.source.observe { values.append($0) }
    XCTAssertEqual(values, [.wifi])
    XCTAssertEqual(self.monitorStarts, 1)
    withExtendedLifetime(observation) {}
  }

  func testReachabilityPreservesNativeFlagClassification() {
    XCTAssertEqual(Reachability.from(flags: []), .none)
    XCTAssertEqual(Reachability.from(flags: [.reachable]), .wifi)
    XCTAssertEqual(Reachability.from(flags: [.isWWAN]), .wwan)
    XCTAssertEqual(Reachability.from(flags: [.isWWAN, .reachable]), .wwan)
    XCTAssertEqual(Reachability.from(flags: [.connectionRequired]), .none)
  }

  func testNativeReachabilityMonitorReleaseFinishesItsStream() async throws {
    var monitor: SystemReachabilityMonitor? = try XCTUnwrap(SystemReachabilityMonitor())
    let stream = try XCTUnwrap(monitor).updates
    weak var released = monitor
    monitor = nil
    XCTAssertNil(released)
    let ended = expectation(description: "native stream ended")
    let consumer = Task {
      for await _ in stream {}
      ended.fulfill()
    }
    await fulfillment(of: [ended], timeout: 2)
    consumer.cancel()
  }

  func testRedirectResponsePreservesRelativeLocationAndIgnoresNonRedirect() throws {
    let url = try XCTUnwrap(URL(string: "https://example.test/click/original"))
    let redirect = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "../target"]))
    XCTAssertEqual(FirstRedirectResolver.destination(in: redirect)?.absoluteString, "https://example.test/target")
    let success = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Location": "/ignored"]))
    XCTAssertNil(FirstRedirectResolver.destination(in: success))
  }

  func testEquivalentDestinationSharesCompleteChain() async throws {
    let first = self.feature.requestDestination(
      self.link(1, .update(42, .commentThread("comment", "reply"))), route: self.route)
    let second = self.feature.requestDestination(
      self.link(1, .update(42, .commentThread("comment", "reply"))), route: self.route)
    await self.provider.projects.waitFor(1)
    try self.provider.projects.finish(0, .success(.template |> Project.lens.id .~ 77))
    await self.provider.updates.waitFor(1)
    XCTAssertEqual(self.provider.updateInputs.first?.0, 42)
    XCTAssertEqual(self.provider.updateInputs.first?.1, .id(77))
    try self.provider.updates.finish(0, .success(.template))
    await self.provider.repliesGate.waitFor(1)
    try self.provider.repliesGate.finish(
      0,
      .success(
        CommentRepliesEnvelope(
          comment: .template, cursor: nil, hasPreviousPage: false, replies: [], totalCount: 0)))
    guard case .project(let value)? = try await first.value else {
      return XCTFail("Missing destination")
    }
    _ = try await second.value
    XCTAssertEqual(value.project.id, 77)
    XCTAssertEqual(value.update?.id, Update.template.id)
    XCTAssertEqual(value.replies?.comment.id, Comment.template.id)
    XCTAssertEqual(self.provider.projects.count, 1)
    XCTAssertEqual(self.provider.repliesGate.count, 1)
  }

  func testNewTabInvalidatesLateProjectAndDoesNotStartItsUpdate() async throws {
    let old = self.feature.requestDestination(self.link(1, .update(42, .root)), route: self.route)
    await self.provider.projects.waitFor(1)
    _ = try await self.feature.resolve(.tab(.search), route: self.route)
    try self.provider.projects.finish(0, .success(.template))
    await self.assertCancelled(old)
    XCTAssertEqual(self.provider.updates.count, 0)
  }

  func testNewProjectSuppressesOldRepliesEvenIfTransportIgnoresCancellation() async throws {
    let old = self.feature.requestDestination(
      self.link(1, .commentThread("old", nil)), route: self.route)
    await self.provider.projects.waitFor(1)
    try self.provider.projects.finish(0, .success(.template))
    await self.provider.repliesGate.waitFor(1)
    let new = self.feature.requestDestination(self.link(2), route: self.route)
    await self.provider.projects.waitFor(2)
    try self.provider.projects.finish(1, .success(.template |> Project.lens.id .~ 2))
    try self.provider.repliesGate.finish(
      0,
      .success(
        CommentRepliesEnvelope(
          comment: .template, cursor: nil, hasPreviousPage: false, replies: [], totalCount: 0)))
    await self.assertCancelled(old)
    guard case .project(let value)? = try await new.value else {
      return XCTFail("Missing destination")
    }
    XCTAssertEqual(value.project.id, 2)
    XCTAssertNil(value.replies)
  }

  func testReleasingRouteSuppressesLateFailure() async throws {
    let old = self.feature.requestDestination(self.link(), route: self.route)
    await self.provider.projects.waitFor(1)
    self.feature.release(route: self.route)
    try self.provider.projects.finish(0, .failure(ErrorEnvelope.couldNotParseJSON))
    // Cancellation takes priority over transport failure for removed routes.
    await self.assertCancelled(old)
  }

  func testSameAccountReauthenticationRejectsOldUpdateAndSkipsReplies() async throws {
    let old = self.feature.requestDestination(
      self.link(1, .update(42, .commentThread("old", nil))), route: self.route)
    await self.provider.projects.waitFor(1)
    try self.provider.projects.finish(0, .success(.template))
    await self.provider.updates.waitFor(1)
    self.feature.sessionFeature.sessionChanged()
    try self.provider.updates.finish(0, .success(.template))
    await self.assertCancelled(old)
    XCTAssertEqual(self.provider.repliesGate.count, 0)
  }

  func testCategoryLookupClearedByNonCategoryDiscoveryLink() async throws {
    let old = self.feature.requestDestination(
      .tab(.discovery(["category_id": "art"])), route: self.route)
    await self.provider.categoriesGate.waitFor(1)
    guard
      case .discovery(nil)? = try await self.feature.resolve(
        .tab(.discovery(nil)), route: self.route)
    else {
      return XCTFail("Cleared discovery must still navigate")
    }
    try self.provider.categoriesGate.finish(0, .success(.template))
    await self.assertCancelled(old)
  }

  func testPrelaunchDoesNotLoadPrivateSubpages() async throws {
    let task = self.feature.requestDestination(self.link(1, .update(42, .root)), route: self.route)
    await self.provider.projects.waitFor(1)
    try self.provider.projects.finish(
      0, .success(.template |> Project.lens.displayPrelaunch .~ true))
    let value = try await task.value
    XCTAssertNil(value)
    XCTAssertEqual(self.provider.updates.count, 0)
  }

}

@MainActor
private final class ControlledLifecycleProvider: DiscussionProvider {
  let permissions = AccountRequestGate<Bool>()
  let tracking = AccountRequestGate<UInt>()
  var permissionOptions: [UInt] = []
  var registrationCount = 0
  let config = AccountRequestGate<Config>()
  let registrations = AccountRequestGate<Void>()
  let recommendationsGate = AccountRequestGate<Int>()
  let categoriesGate = AccountRequestGate<RootCategoriesEnvelope>()
  let surveys = AccountRequestGate<SurveyResponse>()
  let projects = AccountRequestGate<Project>()
  let updates = AccountRequestGate<Update>()
  let repliesGate = AccountRequestGate<CommentRepliesEnvelope>()
  var tokens: [String] = []
  var updateInputs: [(Int, Param)] = []
  func register(token: String) async throws {
    self.tokens.append(token)
    try await self.registrations.request()
  }
  func recommendations() async throws -> Int { try await self.recommendationsGate.request() }
  func categories() async throws -> RootCategoriesEnvelope {
    try await self.categoriesGate.request()
  }
  func survey(id: Int) async throws -> SurveyResponse { try await self.surveys.request() }
  func project(param: Param) async throws -> Project { try await self.projects.request() }
  func update(id: Int, project: Param) async throws -> Update {
    self.updateInputs.append((id, project))
    return try await self.updates.request()
  }
  func comments(slug: String?, updateID: String?, cursor: String?) async throws -> CommentsEnvelope {
    throw CancellationError()
  }
  func post(input: PostCommentInput) async throws -> Comment { throw CancellationError() }
  func block(id: String) async throws -> EmptyResponseEnvelope { throw CancellationError() }
  func replies(id: String, cursor: String?) async throws -> CommentRepliesEnvelope {
    try await self.repliesGate.request()
  }
  func releaseAll() {
    self.permissions.releaseAll()
    self.tracking.releaseAll()
    self.config.releaseAll()
    self.registrations.releaseAll()
    self.recommendationsGate.releaseAll()
    self.categoriesGate.releaseAll()
    self.surveys.releaseAll()
    self.projects.releaseAll()
    self.updates.releaseAll()
    self.repliesGate.releaseAll()
  }
}

private final class ControlledReachabilityMonitor: ReachabilityMonitoring {
  let initial: Reachability = .wifi
  let updates: AsyncStream<Reachability>
  let continuation: AsyncStream<Reachability>.Continuation
  init() { (self.updates, self.continuation) = AsyncStream<Reachability>.makeStream() }
}
