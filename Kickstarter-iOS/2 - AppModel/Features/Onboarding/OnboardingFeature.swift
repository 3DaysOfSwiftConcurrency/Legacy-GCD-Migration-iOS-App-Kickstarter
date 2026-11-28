import AppTrackingTransparency
import Foundation
import UIKit
import UserNotifications

/// Owns onboarding completion, permission eligibility, and application-scoped consent requests.
@MainActor
public final class OnboardingFeature {
  public struct Analytics {
    let pageViewed: @MainActor (OnboardingItemType) -> Void
    let buttonTapped: @MainActor (KSRAnalytics.CTAContext, OnboardingItemType?) -> Void
    let permissionsDialogViewed: @MainActor (KSRAnalytics.SectionContext) -> Void
    let pushPermissionCompleted: @MainActor (KSRAnalytics.SectionContext, UNAuthorizationStatus) -> Void
    let trackingPermissionCompleted: @MainActor (KSRAnalytics.SectionContext) -> Void

    public init(
      pageViewed: @escaping @MainActor (OnboardingItemType) -> Void = { _ in },
      buttonTapped: @escaping @MainActor (KSRAnalytics.CTAContext, OnboardingItemType?) -> Void = { _, _ in },
      permissionsDialogViewed: @escaping @MainActor (KSRAnalytics.SectionContext) -> Void = { _ in },
      pushPermissionCompleted: @escaping @MainActor (KSRAnalytics.SectionContext, UNAuthorizationStatus) -> Void = { _, _ in },
      trackingPermissionCompleted: @escaping @MainActor (KSRAnalytics.SectionContext) -> Void = { _ in }
    ) {
      self.pageViewed = pageViewed
      self.buttonTapped = buttonTapped
      self.permissionsDialogViewed = permissionsDialogViewed
      self.pushPermissionCompleted = pushPermissionCompleted
      self.trackingPermissionCompleted = trackingPermissionCompleted
    }
  }

  private struct PendingNotificationRequest {
    let id: UUID
    let options: UInt
    let task: Task<Bool, Never>
  }

  private let completionStore: () -> any KeyValueStoreType
  private let authorizeNotifications: (UNAuthorizationOptions) async -> Bool
  private let registerNotifications: () -> Void
  private let notificationStatus: () async -> UNAuthorizationStatus
  private let shouldRequestTracking: () -> Bool
  private let trackingAuthorization: (() async -> ATTrackingManager.AuthorizationStatus)?
  private var notificationRequest: PendingNotificationRequest?
  private var trackingRequest: Task<UInt, Never>?
  private let pushRegistration: () -> PushRegistrationType.Type
  private let tracking: () -> (any AppTrackingTransparencyType)?
  private let analytics: Analytics
  private var pushAuthorizationTasks: [UUID: Task<Void, Never>] = [:]
  private var delayedTrackingCheckTasks: [UUID: Task<Void, Never>] = [:]
  private var hasDeniedPushAuthorization = false
  private var hasPreparedTracking = false
  private var latestApplicationActiveState: Bool?
  private var lastActivationStateHandledForTracking: Bool?
  private var trackingAuthorizationObservation: (tracking: any AppTrackingTransparencyType, id: UUID)?

  var onBadgeReset: (@MainActor () -> Void)?
  var onRegistrationAttempted: (@MainActor () -> Void)?
  var onOfferOnboarding: (@MainActor () -> Void)?
  var onTrackingAuthorizationStatus: (@MainActor (AppTrackingAuthorization) -> Void)?

  public init(
    completionStore: @escaping () -> any KeyValueStoreType,
    authorizeNotifications: @escaping (UNAuthorizationOptions) async -> Bool = { options in
      (try? await UNUserNotificationCenter.current().requestAuthorization(options: options)) ?? false
    },
    registerNotifications: @escaping () -> Void = { UIApplication.shared.registerForRemoteNotifications() },
    notificationStatus: @escaping () async -> UNAuthorizationStatus = {
      await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    },
    shouldRequestTracking: @escaping () -> Bool = { false },
    trackingAuthorization: (() async -> ATTrackingManager.AuthorizationStatus)? = nil,
    pushRegistration: @escaping () -> PushRegistrationType.Type = { PushRegistration.self },
    tracking: @escaping () -> (any AppTrackingTransparencyType)? = { nil },
    analytics: Analytics = Analytics()
  ) {
    self.completionStore = completionStore
    self.authorizeNotifications = authorizeNotifications
    self.registerNotifications = registerNotifications
    self.notificationStatus = notificationStatus
    self.shouldRequestTracking = shouldRequestTracking
    self.trackingAuthorization = trackingAuthorization
    self.pushRegistration = pushRegistration
    self.tracking = tracking
    self.analytics = analytics
  }

  public var hasSeenOnboarding: Bool { self.completionStore().hasSeenOnboarding }
  public func markOnboardingCompleted() { self.completionStore().hasSeenOnboarding = true }
  public var shouldOfferOnboarding: Bool { self.shouldRequestTracking() && !self.hasSeenOnboarding }
  public var shouldRequestTrackingAuthorization: Bool {
    guard let tracking = self.tracking() else { return false }
    return tracking.advertisingIdentifier == nil && tracking.shouldRequestAuthorizationStatus()
  }
  public func fetchNotificationAuthorizationStatus() async -> UNAuthorizationStatus { await self.notificationStatus() }

  public func trackPageViewed(_ item: OnboardingItemType) { self.analytics.pageViewed(item) }
  public func trackButtonTapped(_ context: KSRAnalytics.CTAContext, item: OnboardingItemType? = nil) {
    self.analytics.buttonTapped(context, item)
  }
  public func trackPermissionsDialogViewed(_ section: KSRAnalytics.SectionContext) {
    self.analytics.permissionsDialogViewed(section)
  }
  public func trackPushPermissionCompleted(
    _ section: KSRAnalytics.SectionContext, status: UNAuthorizationStatus
  ) {
    self.analytics.pushPermissionCompleted(section, status)
  }
  public func trackTrackingPermissionCompleted(_ section: KSRAnalytics.SectionContext) {
    self.analytics.trackingPermissionCompleted(section)
  }

  /// A system prompt is application-scoped. Equal callers share it, while a
  /// different option set waits for the admitted prompt to settle.
  public func requestNotificationAuthorization(options: UNAuthorizationOptions) async -> Bool {
    if let pending = self.notificationRequest, pending.options == options.rawValue {
      return await pending.task.value
    }

    let previous = self.notificationRequest?.task
    let id = UUID()
    let task = Task { [authorizeNotifications, registerNotifications] in
      if let previous { _ = await previous.value }
      let granted = await authorizeNotifications(options)
      if granted { registerNotifications() }
      return granted
    }
    self.notificationRequest = .init(id: id, options: options.rawValue, task: task)
    let value = await task.value
    if self.notificationRequest?.id == id { self.notificationRequest = nil }
    return value
  }
  public func requestTrackingAuthorization() async -> ATTrackingManager.AuthorizationStatus {
    if let task = self.trackingRequest {
      return ATTrackingManager.AuthorizationStatus(rawValue: await task.value) ?? .notDetermined
    }
    let task = Task { [trackingAuthorization, tracking] in
      if let trackingAuthorization { return await trackingAuthorization().rawValue }
      guard let tracking = tracking() else { return AppTrackingAuthorization.notDetermined.rawValue }
      return await withCheckedContinuation { continuation in
        tracking.requestAndSetAuthorizationStatus { continuation.resume(returning: $0.rawValue) }
      }
    }
    self.trackingRequest = task
    let value = await task.value
    self.trackingRequest = nil
    return ATTrackingManager.AuthorizationStatus(rawValue: value) ?? .notDetermined
  }

  deinit {
    self.pushAuthorizationTasks.values.forEach { $0.cancel() }
    self.delayedTrackingCheckTasks.values.forEach { $0.cancel() }
    if let observation = self.trackingAuthorizationObservation {
      Task { @MainActor in observation.tracking.removeAuthorizationObserver(observation.id) }
    }
  }

  func preparePushNotificationsForLaunch() {
    self.checkPushAuthorizationAtLaunch()
    self.resetBadgeIfPushAuthorized()
  }

  private final class OperationState {
    var finished = false
  }

  private func startTrackedPushOperation(
    _ start: (@escaping @MainActor (Bool) -> Void) -> Task<Void, Never>?,
    completion: @escaping @MainActor (Bool) -> Void
  ) {
    let id = UUID()
    let state = OperationState()
    let task = start { [weak self] value in
      state.finished = true
      self?.pushAuthorizationTasks[id] = nil
      completion(value)
    }
    if let task, !state.finished { self.pushAuthorizationTasks[id] = task }
  }

  private func checkPushAuthorizationAtLaunch() {
    if self.hasDeniedPushAuthorization { self.triggerOnboardingIfEligible() }
    self.startTrackedPushOperation({ completion in
      self.pushRegistration().hasAuthorizedNotifications(completion: completion)
    }) { [weak self] authorized in
      guard let self else { return }
      if authorized {
        self.startPushNotificationRegistration()
      } else {
        self.hasDeniedPushAuthorization = true
        self.triggerOnboardingIfEligible()
      }
    }
  }

  func resetBadgeIfPushAuthorized() {
    self.startTrackedPushOperation({ completion in
      self.pushRegistration().hasAuthorizedNotifications(completion: completion)
    }) { [weak self] authorized in
      if authorized { self?.onBadgeReset?() }
    }
  }

  func startPushNotificationRegistration() {
    self.startTrackedPushOperation({ completion in
      self.pushRegistration().register(
        for: [.alert, .sound, .badge],
        requestAuthorization: { [weak self] options in
          guard let self else { return false }
          return await self.requestNotificationAuthorization(options: options)
        },
        completion: completion
      )
    }) { [weak self] _ in self?.onRegistrationAttempted?() }
  }

  private func triggerOnboardingIfEligible() {
    guard self.shouldOfferOnboarding else { return }
    self.onOfferOnboarding?()
  }

  func prepareTrackingConsent() {
    self.hasPreparedTracking = true
    self.scheduleTrackingRequestIfNeeded()
    self.observeTrackingAuthorization()
  }

  func setApplicationActive(_ state: Bool) {
    self.latestApplicationActiveState = state
    self.scheduleTrackingRequestIfNeeded()
    self.observeTrackingAuthorization()
  }

  private func scheduleTrackingRequestIfNeeded() {
    guard self.hasPreparedTracking, let active = self.latestApplicationActiveState,
          self.lastActivationStateHandledForTracking != active else { return }
    self.lastActivationStateHandledForTracking = active
    guard active else { return }

    let id = UUID()
    self.delayedTrackingCheckTasks[id] = Task { [weak self] in
      defer { self?.delayedTrackingCheckTasks[id] = nil }
      do {
        try await Task.sleep(for: .seconds(1))
        try Task.checkCancellation()
        guard let self, self.hasSeenOnboarding else { return }
        guard let tracking = self.tracking() else { return }
        if tracking.advertisingIdentifier == nil, tracking.shouldRequestAuthorizationStatus() {
          _ = await self.requestTrackingAuthorization()
        }
      } catch { /* Cancellation ends pending consent checks. */ }
    }
  }

  private func observeTrackingAuthorization() {
    let tracking = self.tracking()
    if let previous = self.trackingAuthorizationObservation {
      if let tracking, (previous.tracking as AnyObject) === (tracking as AnyObject) { return }
      previous.tracking.removeAuthorizationObserver(previous.id)
      self.trackingAuthorizationObservation = nil
    }
    guard let tracking else { return }
    let id = tracking.observeAuthorizationStatus { [weak self] status in
      self?.onTrackingAuthorizationStatus?(status)
    }
    self.trackingAuthorizationObservation = (tracking, id)
  }

  func waitForDelayedTrackingChecks() async {
    for task in Array(self.delayedTrackingCheckTasks.values) { await task.value }
  }
}
