@testable import Kickstarter_iOS
@testable import KsApi


import Prelude
import Observation
import XCTest

@MainActor
final class ActivityFeatureTests: TestCase {
  override var requiresSnapshotReferenceSimulator: Bool { false }
  private func session() -> SessionFeature {
    SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) }, currentUser: { .template })
  }

  private func page(_ ids: [Int], cursor: String = "next") -> ActivityEnvelope {
    ActivityEnvelope(
      activities: ids.map { Activity.template |> Activity.lens.id .~ $0 },
      urls: .init(api: .init(moreActivities: cursor))
    )
  }

  func testUnreadBadgeValueComesFromTheActivityFeatureDependency() {
    let feature = ActivityFeature(
      sessionFeature: self.session(),
      makeProvider: { AsyncActivityProvider(service: MockService()) },
      applicationBadgeNumber: { 7 }
    )

    XCTAssertEqual(feature.currentApplicationBadgeNumber, 7)
  }

  func testPlatformComposesSurveyAndBadgeDependencies() async throws {
    let provider = ControlledActivityProvider()
    defer { provider.releaseAll() }
    var surveyIDs: [Int] = []
    let feature = ActivityFeature(
      platform: .test(
        loadSurvey: { surveyIDs.append($0); return .template },
        applicationBadgeNumber: { 7 }
      ),
      sessionFeature: self.session(),
      makeProvider: { provider }
    )

    let page = feature.startActivityPageLoad()
    await provider.pages.waitFor(1)
    try provider.pages.finish(0, .success(self.page([4])))
    await page?.value
    let surveyURLString = try await feature.fetchSurveyURLString(id: 42)

    XCTAssertEqual(feature.activities.map(\.id), [4])
    XCTAssertEqual(surveyIDs, [42])
    XCTAssertEqual(surveyURLString, SurveyResponse.template.urls.web.survey)
    XCTAssertEqual(feature.currentApplicationBadgeNumber, 7)
  }

  func testNativeObservationTracksLoadingAndActivityChanges() async throws {
    let provider = ControlledActivityProvider()
    defer { provider.releaseAll() }
    let feature = ActivityFeature(sessionFeature: self.session(), makeProvider: { provider })
    let loadingChanged = expectation(description: "loading state changed")
    withObservationTracking { _ = feature.isLoadingActivityPage } onChange: { loadingChanged.fulfill() }
    let request = feature.startActivityPageLoad()
    await fulfillment(of: [loadingChanged], timeout: 2)
    XCTAssertTrue(feature.isLoadingActivityPage)
    let activitiesChanged = expectation(description: "activities changed")
    withObservationTracking { _ = feature.activities } onChange: { activitiesChanged.fulfill() }
    await provider.pages.waitFor(1)
    try provider.pages.finish(0, .success(self.page([4])))
    await request?.value
    await fulfillment(of: [activitiesChanged], timeout: 2)
    XCTAssertEqual(feature.activities.map(\.id), [4])
    XCTAssertFalse(feature.isLoadingActivityPage)
  }

  func testHistorySharingPaginationSortingEmptyAndRetry() async throws {
    let provider = ControlledActivityProvider()
    defer { provider.releaseAll() }
    let feature = ActivityFeature(sessionFeature: self.session(), makeProvider: { provider })
    let first = feature.startActivityPageLoad(), duplicate = feature.startActivityPageLoad()
    await provider.pages.waitFor(1)
    try provider.pages.finish(0, .success(self.page([1, 3])))
    await first?.value; await duplicate?.value
    XCTAssertEqual(feature.activities.map(\.id), [3, 1])
    let next = feature.startActivityPageLoad(next: true)
    await provider.pages.waitFor(2)
    try provider.pages.finish(1, .success(self.page([2, 3])))
    await next?.value
    XCTAssertEqual(feature.activities.map(\.id), [3, 2, 1])
    XCTAssertEqual(provider.cursors, [nil, "next"])
    let failed = feature.startActivityPageLoad()
    await provider.pages.waitFor(3)
    try provider.pages.finish(2, .failure(ErrorEnvelope.couldNotParseJSON))
    await failed?.value
    XCTAssertNotNil(feature.activityPageError)
    XCTAssertEqual(feature.activities.count, 3)
    let empty = feature.startActivityPageLoad()
    await provider.pages.waitFor(4)
    try provider.pages.finish(3, .success(self.page([])))
    await empty?.value
    XCTAssertTrue(feature.activities.isEmpty)
    XCTAssertNil(feature.activityPageError)
    XCTAssertNil(feature.startActivityPageLoad(next: true))
  }

  func testResetRejectsLatePagesAndSurveys() async throws {
    let provider = ControlledActivityProvider()
    defer { provider.releaseAll() }
    let session = self.session()
    let feature = ActivityFeature(sessionFeature: session, makeProvider: { provider })
    let page = feature.startActivityPageLoad(), survey = feature.startUnansweredSurveyLoad()
    await provider.pages.waitFor(1); await provider.surveysGate.waitFor(1)
    session.sessionChanged()
    feature.resetForSessionChange()
    try provider.pages.finish(0, .success(self.page([1])))
    try provider.surveysGate.finish(0, .success([.template]))
    await page?.value; await survey?.value
    XCTAssertTrue(feature.activities.isEmpty)
    XCTAssertTrue(feature.surveys.isEmpty)
    XCTAssertFalse(feature.isLoadingActivityPage)
  }

  func testSurveyFailurePreservesDataAndIndependentPageCanComplete() async throws {
    let provider = ControlledActivityProvider()
    defer { provider.releaseAll() }
    let feature = ActivityFeature(sessionFeature: self.session(), makeProvider: { provider })
    let survey = feature.startUnansweredSurveyLoad(), duplicate = feature.startUnansweredSurveyLoad()
    let page = feature.startActivityPageLoad()
    await provider.surveysGate.waitFor(1); await provider.pages.waitFor(1)
    try provider.surveysGate.finish(0, .success([.template]))
    try provider.pages.finish(0, .success(self.page([1])))
    await survey?.value; await duplicate?.value; await page?.value
    let failed = feature.startUnansweredSurveyLoad()
    await provider.surveysGate.waitFor(2)
    try provider.surveysGate.finish(1, .failure(ErrorEnvelope.couldNotParseJSON))
    await failed?.value
    XCTAssertEqual(feature.surveys.count, 1)
    XCTAssertNotNil(feature.surveyError)
    XCTAssertEqual(feature.activities.count, 1)
  }

  func testLoggedOutRequestsDoNotReachProvider() async {
    let provider = ControlledActivityProvider()
    let session = SessionFeature(
      makeProvider: { AsyncSessionProvider(service: MockService()) },
      currentUser: { nil }
    )
    let feature = ActivityFeature(sessionFeature: session, makeProvider: { provider })
    await feature.refreshActivityFeed()
    XCTAssertNil(feature.startUnansweredSurveyLoad())
    XCTAssertEqual(provider.pages.count, 0)
    XCTAssertEqual(provider.surveysGate.count, 0)
  }

  func testResetRejectsLateErrorsWithoutChangingSession() async throws {
    let provider = ControlledActivityProvider()
    defer { provider.releaseAll() }
    let feature = ActivityFeature(sessionFeature: self.session(), makeProvider: { provider })
    let page = feature.startActivityPageLoad(), survey = feature.startUnansweredSurveyLoad()
    await provider.pages.waitFor(1)
    await provider.surveysGate.waitFor(1)
    feature.resetForSessionChange()
    try provider.pages.finish(0, .failure(ErrorEnvelope.couldNotParseJSON))
    try provider.surveysGate.finish(0, .failure(ErrorEnvelope.couldNotParseJSON))
    await page?.value
    await survey?.value
    XCTAssertNil(feature.activityPageError)
    XCTAssertNil(feature.surveyError)
    XCTAssertFalse(feature.isLoadingActivityPage)
  }
}

@MainActor
private final class ControlledActivityProvider: ActivityProvider {
  let pages = AccountRequestGate<ActivityEnvelope>()
  let surveysGate = AccountRequestGate<[SurveyResponse]>()
  var cursors: [String?] = []
  func fetchActivityPage(cursor: String?) async throws -> ActivityEnvelope { self.cursors
    .append(cursor); return try await self.pages.request()
  }

  func fetchUnansweredSurveys() async throws -> [SurveyResponse] { try await self.surveysGate.request() }
  func releaseAll() { self.pages.releaseAll(); self.surveysGate.releaseAll() }
}
