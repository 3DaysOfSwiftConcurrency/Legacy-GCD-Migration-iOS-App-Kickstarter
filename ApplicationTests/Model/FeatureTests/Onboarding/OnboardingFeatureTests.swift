@testable import Kickstarter_iOS
import AppTrackingTransparency
import Foundation
import UserNotifications
import XCTest

@MainActor
final class OnboardingFeatureTests: XCTestCase {
  func testTrackingAuthorizationEligibilityUsesComposedTrackingAdapter() {
    let tracking = MockAppTrackingTransparency()
    tracking.shouldRequestAuthStatus = true
    let feature = OnboardingFeature(
      completionStore: { [store = MockKeyValueStore()] in store },
      tracking: { tracking }
    )

    XCTAssertTrue(feature.shouldRequestTrackingAuthorization)

    tracking.updateAdvertisingIdentifier()

    XCTAssertFalse(feature.shouldRequestTrackingAuthorization)
  }

  func testTrackingAuthorizationIsIneligibleWithoutTrackingAdapter() {
    let feature = OnboardingFeature(
      completionStore: { [store = MockKeyValueStore()] in store }
    )

    XCTAssertFalse(feature.shouldRequestTrackingAuthorization)
  }

  func testApplicationAndOnboardingShareTheSameTrackingPrompt() async throws {
    let response = AccountRequestGate<UInt>()
    defer { response.releaseAll() }
    let store = MockKeyValueStore()
    store.hasSeenOnboarding = true
    let tracking = MockAppTrackingTransparency()
    let feature = OnboardingFeature(
      completionStore: { store },
      trackingAuthorization: {
        let rawValue = (try? await response.request()) ?? AppTrackingAuthorization.notDetermined.rawValue
        return AppTrackingAuthorization(rawValue: rawValue) ?? .notDetermined
      },
      tracking: { tracking }, trackingDelay: {}
    )
    feature.prepareTrackingConsent()
    feature.setApplicationActive(true)
    await response.waitFor(1)

    let onboardingJoined = expectation(description: "Onboarding joins the tracking prompt")
    let onboarding = Task {
      onboardingJoined.fulfill()
      return await feature.requestTrackingAuthorization()
    }
    await fulfillment(of: [onboardingJoined], timeout: 2)
    try response.finish(0, .success(AppTrackingAuthorization.authorized.rawValue))
    let status = await onboarding.value
    await feature.waitForTrackingChecks()

    XCTAssertEqual(status, .authorized)
    XCTAssertEqual(response.count, 1)
  }

  func testApplicationAndOnboardingShareTheSameNotificationPrompt() async throws {
    let response = AccountRequestGate<Bool>()
    defer { response.releaseAll() }
    var registrations = 0
    let feature = OnboardingFeature(
      completionStore: { [store = MockKeyValueStore()] in store },
      authorizeNotifications: { _ in (try? await response.request()) ?? false },
      registerNotifications: { registrations += 1 }
    )
    let applicationFinished = expectation(description: "Application request finishes")
    feature.onRegistrationAttempted = { applicationFinished.fulfill() }
    feature.requestNotificationAuthorization()
    await response.waitFor(1)

    let onboardingJoined = expectation(description: "Onboarding joins the prompt")
    let onboarding = Task {
      onboardingJoined.fulfill()
      return await feature.requestNotifications(options: [.alert, .sound, .badge])
    }
    await fulfillment(of: [onboardingJoined], timeout: 2)
    onboarding.cancel()
    try response.finish(0, .success(true))
    let granted = await onboarding.value
    await fulfillment(of: [applicationFinished], timeout: 2)

    XCTAssertTrue(granted)
    XCTAssertEqual(response.count, 1)
    XCTAssertEqual(registrations, 1)
  }

  func testCompletingOnboardingEnablesThePendingTrackingCheck() async throws {
    let delay = AccountRequestGate<Void>()
    defer { delay.releaseAll() }
    let tracking = MockAppTrackingTransparency()
    let feature = OnboardingFeature(
      completionStore: { [store = MockKeyValueStore()] in store },
      tracking: { tracking }, trackingDelay: { try await delay.request() }
    )
    feature.prepareTrackingConsent()
    feature.setApplicationActive(true)
    await delay.waitFor(1)
    XCTAssertEqual(tracking.requestCount, 0)
    feature.recordCompletion()
    try delay.finish(0, .success(()))
    await feature.waitForTrackingChecks()
    XCTAssertEqual(tracking.requestCount, 1)
  }

  func testRemovingTrackingAdapterStopsItsStatusDelivery() {
    let original = MockAppTrackingTransparency()
    var tracking: (any AppTrackingTransparencyType)? = original
    let feature = OnboardingFeature(
      completionStore: { [store = MockKeyValueStore()] in store }, tracking: { tracking }
    )
    var statuses: [AppTrackingAuthorization] = []
    feature.onTrackingAuthorizationStatus = { statuses.append($0) }
    feature.prepareTrackingConsent()
    tracking = nil
    feature.setApplicationActive(false)
    original.authorizationStatusValue = .denied
    XCTAssertEqual(statuses, [.notDetermined])
  }

  func testAcceptedPermissionRequestsStandardOptionsAndRegistersOnce() async {
    let store = MockKeyValueStore()
    let finished = self.expectation(description: "Authorization finishes")
    var requestedOptions: [UNAuthorizationOptions] = []
    var registrationCount = 0
    let onboarding = OnboardingFeature(
      completionStore: { store },
      authorizeNotifications: {
        requestedOptions.append($0)
        return true
      },
      registerNotifications: { registrationCount += 1 }
    )
    onboarding.onRegistrationAttempted = { finished.fulfill() }

    onboarding.requestNotificationAuthorization()
    await self.fulfillment(of: [finished], timeout: 2)
    XCTAssertEqual(requestedOptions, [[.alert, .sound, .badge]])
    XCTAssertEqual(registrationCount, 1)
  }

  func testEarlyActivationWaitsForLaunchAndDuplicateEventsShareTheDelay() async {
    let tracking = MockAppTrackingTransparency()
    var delayCount = 0
    let store = MockKeyValueStore()
    store.hasSeenOnboarding = true
    let consent = OnboardingFeature(
      completionStore: { store }, tracking: { tracking }, trackingDelay: { delayCount += 1 }
    )

    consent.setApplicationActive(true)
    await consent.waitForTrackingChecks()
    XCTAssertEqual(delayCount, 0)
    consent.prepareTrackingConsent()
    consent.setApplicationActive(true)
    await consent.waitForTrackingChecks()
    XCTAssertEqual(delayCount, 1)
    XCTAssertEqual(tracking.requestCount, 1)
  }

  func testReplacingTheTrackingAdapterRemovesThePreviousStatusObserver() {
    let old = MockAppTrackingTransparency()
    let replacement = MockAppTrackingTransparency()
    var tracking = old
    let consent = OnboardingFeature(
      completionStore: { [store = MockKeyValueStore()] in store }, tracking: { tracking }
    )
    var statuses: [AppTrackingAuthorization] = []
    consent.onTrackingAuthorizationStatus = { statuses.append($0) }

    consent.prepareTrackingConsent()
    tracking = replacement
    consent.setApplicationActive(false)
    old.authorizationStatusValue = .denied
    replacement.authorizationStatusValue = .restricted

    XCTAssertEqual(statuses, [.notDetermined, .notDetermined, .restricted])
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

}
