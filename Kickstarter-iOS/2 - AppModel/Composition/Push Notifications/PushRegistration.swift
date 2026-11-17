import Foundation
import UserNotifications

@MainActor
public struct PushRegistration: PushRegistrationType {
  public static func register(
    for options: UNAuthorizationOptions,
    requestAuthorization: @escaping @MainActor (UNAuthorizationOptions) async -> Bool,
    completion: @escaping @MainActor (Bool) -> Void
  ) -> Task<Void, Never>? {
    Task { @MainActor in
      guard !Task.isCancelled else { return }
      let granted = await requestAuthorization(options)
      guard !Task.isCancelled else { return }
      completion(granted)
    }
  }

  public static func hasAuthorizedNotifications(completion: @escaping @MainActor (Bool) -> Void) -> Task<Void, Never>? {
    Task { @MainActor in
      guard !Task.isCancelled else { return }
      let settings = await UNUserNotificationCenter.current().notificationSettings()
      guard !Task.isCancelled else { return }
      completion(settings.authorizationStatus == .authorized)
    }
  }
}

/// Coordinates the application's push-authorization checks and requests.
@MainActor
public final class PushAuthorization {
  private let pushRegistration: () -> PushRegistrationType.Type
  private let onboardingFeature: OnboardingFeature
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var hasDeniedPushAuthorization = false

  var onBadgeReset: (@MainActor () -> Void)?
  var onRegistrationAttempted: (@MainActor () -> Void)?
  var onOfferOnboarding: (@MainActor () -> Void)?

  public init(
    pushRegistration: @escaping () -> PushRegistrationType.Type,
    onboardingFeature: OnboardingFeature
  ) {
    self.pushRegistration = pushRegistration
    self.onboardingFeature = onboardingFeature
  }

  deinit { self.tasks.values.forEach { $0.cancel() } }

  func applicationDidFinishLaunching() {
    self.checkPushAuthorizationForLaunch()
    self.checkPushAuthorizationForBadge()
  }

  func applicationWillEnterForeground() {
    self.checkPushAuthorizationForBadge()
  }

  private final class OperationState {
    var finished = false
  }

  private func performPushOperation(
    _ start: (@escaping @MainActor (Bool) -> Void) -> Task<Void, Never>?,
    completion: @escaping @MainActor (Bool) -> Void
  ) {
    let id = UUID()
    let state = OperationState()
    let task = start { [weak self] value in
      state.finished = true
      self?.tasks[id] = nil
      completion(value)
    }
    if let task, !state.finished { self.tasks[id] = task }
  }

  private func checkPushAuthorizationForLaunch() {
    if self.hasDeniedPushAuthorization { self.triggerOnboardingIfEligible() }
    self.performPushOperation({ completion in
      self.pushRegistration().hasAuthorizedNotifications(completion: completion)
    }) { [weak self] authorized in
      guard let self else { return }
      if authorized {
        self.requestAuthorization()
      } else {
        self.hasDeniedPushAuthorization = true
        self.triggerOnboardingIfEligible()
      }
    }
  }

  private func checkPushAuthorizationForBadge() {
    self.performPushOperation({ completion in
      self.pushRegistration().hasAuthorizedNotifications(completion: completion)
    }) { [weak self] authorized in
      if authorized { self?.onBadgeReset?() }
    }
  }

  func requestAuthorization() {
    self.performPushOperation({ completion in
      self.pushRegistration().register(
        for: [.alert, .sound, .badge],
        requestAuthorization: { [onboardingFeature = self.onboardingFeature] options in
          await onboardingFeature.requestNotifications(options: options)
        },
        completion: completion
      )
    }) { [weak self] _ in self?.onRegistrationAttempted?() }
  }

  private func triggerOnboardingIfEligible() {
    guard self.onboardingFeature.shouldOfferOnboarding else { return }
    self.onOfferOnboarding?()
  }
}
