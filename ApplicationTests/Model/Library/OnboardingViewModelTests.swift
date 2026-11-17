@testable import Kickstarter_iOS
import AppTrackingTransparency
@testable import KsApi


import XCTest
import UserNotifications

@MainActor
final class OnboardingViewModelTest: TestCase {
  override var requiresSnapshotReferenceSimulator: Bool { false }
  // MARK: Properties

  private var viewModel: OnboardingViewModel!

  private var trackingPromptCount = 0

  // MARK: Lifecycle

  override func setUp() async throws {
    try await super.setUp()

    self.viewModel = OnboardingViewModel(with: Bundle.main, onboardingFeature: .live())

    self.viewModel.onTrackingPrompt = { [weak self] in
      self?.trackingPromptCount += 1
    }
  }

  @MainActor
  func testClosingOnboardingSuppressesLateNotificationCompletion() async throws {
    let gate = AccountRequestGate<UNAuthorizationStatus>()
    defer { gate.releaseAll() }
    let feature = OnboardingFeature(
      completionStore: { [store = MockKeyValueStore()] in store },
      notificationStatus: { (try? await gate.request()) ?? .denied }
    )
    let model = OnboardingViewModel(onboardingFeature: feature)
    let advance = expectation(description: "Closed onboarding must not advance")
    advance.isInverted = true
    model.bind(items: { _ in }, advance: { advance.fulfill() })
    model.getNotifiedTapped()
    await gate.waitFor(1)
    model.stopObserving()
    try gate.finish(0, .success(.authorized))
    await fulfillment(of: [advance], timeout: 0.1)
  }

  @MainActor
  func testRebindingOnboardingDeliversNotificationCompletionOnce() async throws {
    let feature = OnboardingFeature(
      completionStore: { [store = MockKeyValueStore()] in store },
      authorizeNotifications: { _ in true },
      registerNotifications: {},
      notificationStatus: { .denied })
    let model = OnboardingViewModel(onboardingFeature: feature)
    defer { model.stopObserving() }
    model.bind(items: { _ in }, advance: { XCTFail("Old appearance advanced") })
    let advance = expectation(description: "Current appearance advances")
    advance.assertForOverFulfill = true
    model.bind(items: { _ in }, advance: { advance.fulfill() })
    model.getNotifiedTapped()
    await fulfillment(of: [advance], timeout: 2)
  }

  func testOnboardingItems_AreReturned_OnInit() {
    let items = self.viewModel.onboardingItems
    XCTAssertEqual(items.count, 5)
    XCTAssertTrue(items.contains(where: { $0.type == .welcome }))
    XCTAssertTrue(items.contains(where: { $0.type == .saveProjects }))
    XCTAssertTrue(items.contains(where: { $0.type == .enableNotifications }))
    XCTAssertTrue(items.contains(where: { $0.type == .allowTracking }))
    XCTAssertTrue(items.contains(where: { $0.type == .loginSignUp }))
  }

  func testAlreadyAuthorizedNotificationsDoNotPromptOrAdvance() async {
    var requested = false
    let feature = OnboardingFeature(
      completionStore: { [store = MockKeyValueStore()] in store },
      authorizeNotifications: { _ in requested = true; return true },
      registerNotifications: {},
      notificationStatus: { .authorized }
    )
    let model = OnboardingViewModel(onboardingFeature: feature)
    let advance = expectation(description: "Already authorized does not advance")
    advance.isInverted = true
    model.bind(items: { _ in }, advance: { advance.fulfill() })
    model.getNotifiedTapped()
    await fulfillment(of: [advance], timeout: 0.1)
    XCTAssertFalse(requested)
    model.stopObserving()
  }

  func testNotificationPromptSharesPendingRequestAndSurvivesObserverCancellation() async throws {
    let gate = AccountRequestGate<Bool>()
    defer { gate.releaseAll() }
    var registrations = 0
    let feature = OnboardingFeature(
      completionStore: { [store = MockKeyValueStore()] in store },
      authorizeNotifications: { _ in (try? await gate.request()) ?? false },
      registerNotifications: { registrations += 1 }
    )
    let first = Task { await feature.requestNotifications(options: [.alert]) }
    await gate.waitFor(1)
    let second = Task { await feature.requestNotifications(options: [.alert]) }
    await Task.yield()
    first.cancel()
    try gate.finish(0, .success(true))
    let firstValue = await first.value
    let secondValue = await second.value
    XCTAssertTrue(firstValue)
    XCTAssertTrue(secondValue)
    XCTAssertEqual(gate.count, 1)
    XCTAssertEqual(registrations, 1)
  }

  func testDistinctNotificationOptionsSerializeAndDeniedRequestDoesNotRegister() async throws {
    let gate = AccountRequestGate<Bool>()
    defer { gate.releaseAll() }
    var options: [UInt] = []
    var registrations = 0
    let feature = OnboardingFeature(
      completionStore: { [store = MockKeyValueStore()] in store },
      authorizeNotifications: { option in
        options.append(option.rawValue)
        return (try? await gate.request()) ?? false
      },
      registerNotifications: { registrations += 1 }
    )
    let first = Task { await feature.requestNotifications(options: [.alert]) }
    await gate.waitFor(1)
    let second = Task { await feature.requestNotifications(options: [.sound]) }
    await Task.yield()
    XCTAssertEqual(gate.count, 1)
    try gate.finish(0, .success(false))
    await gate.waitFor(2)
    try gate.finish(1, .success(true))
    _ = await first.value
    _ = await second.value
    XCTAssertEqual(options, [UNAuthorizationOptions.alert.rawValue, UNAuthorizationOptions.sound.rawValue])
    XCTAssertEqual(registrations, 1)
  }

  func testTrackingPromptSharesAndAllowsLaterRequest() async throws {
    let gate = AccountRequestGate<UInt>()
    defer { gate.releaseAll() }
    let feature = OnboardingFeature(
      completionStore: { [store = MockKeyValueStore()] in store },
      trackingAuthorization: {
        let value = (try? await gate.request()) ?? ATTrackingManager.AuthorizationStatus.notDetermined.rawValue
        return ATTrackingManager.AuthorizationStatus(rawValue: value) ?? .notDetermined
      }
    )
    let first = Task { await feature.requestTrackingAuthorization() }
    await gate.waitFor(1)
    let second = Task { await feature.requestTrackingAuthorization() }
    await Task.yield()
    first.cancel()
    try gate.finish(0, .success(ATTrackingManager.AuthorizationStatus.authorized.rawValue))
    let firstStatus = await first.value
    let secondStatus = await second.value
    XCTAssertEqual(firstStatus, .authorized)
    XCTAssertEqual(secondStatus, .authorized)
    XCTAssertEqual(gate.count, 1)
    let next = Task { await feature.requestTrackingAuthorization() }
    await gate.waitFor(2)
    try gate.finish(1, .success(ATTrackingManager.AuthorizationStatus.denied.rawValue))
    let nextStatus = await next.value
    XCTAssertEqual(nextStatus, .denied)
  }

  func testAppTrackingTransparencyPopup_IsCalled_OnAllowTrackingTapped() {
    let appTrackingTransparency = MockAppTrackingTransparency()
    appTrackingTransparency.requestAndSetAuthorizationStatusFlag = true
    appTrackingTransparency.shouldRequestAuthStatus = true

    withEnvironment(appTrackingTransparency: appTrackingTransparency) {
      self.viewModel.allowTrackingTapped()

      XCTAssertEqual(self.trackingPromptCount, 1)
    }
  }

  func testAllowTrackingTapped_DoesNotTrigger_WhenNotRequired() {
    let appTrackingTransparency = MockAppTrackingTransparency()
    appTrackingTransparency.shouldRequestAuthStatus = false

    withEnvironment(appTrackingTransparency: appTrackingTransparency) {
      self.viewModel.allowTrackingTapped()

      XCTAssertEqual(self.trackingPromptCount, 0)
    }
  }

  func testOnAppear_FiresPageViewedAnalyticsEvents() {
    self.viewModel.onAppear()

    XCTAssertEqual(["Page Viewed"], self.segmentTrackingClient.events)
    XCTAssertEqual("onboarding", self.segmentTrackingClient.properties.last?["context_page"] as? String)
    XCTAssertEqual("welcome", self.segmentTrackingClient.properties.last?["context_section"] as? String)
  }

  func testDidCompleteAppTrackingDialog_FiresAnalyticsEvent() {
    self.viewModel.didCompleteAppTrackingDialog(with: .authorized)

    XCTAssertEqual(["CTA Clicked"], self.segmentTrackingClient.events)
    XCTAssertEqual("onboarding", self.segmentTrackingClient.properties.last?["context_page"] as? String)
    XCTAssertEqual(
      "activity_tracking_prompt",
      self.segmentTrackingClient.properties.last?["context_section"] as? String
    )
    XCTAssertEqual("allow", self.segmentTrackingClient.properties.last?["context_cta"] as? String)

    self.viewModel.didCompleteAppTrackingDialog(with: .denied)

    XCTAssertEqual(["CTA Clicked"], self.segmentTrackingClient.events)
    XCTAssertEqual("onboarding", self.segmentTrackingClient.properties.last?["context_page"] as? String)
    XCTAssertEqual(
      "activity_tracking_prompt",
      self.segmentTrackingClient.properties.last?["context_section"] as? String
    )

    /// last ctaContext should be `allow` still because we shouldn't track denied events.
    XCTAssertEqual("allow", self.segmentTrackingClient.properties.last?["context_cta"] as? String)
  }

  func testGoToLoginSignupTapped_FiresAnalyticsEvents() {
    self.viewModel.goToLoginSignupTapped()

    /// Two events should be fired. One that tracks login/signup tapped and one that tracks that the onboarding flow was closed.
    /// We're asserting on both events (that will be the last two in `self.segmentTrackingClient.properties`).

    XCTAssertEqual(["CTA Clicked", "CTA Clicked"], self.segmentTrackingClient.events)

    /// Signup/login tapped assertions.
    XCTAssertEqual(
      "onboarding",
      self.segmentTrackingClient
        .properties[self.segmentTrackingClient.properties.count - 2]["context_page"] as? String
    )
    XCTAssertEqual(
      "signup_login",
      self.segmentTrackingClient
        .properties[self.segmentTrackingClient.properties.count - 2]["context_section"] as? String
    )
    XCTAssertEqual(
      "signup_login",
      self.segmentTrackingClient
        .properties[self.segmentTrackingClient.properties.count - 2]["context_cta"] as? String
    )

    /// Close assertions.
    XCTAssertEqual("onboarding", self.segmentTrackingClient.properties.last?["context_page"] as? String)
    XCTAssertNil(self.segmentTrackingClient.properties.last?["context_section"] as? String)
    XCTAssertEqual("close", self.segmentTrackingClient.properties.last?["context_cta"] as? String)
  }

  func testOnboardingFlowEnded_FiresAnalyticsEvent() {
    self.viewModel.onboardingFlowEnded()

    XCTAssertEqual("onboarding", self.segmentTrackingClient.properties.last?["context_page"] as? String)
    XCTAssertNil(self.segmentTrackingClient.properties.last?["context_section"] as? String)
    XCTAssertEqual("close", self.segmentTrackingClient.properties.last?["context_cta"] as? String)
  }

  func testGoToNextItemTapped_FiresAnalyticsEvents() {
    let onboardingItem = OnboardingItem(title: "test", subtitle: "test", type: .saveProjects)

    self.viewModel.goToNextItemTapped(item: onboardingItem)

    /// Two events should be fired. One that tracks when 'next' tapped and one that tracks that the next onboarding flow item has been viewed..
    /// We're asserting on both events (that will be the last two in `self.segmentTrackingClient.properties`).

    XCTAssertEqual(["Page Viewed", "CTA Clicked"], self.segmentTrackingClient.events)

    /// Page viewed.
    XCTAssertEqual(
      "onboarding",
      self.segmentTrackingClient
        .properties[self.segmentTrackingClient.properties.count - 2]["context_page"] as? String
    )
    XCTAssertEqual(
      "save_projects",
      self.segmentTrackingClient
        .properties[self.segmentTrackingClient.properties.count - 2]["context_section"] as? String
    )

    /// Next tapped assertions.
    XCTAssertEqual("onboarding", self.segmentTrackingClient.properties.last?["context_page"] as? String)
    XCTAssertEqual("save_projects", self.segmentTrackingClient.properties.last?["context_section"] as? String)
    XCTAssertEqual("next", self.segmentTrackingClient.properties.last?["context_cta"] as? String)
  }
}
