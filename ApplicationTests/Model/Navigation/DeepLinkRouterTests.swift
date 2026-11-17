@testable import Kickstarter_iOS
import UserNotifications
import AppTrackingTransparency
import Prelude
import XCTest

@testable import KsApi

@MainActor
final class DeepLinkRouterTests: XCTestCase {
  private var provider: ControlledDeepLinkProvider!
  private var router: DeepLinkRouter!
  private var model: AppModel!
  private let route = UUID()
  private var discoveryDelay: TimeInterval = 0
  private var discoverySleeps: [TimeInterval] = []
  private let redirects = AccountRequestGate<URL?>()
  private var settingsLinks: SettingsLinkPresentation!

  override func setUp() async throws {
    try await super.setUp()
    let provider = ControlledDeepLinkProvider()
    self.provider = provider
    let session = SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) })
    let messaging = MessagingFeature(
      sessionFeature: session, makeProvider: { AsyncMessagingProvider(service: MockService()) })
    let settings = SettingsFeature(sessionFeature: session, makeProvider: {
      AsyncAccountPreferencesProvider(service: MockService(
        verifyEmailResult: .success(EmailVerificationResponseEnvelope(message: "Verified"))
      ))
    })
    self.settingsLinks = SettingsLinkPresentation(settingsFeature: settings, responseDelay: { 0 })
    self.model = makeTestAppModel(
      sessionFeature: session, settingsFeature: settings, messagingFeature: messaging,
      discussionFeature: DiscussionFeature(platform: .live(), sessionFeature: session, makeProvider: { provider }),
      discoveryFeature: DiscoveryFeature(
        provider: EnvironmentDiscoveryProvider(), loadCategories: { try await provider.categories() },
        sleep: { [weak self] seconds in
          try Task.checkCancellation()
          self?.discoverySleeps.append(seconds)
        },
        sessionFeature: session
      ),
      activityFeature: ActivityFeature(
        sessionFeature: session, makeProvider: { AsyncActivityProvider(service: MockService()) },
        loadSurvey: { try await provider.survey(id: $0) }
      ),
      authenticationFeature: AuthenticationFeature(
        sessionFeature: session,
        makeProvider: { AsyncAuthenticationProvider(service: MockService()) },
        resolveRedirect: { [redirects = self.redirects] _ in try await redirects.request() }
      )
    )
    let model = try XCTUnwrap(self.model)
    self.router = DeepLinkRouter(
      currentSession: { model.deepLinkSession },
      resolveDestination: { try await model.resolveDeepLink($0, discoveryResponseDelay: $1) },
      firstRedirect: { try await model.resolveEmailLink($0, route: $1) },
      releaseRedirect: { model.releaseEmailLink(route: $0) },
      settingsLinks: self.settingsLinks,
      serverConfig: { ServerConfig.local },
      discoveryResponseDelay: { [weak self] in self?.discoveryDelay ?? 0 }
    )
  }

  override func tearDown() async throws {
    self.router?.reset()
    self.provider.releaseAll()
    self.redirects.releaseAll()
    await self.router?.waitForOperations()
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

    XCTAssertTrue(self.router.route(url: url, route: self.route) { actions.append($0.action) })
    XCTAssertTrue(actions.isEmpty)
    await self.settingsLinks.waitForOperations()
    XCTAssertEqual(actions, [.emailVerificationCompleted("Verified", true)])

    actions.removeAll()
    XCTAssertTrue(self.router.route(url: url, route: self.route, source: .braze) { actions.append($0.action) })
    await self.settingsLinks.waitForOperations()
    XCTAssertTrue(actions.isEmpty)
  }

  func testDuplicateEmailClicksShareRedirectAndOnlyDeliverTheResolvedRouteOnce() async throws {
    let url = try XCTUnwrap(URL(string: "https://clicks.kickstarter.com/?qs=fixture"))
    let destination = try XCTUnwrap(URL(string: "http://ksr.test/activity"))
    var actions: [DeepLinkRouter.Action] = []

    XCTAssertTrue(self.router.route(url: url, route: self.route) { actions.append($0.action) })
    await self.redirects.waitFor(1)
    XCTAssertTrue(self.router.route(url: url, route: self.route) { actions.append($0.action) })
    XCTAssertTrue(actions.isEmpty)

    try self.redirects.finish(0, .success(destination))
    await self.router.waitForOperations()
    XCTAssertEqual(self.redirects.count, 1)
    XCTAssertEqual(actions, [.selectActivity])
  }

  func testNewDestinationDiscardsLateEmailRedirect() async throws {
    let url = try XCTUnwrap(URL(string: "https://clicks.kickstarter.com/?qs=fixture"))
    let destination = try XCTUnwrap(URL(string: "http://ksr.test/activity"))
    var actions: [DeepLinkRouter.Action] = []

    XCTAssertTrue(self.router.route(url: url, route: self.route) { actions.append($0.action) })
    await self.redirects.waitFor(1)
    _ = try await self.router.resolve(.tab(.discovery(nil)), route: self.route)

    try self.redirects.finish(0, .success(destination))
    await self.router.waitForOperations()
    XCTAssertTrue(actions.isEmpty)
  }

  func testNewDestinationCanReplaceAnEmailClickBeforeRedirectStarts() async throws {
    let url = try XCTUnwrap(URL(string: "https://clicks.kickstarter.com/?qs=fixture"))
    XCTAssertTrue(self.router.route(url: url, route: self.route) { _ in
      XCTFail("A replaced email click delivered an action")
    })
    _ = try await self.router.resolve(.tab(.discovery(nil)), route: self.route)

    await self.router.waitForOperations()
    XCTAssertEqual(self.redirects.count, 0)
  }

  func testReplacingSessionDiscardsLateEmailRedirect() async throws {
    let url = try XCTUnwrap(URL(string: "https://clicks.kickstarter.com/?qs=fixture"))
    let destination = try XCTUnwrap(URL(string: "http://ksr.test/activity"))
    var actions: [DeepLinkRouter.Action] = []

    XCTAssertTrue(self.router.route(url: url, route: self.route) { actions.append($0.action) })
    await self.redirects.waitFor(1)
    self.model.sessionFeature.sessionChanged()

    try self.redirects.finish(0, .success(destination))
    await self.router.waitForOperations()
    XCTAssertTrue(actions.isEmpty)
  }

  func testDiscoveryTimingUsesTheDelayAtRequestAdmission() async throws {
    self.discoveryDelay = 0.25
    let task = self.router.requestDestination(
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
    XCTAssertTrue(self.router.route(url: activity, route: self.route) { earlier = $0 })
    let delivery = try XCTUnwrap(earlier)
    XCTAssertEqual(delivery.action, .selectActivity)

    self.router.route(url: activity, route: UUID()) { _ in }
    XCTAssertTrue(delivery.isCurrent)

    XCTAssertTrue(self.router.route(url: discovery, route: self.route) { later = $0 })
    XCTAssertFalse(delivery.isCurrent)
    await self.provider.categoriesGate.waitFor(1)
    XCTAssertNil(later)

    try self.provider.categoriesGate.finish(0, .success(.template))
    await self.router.waitForOperations()
    XCTAssertTrue(try XCTUnwrap(later).isCurrent)
    XCTAssertFalse(delivery.isCurrent)
  }

  func testSessionReplacementAndReleaseInvalidateDeliveredActions() throws {
    let activity = try XCTUnwrap(URL(string: "http://ksr.test/activity"))
    var latest: DeepLinkRouter.Delivery?
    XCTAssertTrue(self.router.route(url: activity, route: self.route) { latest = $0 })
    let beforeSessionChange = try XCTUnwrap(latest)
    XCTAssertTrue(beforeSessionChange.isCurrent)

    self.model.sessionFeature.sessionChanged()
    XCTAssertFalse(beforeSessionChange.isCurrent)

    XCTAssertTrue(self.router.route(url: activity, route: self.route) { latest = $0 })
    let beforeRelease = try XCTUnwrap(latest)
    XCTAssertTrue(beforeRelease.isCurrent)
    self.router.release(route: self.route)
    XCTAssertFalse(beforeRelease.isCurrent)
  }

  func testRedirectResponsePreservesRelativeLocationAndIgnoresNonRedirect() throws {
    let url = try XCTUnwrap(URL(string: "https://example.test/click/original"))
    let redirect = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "../target"]))
    XCTAssertEqual(FirstRedirectResolver.destination(in: redirect)?.absoluteString, "https://example.test/target")
    let success = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Location": "/ignored"]))
    XCTAssertNil(FirstRedirectResolver.destination(in: success))
  }

  func testEquivalentDestinationSharesCompleteChain() async throws {
    let first = self.router.requestDestination(
      self.link(1, .update(42, .commentThread("comment", "reply"))), route: self.route)
    let second = self.router.requestDestination(
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
    let old = self.router.requestDestination(self.link(1, .update(42, .root)), route: self.route)
    await self.provider.projects.waitFor(1)
    _ = try await self.router.resolve(.tab(.search), route: self.route)
    try self.provider.projects.finish(0, .success(.template))
    await self.assertCancelled(old)
    XCTAssertEqual(self.provider.updates.count, 0)
  }

  func testNewProjectSuppressesOldRepliesEvenIfTransportIgnoresCancellation() async throws {
    let old = self.router.requestDestination(
      self.link(1, .commentThread("old", nil)), route: self.route)
    await self.provider.projects.waitFor(1)
    try self.provider.projects.finish(0, .success(.template))
    await self.provider.repliesGate.waitFor(1)
    let new = self.router.requestDestination(self.link(2), route: self.route)
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
    let old = self.router.requestDestination(self.link(), route: self.route)
    await self.provider.projects.waitFor(1)
    self.router.release(route: self.route)
    try self.provider.projects.finish(0, .failure(ErrorEnvelope.couldNotParseJSON))
    // Cancellation takes priority over transport failure for removed routes.
    await self.assertCancelled(old)
  }

  func testSameAccountReauthenticationRejectsOldUpdateAndSkipsReplies() async throws {
    let old = self.router.requestDestination(
      self.link(1, .update(42, .commentThread("old", nil))), route: self.route)
    await self.provider.projects.waitFor(1)
    try self.provider.projects.finish(0, .success(.template))
    await self.provider.updates.waitFor(1)
    self.model.sessionFeature.sessionChanged()
    try self.provider.updates.finish(0, .success(.template))
    await self.assertCancelled(old)
    XCTAssertEqual(self.provider.repliesGate.count, 0)
  }

  func testCategoryLookupClearedByNonCategoryDiscoveryLink() async throws {
    let old = self.router.requestDestination(
      .tab(.discovery(["category_id": "art"])), route: self.route)
    await self.provider.categoriesGate.waitFor(1)
    guard
      case .discovery(nil)? = try await self.router.resolve(
        .tab(.discovery(nil)), route: self.route)
    else {
      return XCTFail("Cleared discovery must still navigate")
    }
    try self.provider.categoriesGate.finish(0, .success(.template))
    await self.assertCancelled(old)
  }

  func testPrelaunchDoesNotLoadPrivateSubpages() async throws {
    let task = self.router.requestDestination(self.link(1, .update(42, .root)), route: self.route)
    await self.provider.projects.waitFor(1)
    try self.provider.projects.finish(
      0, .success(.template |> Project.lens.displayPrelaunch .~ true))
    let value = try await task.value
    XCTAssertNil(value)
    XCTAssertEqual(self.provider.updates.count, 0)
  }

}

@MainActor
private final class ControlledDeepLinkProvider: DiscussionProvider {
  let categoriesGate = AccountRequestGate<RootCategoriesEnvelope>()
  let surveys = AccountRequestGate<SurveyResponse>()
  let projects = AccountRequestGate<Project>()
  let updates = AccountRequestGate<Update>()
  let repliesGate = AccountRequestGate<CommentRepliesEnvelope>()
  var updateInputs: [(Int, Param)] = []
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
    self.categoriesGate.releaseAll()
    self.surveys.releaseAll()
    self.projects.releaseAll()
    self.updates.releaseAll()
    self.repliesGate.releaseAll()
  }
}
