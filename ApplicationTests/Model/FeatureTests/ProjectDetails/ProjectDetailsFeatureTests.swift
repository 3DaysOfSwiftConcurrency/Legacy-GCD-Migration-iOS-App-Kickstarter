@testable import Kickstarter_iOS
import Experimentation
import Foundation
import GraphAPI
@testable import KsApi
import Prelude


import XCTest

@MainActor
final class ProjectDetailsFeatureTests: TestCase {
  override var requiresSnapshotReferenceSimulator: Bool { false }

  func testCreatorMessageAuthorizationUsesCurrentSession() {
    let feature = self.feature(ControlledProjectDetailsProvider())
    XCTAssertTrue(feature.creatorMessageRequiresAuthentication)
    XCTAssertNil(feature.creatorMessageSubject(projectID: 42, projectName: "Creator project"))
    withEnvironment(currentUser: User.template) {
      XCTAssertFalse(feature.creatorMessageRequiresAuthentication)
      XCTAssertEqual(
        feature.creatorMessageSubject(projectID: 42, projectName: "Creator project"),
        .project(id: 42, name: "Creator project")
      )
    }
    XCTAssertNil(feature.creatorMessageSubject(projectID: 42, projectName: "Creator project"))
  }

  func testCreatorRequestPreparationAndMessageClassification() throws {
    let feature = self.feature(ControlledProjectDetailsProvider())
    let request = try XCTUnwrap(feature.creatorBiographyRequest(
      projectURL: "https://www.kickstarter.com/projects/creator/project"
    ))
    XCTAssertEqual(request.url?.path, "/projects/creator/project/creator_bio")
    XCTAssertTrue(AppEnvironment.current.apiService.isPrepared(request: request))
    XCTAssertFalse(feature.isCreatorMessage(request: request))
    let messageURL = try XCTUnwrap(URL(string: "https://www.kickstarter.com/projects/a/b/messages/new"))
    XCTAssertTrue(feature.isCreatorMessage(request: URLRequest(url: messageURL)))
  }

  func testRelatedSharingAndReplacementRejectsLateFailure() async throws {
    let provider = ControlledProjectDetailsProvider()
    provider.pauseRelated = true
    defer { provider.releaseAll() }
    let feature = self.feature(provider)
    let route = UUID()
    var relatedUpdates = 0
    let observation = feature.observe { update in
      if case let .relatedChanged(updatedRoute) = update, updatedRoute == route { relatedUpdates += 1 }
    }
    defer { observation.stop() }
    let first = feature.startRelatedProjectsLoad(route: route, projectID: "1")
    let shared = feature.startRelatedProjectsLoad(route: route, projectID: "1")
    await provider.waitFor("related:1")
    XCTAssertEqual(provider.calls, ["related:1"])
    let second = feature.startRelatedProjectsLoad(route: route, projectID: "2")
    await provider.waitFor("related:2")
    try provider.finishRelated(1, error: nil)
    await second.value
    try provider.finishRelated(0, error: .graphError("obsolete"))
    await first.value
    await shared.value
    XCTAssertTrue(first.isCancelled)
    XCTAssertNil(feature.relatedSnapshot(for: route).error)
    XCTAssertFalse(feature.relatedSnapshot(for: route).isLoading)
    XCTAssertEqual(feature.relatedSnapshot(for: route).projectID, "2")
    XCTAssertEqual(relatedUpdates, 1)
  }

  func testRelatedFailureAndEmptySuccessAreDistinctAndRetryable() async {
    let provider = ControlledProjectDetailsProvider()
    let feature = self.feature(provider)
    let route = UUID()
    provider.failAt = "related:1"
    await feature.loadRelatedProjects(route: route, projectID: "1")
    XCTAssertNotNil(feature.relatedSnapshot(for: route).error)
    XCTAssertFalse(feature.relatedSnapshot(for: route).isLoading)
    provider.failAt = nil
    await feature.loadRelatedProjects(route: route, projectID: "1")
    XCTAssertNil(feature.relatedSnapshot(for: route).error)
    XCTAssertTrue(feature.relatedSnapshot(for: route).projects.isEmpty)
  }

  func testRelatedRoutesReleaseIndependently() async throws {
    let provider = ControlledProjectDetailsProvider()
    provider.pauseRelated = true
    defer { provider.releaseAll() }
    let feature = self.feature(provider)
    let firstRoute = UUID(), secondRoute = UUID()
    let first = feature.startRelatedProjectsLoad(route: firstRoute, projectID: "1")
    let second = feature.startRelatedProjectsLoad(route: secondRoute, projectID: "1")
    await provider.waitFor("related:1", count: 2)
    feature.releaseRelatedProjects(route: firstRoute)
    try provider.finishRelated(0, error: .graphError("released"))
    try provider.finishRelated(1, error: .graphError("current"))
    await first.value
    await second.value
    XCTAssertTrue(first.isCancelled)
    XCTAssertFalse(second.isCancelled)
    XCTAssertNil(feature.relatedSnapshot(for: firstRoute).error)
    XCTAssertNotNil(feature.relatedSnapshot(for: secondRoute).error)
  }

  func testRelatedAccountChangeDoesNotShareOrPublishOldRequest() async throws {
    let provider = ControlledProjectDetailsProvider()
    provider.pauseRelated = true
    defer { provider.releaseAll() }
    let feature = self.feature(provider)
    let route = UUID()
    let anonymous = feature.startRelatedProjectsLoad(route: route, projectID: "1")
    await provider.waitFor("related:1")
    AppEnvironment.pushEnvironment(currentUser: User.template)
    defer { AppEnvironment.popEnvironment() }
    do {
      let signedIn = feature.startRelatedProjectsLoad(route: route, projectID: "1")
      await provider.waitFor("related:1", count: 2)
      try provider.finishRelated(0, error: .graphError("anonymous"))
      await anonymous.value
      XCTAssertTrue(feature.relatedSnapshot(for: route).isLoading)
      XCTAssertNil(feature.relatedSnapshot(for: route).error)
      try provider.finishRelated(1, error: nil)
      await signedIn.value
      XCTAssertFalse(feature.relatedSnapshot(for: route).isLoading)
    }
  }

  func testRelatedRequestDoesNotShareAcrossSameUserSessionReplacement() async {
    let provider = ControlledProjectDetailsProvider()
    provider.pauseRelated = true
    defer { provider.releaseAll() }
    let feature = self.feature(provider)
    let route = UUID()

    await withEnvironment(currentUser: .template) {
      let previous = feature.startRelatedProjectsLoad(route: route, projectID: "1")
      await provider.waitFor("related:1")
      feature.sessionFeature.sessionChanged()
      let current = feature.startRelatedProjectsLoad(route: route, projectID: "1")
      await provider.waitFor("related:1", count: 2)

      do {
        try provider.finishRelated(0, error: .graphError("previous session"))
        await previous.value
        XCTAssertTrue(feature.relatedSnapshot(for: route).isLoading)
        XCTAssertNil(feature.relatedSnapshot(for: route).error)
        try provider.finishRelated(1, error: nil)
        await current.value
        XCTAssertTrue(previous.isCancelled)
        XCTAssertFalse(feature.relatedSnapshot(for: route).isLoading)
      } catch {
        XCTFail("Could not complete related project fixtures: \(error)")
      }
    }
  }

  func testAttributionSharesOneEventPerRouteAndPreservesPayload() async throws {
    let provider = ControlledProjectDetailsProvider()
    provider.pauseAttribution = true
    defer { provider.attributionGate.releaseAll() }
    let feature = self.feature(provider)
    let route = UUID()
    let first = feature.startProjectPageViewAttribution(route: route, projectID: "project", properties: "{\"ref\":\"search\"}")
    let duplicate = feature.startProjectPageViewAttribution(route: route, projectID: "project", properties: "changed")
    await provider.attributionGate.waitFor(1)
    let input = try XCTUnwrap(provider.attributions.first)
    XCTAssertEqual(input.eventName, AttributionTracking.AttributionEvent.projectPageViewed.rawValue)
    XCTAssertEqual(input.projectId, .some("project"))
    XCTAssertEqual(input.eventProperties, .some("{\"ref\":\"search\"}"))
    try provider.attributionGate.finish(0, .success(()))
    try await first.value
    try await duplicate.value
    try await feature.startProjectPageViewAttribution(route: route, projectID: "project", properties: nil).value
    XCTAssertEqual(provider.attributions.count, 1)
  }

  func testAttributionFailureIsNotRetriedAndAnotherPageIsIndependent() async throws {
    let provider = ControlledProjectDetailsProvider()
    provider.pauseAttribution = true
    defer { provider.attributionGate.releaseAll() }
    let feature = self.feature(provider)
    let route = UUID()
    let first = feature.startProjectPageViewAttribution(route: route, projectID: "project", properties: nil)
    await provider.attributionGate.waitFor(1)
    try provider.attributionGate.finish(0, .failure(ErrorEnvelope.couldNotParseJSON))
    do { try await first.value; XCTFail("Expected failure") } catch {}
    do { try await feature.startProjectPageViewAttribution(route: route, projectID: "project", properties: nil).value; XCTFail("Must retain failure") } catch {}
    let other = feature.startProjectPageViewAttribution(route: UUID(), projectID: "project", properties: nil)
    await provider.attributionGate.waitFor(2)
    try provider.attributionGate.finish(1, .success(()))
    try await other.value
    XCTAssertEqual(provider.attributions.count, 2)
  }

  func testAdmittedAttributionSettlesAfterScreenRelease() async throws {
    let provider = ControlledProjectDetailsProvider()
    provider.pauseAttribution = true
    defer { provider.attributionGate.releaseAll() }
    let feature = self.feature(provider)
    let route = UUID()
    let task = feature.startProjectPageViewAttribution(route: route, projectID: "project", properties: nil)
    await provider.attributionGate.waitFor(1)
    feature.releaseProjectPage(route: route)
    XCTAssertFalse(task.isCancelled)
    try provider.attributionGate.finish(0, .success(()))
    try await task.value
    await feature.waitForProjectPageViewAttribution()
  }

  func testSessionChangeBeforeAttributionDispatchPreventsSending() async {
    let provider = ControlledProjectDetailsProvider()
    let feature = self.feature(provider)
    let task = feature.startProjectPageViewAttribution(route: UUID(), projectID: "project", properties: nil)
    feature.sessionFeature.sessionChanged()
    do { try await task.value; XCTFail("Obsolete account") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertTrue(provider.attributions.isEmpty)
  }

  func testProjectPageAnalyticsAndThirdPartyEventUseComposedPolicy() throws {
    var analytics: [String] = []
    var events: [KsApi.TriggerThirdPartyEventInput] = []
    let user = User.template |> User.lens.id .~ 99
    let session = SessionFeature(
      makeProvider: { AsyncSessionProvider(service: MockService()) }, currentUser: { user }
    )
    let feature = ProjectDetailsFeature(
      platform: .init(
        serverConfig: { ServerConfig.staging },
        prepareWebRequest: { URLRequest(url: $0) },
        cookieStorage: { MockCookieStorage() },
        dateType: { MockDate.self },
        responseDelaySeconds: { 0 },
        recordThirdPartyEvent: { events.append($0) }
      ),
      sessionFeature: session,
      discussionFeature: DiscussionFeature(
        platform: .live(), sessionFeature: session,
        makeProvider: { AsyncDiscussionProvider(service: MockService()) }
      ),
      makeProvider: { ControlledProjectDetailsProvider() },
      useFastLoading: { false },
      includeRichText: { false },
      analytics: .init(
        projectViewed: { _, _ in analytics.append("viewed") },
        blockInitiated: { _, _ in analytics.append("initiated") },
        blockConfirmed: { _, _ in analytics.append("confirmed") }
      ),
      projectViewContext: { ("advertising-id", "platform-version") }
    )
    let project = Project.template |> Project.lens.id .~ 42

    feature.recordProjectViewed(project, refTag: .search)
    feature.trackBlockInitiated(project: project, targetUserID: "7")
    feature.trackBlockConfirmed(project: project, targetUserID: "7")

    XCTAssertEqual(analytics, ["viewed", "initiated", "confirmed"])
    let event = try XCTUnwrap(events.first)
    XCTAssertEqual(event.deviceId, "advertising-id")
    XCTAssertEqual(event.projectId, "42")
    XCTAssertEqual(event.userId, "99")
    XCTAssertEqual(try XCTUnwrap(event.appData).extinfo[4], "platform-version")
  }

  private func feature(
    _ provider: ControlledProjectDetailsProvider,
    fast: Bool = false,
    includeRichText: @escaping @MainActor () -> Bool = { true },
    platform: ProjectDetailsFeature.Platform = .live(),
    analytics: ProjectDetailsFeature.Analytics = .init(),
    projectViewContext: @escaping @MainActor () -> (advertisingID: String, platformVersion: String)? = { nil }
  ) -> ProjectDetailsFeature {
    ProjectDetailsFeature(
      platform: platform,
      sessionFeature: SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) }),
      discussionFeature: DiscussionFeature(platform: .live(), sessionFeature: SessionFeature(makeProvider: { AsyncSessionProvider(service: AppEnvironment.current.apiService) }), makeProvider: { AsyncDiscussionProvider(service: AppEnvironment.current.apiService) }),
      makeProvider: { provider },
      useFastLoading: { fast },
      includeRichText: includeRichText,
      analytics: analytics,
      projectViewContext: projectViewContext,
      sleep: { _ in try Task.checkCancellation() }
    )
  }

  func testReferralUsesInjectedCookieStorageAndClock() throws {
    let storage = MockCookieStorage()
    let feature = self.feature(
      ControlledProjectDetailsProvider(),
      platform: .init(
        serverConfig: { ServerConfig.staging },
        prepareWebRequest: { URLRequest(url: $0) },
        cookieStorage: { storage },
        dateType: { MockDate.self },
        responseDelaySeconds: { 0 },
        recordThirdPartyEvent: { _ in }
      )
    )
    let project = Project.template
    feature.storeReferral(for: project, fallback: .search)
    let cookie = try XCTUnwrap(storage.cookies?.first)
    XCTAssertEqual(cookie.value, "search?\(Int(MockDate().timeIntervalSince1970))")

    feature.storeReferral(for: project, fallback: .discovery)
    XCTAssertEqual(cookieRefTagFor(project: project, cookies: storage.cookies)?.stringTag, RefTag.search.stringTag)
  }

  func testNativeUpdatesKeepRouteAndStopOnCancellation() async {
    let feature = self.feature(ControlledProjectDetailsProvider())
    let route = UUID()
    var events: [String] = []
    let observation = feature.observe { update in
      switch update {
      case let .loading(id, loading):
        if id == route { events.append(loading ? "loading" : "finished") }
      case let .completion(id, result):
        if id == route, case .success = result { events.append("project") }
      case .relatedChanged:
        break
      }
    }
    await feature.loadProjectPage(route: route, param: .id(1))
    XCTAssertEqual(events, ["loading", "project", "finished"])
    observation.stop()
    await feature.loadProjectPage(route: UUID(), param: .id(2))
    XCTAssertEqual(events, ["loading", "project", "finished"])
  }

  func testStandardLoadOrdersBackingBeforeRewardsAndPreservesProjectFields() async throws {
    let provider = ControlledProjectDetailsProvider()
    provider.backingID = 42
    let feature = self.feature(provider)
    let route = UUID()
    await feature.loadProjectPage(route: route, param: .id(1))
    XCTAssertEqual(provider.calls, ["project", "backing", "rewards"])
    let project = try XCTUnwrap(feature.projectPageSnapshot(for: route).project)
    XCTAssertEqual(project.name, Project.template.name)
    XCTAssertEqual(project.personalization.backing, Backing.template)
    XCTAssertEqual(project.personalization.isBacking, true)
    XCTAssertEqual(project.rewards, [Reward.noReward, Reward.template])
    XCTAssertFalse(feature.projectPageSnapshot(for: route).isLoading)
    XCTAssertNil(feature.projectPageSnapshot(for: route).error)
    XCTAssertEqual(provider.richTextValues, [true])
  }

  func testUnbackedProjectSkipsBackingAndKeepsNoRewardFirst() async throws {
    let provider = ControlledProjectDetailsProvider()
    let feature = self.feature(provider)
    let route = UUID()
    await feature.loadProjectPage(route: route, param: .slug("example"))
    XCTAssertEqual(provider.calls, ["project", "rewards"])
    XCTAssertEqual(feature.projectPageSnapshot(for: route).project?.rewards, [Reward.noReward, Reward.template])
  }

  func testEnrollmentMustCompleteBeforeAnyRead() async throws {
    await withEnvironment(currentUser: User.template) {
      let provider = ControlledProjectDetailsProvider()
      provider.pauseEnrollment = true
      defer { provider.releaseAll() }
      let feature = self.feature(provider)
      let route = UUID()
      let task = feature.startProjectPageLoad(route: route, param: .id(1), secretRewardToken: "local-test-token")
      await provider.waitFor("enroll")
      XCTAssertEqual(provider.calls, ["enroll"])
      provider.finishEnrollment()
      await task.value
      XCTAssertEqual(provider.calls, ["enroll", "project", "rewards"])
      XCTAssertNotNil(feature.projectPageSnapshot(for: route).project)
    }
  }

  func testEnrollmentFailureStopsReadsAndIsRetryable() async {
    await withEnvironment(currentUser: User.template) {
      let provider = ControlledProjectDetailsProvider()
      provider.failAt = "enroll"
      let feature = self.feature(provider)
      let route = UUID()
      await feature.loadProjectPage(route: route, param: .id(1), secretRewardToken: "local-test-token")
      XCTAssertEqual(provider.calls, ["enroll"])
      XCTAssertNotNil(feature.projectPageSnapshot(for: route).error)
      provider.failAt = nil
      await feature.loadProjectPage(route: route, param: .id(1), secretRewardToken: "local-test-token")
      XCTAssertEqual(provider.calls, ["enroll", "enroll", "project", "rewards"])
      XCTAssertNil(feature.projectPageSnapshot(for: route).error)
    }
  }

  func testAnonymousOrEmptyTokenDoesNotEnroll() async {
    let provider = ControlledProjectDetailsProvider()
    let feature = self.feature(provider)
    await feature.loadProjectPage(route: UUID(), param: .id(1), secretRewardToken: "local-test-token")
    await withEnvironment(currentUser: User.template) {
      await feature.loadProjectPage(route: UUID(), param: .id(1), secretRewardToken: "")
    }
    XCTAssertFalse(provider.calls.contains("enroll"))
  }

  func testBackingAndRewardsFailuresNeverPublishPartialProjectAndRetryRetainsCache() async {
    for failure in ["project", "backing", "rewards"] {
      let provider = ControlledProjectDetailsProvider()
      provider.backingID = 42
      let feature = self.feature(provider)
      let route = UUID()
      provider.failAt = failure
      await feature.loadProjectPage(route: route, param: .id(1))
      XCTAssertNil(feature.projectPageSnapshot(for: route).project)
      XCTAssertNotNil(feature.projectPageSnapshot(for: route).error)
      XCTAssertEqual(provider.calls.last, failure)
      provider.failAt = nil
      await feature.loadProjectPage(route: route, param: .id(1))
      let cached = feature.projectPageSnapshot(for: route).project
      XCTAssertNotNil(cached)
      provider.failAt = failure
      await feature.loadProjectPage(route: route, param: .id(1))
      XCTAssertEqual(feature.projectPageSnapshot(for: route).project, cached)
      XCTAssertNotNil(feature.projectPageSnapshot(for: route).error)
      XCTAssertFalse(feature.projectPageSnapshot(for: route).isLoading)
    }
  }

  func testEquivalentRequestsShareAndChangedRequestRejectsLateCompletion() async throws {
    let provider = ControlledProjectDetailsProvider()
    provider.pauseProjects = true
    defer { provider.releaseAll() }
    let feature = self.feature(provider)
    let route = UUID()
    let first = feature.startProjectPageLoad(route: route, param: .id(1))
    await provider.waitFor("project")
    let shared = feature.startProjectPageLoad(route: route, param: .id(1))
    XCTAssertEqual(provider.projects.count, 1)
    let replacement = feature.startProjectPageLoad(route: route, param: .id(2))
    await provider.waitFor("project", count: 2)
    try provider.finishProject(1, id: 2)
    await replacement.value
    try provider.finishProject(0, id: 1)
    await first.value
    await shared.value
    XCTAssertEqual(feature.projectPageSnapshot(for: route).project?.id, 2)
    XCTAssertEqual(provider.calls.filter { $0 == "rewards" }.count, 1)
  }

  func testCancelOneRouteDoesNotCancelAnotherAndReleaseRemovesState() async throws {
    let provider = ControlledProjectDetailsProvider()
    provider.pauseProjects = true
    defer { provider.releaseAll() }
    let feature = self.feature(provider)
    let firstRoute = UUID()
    let secondRoute = UUID()
    let first = feature.startProjectPageLoad(route: firstRoute, param: .id(1))
    await provider.waitFor("project")
    let second = feature.startProjectPageLoad(route: secondRoute, param: .id(2))
    await provider.waitFor("project", count: 2)
    feature.cancelProjectPageLoad(route: firstRoute)
    try provider.finishProject(0, id: 1)
    try provider.finishProject(1, id: 2)
    await first.value
    await second.value
    XCTAssertNil(feature.projectPageSnapshot(for: firstRoute).project)
    XCTAssertNil(feature.projectPageSnapshot(for: firstRoute).error)
    XCTAssertEqual(feature.projectPageSnapshot(for: secondRoute).project?.id, 2)
    feature.releaseProjectPage(route: secondRoute)
    XCTAssertNil(feature.projectPageSnapshot(for: secondRoute).project)
  }

  func testAccountChangeRejectsResultBeforeBackingOrRewards() async throws {
    let provider = ControlledProjectDetailsProvider()
    provider.pauseProjects = true
    provider.backingID = 42
    defer { provider.releaseAll() }
    let feature = self.feature(provider)
    let route = UUID()
    let task = feature.startProjectPageLoad(route: route, param: .id(1))
    await provider.waitFor("project")
    await withEnvironment(currentUser: User.template) {
      do { try provider.finishProject(0, id: 1) }
      catch { XCTFail("Could not complete fixture: \(error)") }
      await task.value
      XCTAssertNil(feature.projectPageSnapshot(for: route).project)
      XCTAssertEqual(provider.calls, ["project"])
      XCTAssertNil(feature.projectPageSnapshot(for: route).error)
    }
  }

  func testSameUserSessionReplacementRejectsResultBeforeBackingOrRewards() async {
    let provider = ControlledProjectDetailsProvider()
    provider.pauseProjects = true
    provider.backingID = 42
    defer { provider.releaseAll() }
    let feature = self.feature(provider)
    let route = UUID()

    await withEnvironment(currentUser: .template) {
      let task = feature.startProjectPageLoad(route: route, param: .id(1))
      await provider.waitFor("project")
      feature.sessionFeature.sessionChanged()
      do { try provider.finishProject(0, id: 1) }
      catch { XCTFail("Could not complete project fixture: \(error)") }
      await task.value

      XCTAssertEqual(provider.calls, ["project"])
      XCTAssertNil(feature.projectPageSnapshot(for: route).project)
      XCTAssertNil(feature.projectPageSnapshot(for: route).error)
      XCTAssertFalse(feature.projectPageSnapshot(for: route).isLoading)
    }
  }

  func testRichTextPolicyChangeReplacesAnEquivalentProjectRead() async throws {
    let provider = ControlledProjectDetailsProvider()
    provider.pauseProjects = true
    defer { provider.releaseAll() }
    var includeRichText = false
    let feature = self.feature(provider, includeRichText: { includeRichText })
    let route = UUID()

    let previous = feature.startProjectPageLoad(route: route, param: .id(1))
    await provider.waitFor("project")
    XCTAssertFalse(feature.includesRichTextStory)
    includeRichText = true
    let current = feature.startProjectPageLoad(route: route, param: .id(1))
    await provider.waitFor("project", count: 2)
    XCTAssertTrue(feature.includesRichTextStory)
    XCTAssertEqual(provider.richTextValues, [false, true])

    try provider.finishProject(1, id: 2)
    await current.value
    try provider.finishProject(0, id: 1)
    await previous.value
    XCTAssertEqual(feature.projectPageSnapshot(for: route).project?.id, 2)
  }

  func testRichTextPolicyUsesInjectedSettingsFeature() {
    let sessionFeature = SessionFeature(
      makeProvider: { AsyncSessionProvider(service: MockService()) }
    )
    let injectedStatsigClient = MockStatsigWrapper()
    injectedStatsigClient.features[.projectStoryRichText] = true
    let globalStatsigClient = MockStatsigWrapper()
    globalStatsigClient.features[.projectStoryRichText] = false
    let settingsFeature = SettingsFeature(
      sessionFeature: sessionFeature,
      applicationSettings: .test(statsigClient: { injectedStatsigClient }),
      makeProvider: { AsyncAccountPreferencesProvider(service: MockService()) }
    )
    let feature = ProjectDetailsFeature(
      platform: .live(),
      sessionFeature: sessionFeature,
      settingsFeature: settingsFeature,
      discussionFeature: DiscussionFeature(
        platform: .live(), sessionFeature: sessionFeature,
        makeProvider: { AsyncDiscussionProvider(service: MockService()) }
      ),
      makeProvider: { ControlledProjectDetailsProvider() },
      useFastLoading: { false }
    )

    withEnvironment(statsigClient: globalStatsigClient) {
      XCTAssertTrue(feature.includesRichTextStory)
    }
  }

  func testCompletedProjectSnapshotDoesNotSurviveSameUserSessionReplacement() async {
    let provider = ControlledProjectDetailsProvider()
    provider.backingID = 42
    let feature = self.feature(provider)
    let route = UUID()

    await withEnvironment(currentUser: .template) {
      await feature.loadProjectPage(route: route, param: .id(1))
      XCTAssertNotNil(feature.projectPageSnapshot(for: route).project?.personalization.backing)

      feature.sessionFeature.sessionChanged()
      XCTAssertNil(feature.projectPageSnapshot(for: route).project)

      provider.failAt = "project"
      await feature.loadProjectPage(route: route, param: .id(1))
      XCTAssertNil(feature.projectPageSnapshot(for: route).project)
      XCTAssertNotNil(feature.projectPageSnapshot(for: route).error)
    }
  }

  func testCompletedRelatedErrorDoesNotSurviveSameUserSessionReplacement() async {
    let provider = ControlledProjectDetailsProvider()
    provider.failAt = "related:1"
    let feature = self.feature(provider)
    let route = UUID()

    await withEnvironment(currentUser: .template) {
      await feature.loadRelatedProjects(route: route, projectID: "1")
      XCTAssertNotNil(feature.relatedSnapshot(for: route).error)

      feature.sessionFeature.sessionChanged()
      XCTAssertNil(feature.relatedSnapshot(for: route).error)
    }
  }

  func testFastPathStartsBothDependenciesAndWaitsForBoth() async throws {
    let provider = ControlledProjectDetailsProvider()
    provider.pauseBase = true
    defer { provider.releaseAll() }
    let feature = self.feature(provider, fast: true)
    let route = UUID()
    let task = feature.startProjectPageLoad(route: route, param: .id(1))
    await provider.waitFor("base")
    await provider.waitFor("extras")
    XCTAssertNil(feature.projectPageSnapshot(for: route).project)
    provider.finishBase()
    await task.value
    XCTAssertEqual(Set(provider.calls), Set(["base", "extras"]))
    XCTAssertEqual(feature.projectPageSnapshot(for: route).project?.extendedProjectProperties?.risks, "risk")
    XCTAssertEqual(feature.projectPageSnapshot(for: route).project?.extendedProjectProperties?.minimumPledgeAmount, 1)
    XCTAssertEqual(feature.projectPageSnapshot(for: route).project?.flagging, true)
  }

  func testFastDependencyFailuresPublishNoPartialProject() async {
    for failure in ["base", "extras"] {
      let provider = ControlledProjectDetailsProvider()
      provider.failAt = failure
      let feature = self.feature(provider, fast: true)
      let route = UUID()
      await feature.loadProjectPage(route: route, param: .id(1))
      XCTAssertNil(feature.projectPageSnapshot(for: route).project)
      XCTAssertNotNil(feature.projectPageSnapshot(for: route).error)
      XCTAssertFalse(feature.projectPageSnapshot(for: route).isLoading)
    }
  }

  func testForceRefreshAfterMutationReplacesEquivalentRead() async throws {
    let provider = ControlledProjectDetailsProvider()
    provider.pauseProjects = true
    defer { provider.releaseAll() }
    let feature = self.feature(provider)
    let route = UUID()
    let first = feature.startProjectPageLoad(route: route, param: .id(1))
    await provider.waitFor("project")
    let refreshed = feature.startProjectPageLoad(route: route, param: .id(1), force: true)
    await provider.waitFor("project", count: 2)
    try provider.finishProject(1, id: 10)
    await refreshed.value
    try provider.finishProject(0, id: 9)
    await first.value
    XCTAssertEqual(feature.projectPageSnapshot(for: route).project?.id, 10)
  }
}

@MainActor
final class ControlledProjectDetailsProvider: ProjectDetailsProvider {
  var pauseAttribution = false
  var attributions: [GraphAPI.CreateAttributionEventInput] = []
  let attributionGate = AccountRequestGate<Void>()
  func recordAttribution(input: GraphAPI.CreateAttributionEventInput) async throws {
    self.attributions.append(input)
    if self.pauseAttribution { try await self.attributionGate.request() }
  }

  var pauseRelated = false
  private var related: [CheckedContinuation<[ProjectCardProperties], Error>?] = []

  func fetchRelatedProjects(projectID: String) async throws -> [ProjectCardProperties] {
    try self.record("related:\(projectID)")
    if self.pauseRelated {
      return try await withCheckedThrowingContinuation { self.related.append($0) }
    }
    return []
  }

  func finishRelated(_ index: Int, error: ErrorEnvelope?) throws {
    guard self.related.indices.contains(index) else { XCTFail("Missing related request"); return }
    let continuation = try XCTUnwrap(self.related[index])
    self.related[index] = nil
    if let error { continuation.resume(throwing: error) }
    else { continuation.resume(returning: []) }
  }

  var calls: [String] = []
  var richTextValues: [Bool] = []
  var backingID: Int?
  var failAt: String?
  var pauseEnrollment = false
  var pauseProjects = false
  var pauseBase = false
  var projects: [CheckedContinuation<Project.ProjectPamphletData, Error>?] = []
  private var enrollment: CheckedContinuation<Void, Error>?
  private var baseContinuation: CheckedContinuation<Project, Error>?
  private var waits: [(String, Int, XCTestExpectation)] = []
  let extra = ProjectPageExtraProperties(extendedProjectProperties: ExtendedProjectProperties(
    environmentalCommitments: [], faqs: [], aiDisclosure: nil, risks: "risk",
    story: ProjectStoryElements(htmlViewElements: []), minimumPledgeAmount: 1, projectNotice: nil
  ), video: nil, flagging: true)

  private func record(_ call: String) throws {
    self.calls.append(call)
    for (name, count, expectation) in self.waits
      where name == call && self.calls.filter({ $0 == name }).count == count {
      expectation.fulfill()
    }
    if self.failAt == call { throw ErrorEnvelope.graphError("fixture failure") }
  }

  func waitFor(_ name: String, count: Int = 1) async {
    if self.calls.filter({ $0 == name }).count >= count { return }
    let expectation = XCTestExpectation(description: "\(name) admitted \(count)")
    self.waits.append((name, count, expectation))
    let result = await XCTWaiter().fulfillment(of: [expectation], timeout: 2)
    XCTAssertEqual(result, .completed)
  }

  func enrollSecretReward(token _: String, param _: Param) async throws {
    try self.record("enroll")
    if self.pauseEnrollment { try await withCheckedThrowingContinuation { self.enrollment = $0 } }
  }

  func fetchProjectPamphlet(param _: Param, richText: Bool) async throws -> Project.ProjectPamphletData {
    self.richTextValues.append(richText)
    try self.record("project")
    if self.pauseProjects { return try await withCheckedThrowingContinuation { self.projects.append($0) } }
    var project = Project.template
    project.rewardData.rewards = [Reward.noReward]
    return Project.ProjectPamphletData(project: project, backingId: self.backingID)
  }

  func fetchProjectBacking(id _: Int) async throws -> ProjectAndBackingEnvelope {
    try self.record("backing")
    return ProjectAndBackingEnvelope(project: Project.template, backing: Backing.template)
  }

  func fetchProjectRewards(projectID _: Int) async throws -> [Reward] {
    try self.record("rewards")
    return [Reward.template]
  }

  func fetchBaseProject(param _: Param) async throws -> Project {
    try self.record("base")
    if self.pauseBase { return try await withCheckedThrowingContinuation { self.baseContinuation = $0 } }
    return Project.template
  }

  func fetchProjectPageExtras(param _: Param, richText _: Bool) async throws -> ProjectPageExtraProperties {
    try self.record("extras")
    return self.extra
  }

  func finishEnrollment() { self.enrollment?.resume(); self.enrollment = nil }
  func finishBase() { self.baseContinuation?.resume(returning: Project.template); self.baseContinuation = nil
  }

  func finishProject(_ index: Int, id: Int) throws {
    guard self.projects.indices.contains(index) else { XCTFail("Missing request"); return }
    let continuation = try XCTUnwrap(self.projects[index])
    self.projects[index] = nil
    var project = Project.template
    project.id = id
    project.rewardData.rewards = [Reward.noReward]
    continuation.resume(returning: Project.ProjectPamphletData(project: project, backingId: self.backingID))
  }

  func releaseAll() {
    for continuation in self.related { continuation?.resume(throwing: CancellationError()) }
    self.related.removeAll()
    self.enrollment?.resume(throwing: CancellationError()); self.enrollment = nil
    self.baseContinuation?.resume(throwing: CancellationError()); self.baseContinuation = nil
    for continuation in self.projects { continuation?.resume(throwing: CancellationError()) }
    self.projects.removeAll()
  }
}
