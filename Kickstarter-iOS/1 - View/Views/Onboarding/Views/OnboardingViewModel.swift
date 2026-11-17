import AppTrackingTransparency
import Foundation
import KsApi
import Observation
import UserNotifications

@MainActor
@Observable
public final class OnboardingViewModel {
  @MainActor private var completionTask: Task<Void, Never>?
  @MainActor private var completionVersion = UUID()
  var onTrackingPrompt: (() -> Void)?
  var onNotificationCompletion: ((UNAuthorizationStatus) -> Void)?

  /// Own the subscriptions for this appearance and invalidate callbacks on exit.
  @MainActor public func bind(
    items: @escaping ([OnboardingItem]) -> Void,
    advance: @escaping () -> Void
  ) {
    self.stopObserving()
    items(self.onboardingItems)
    self.onNotificationCompletion = { [weak self] status in
      self?.didCompletePushNotificationsDialog(with: status)
      advance()
    }
    self.onTrackingPrompt = { [weak self] in
      self?.completeTracking(advance: advance)
    }
  }
  @MainActor public func cancelCompletion() {
    self.completionTask?.cancel()
    self.completionTask = nil
    self.completionVersion = UUID()
  }
  @MainActor public func stopObserving() {
    self.cancelCompletion()
    self.onNotificationCompletion = nil
    self.onTrackingPrompt = nil
  }
  @MainActor private func completeTracking(advance: @escaping () -> Void) {
    guard self.completionTask == nil else { return }
    let version = self.completionVersion
    let feature = self.onboardingFeature
    self.completionTask = Task { [weak self] in
      let status = await feature.requestTrackingAuthorization()
      guard !Task.isCancelled, let self, self.completionVersion == version else { return }
      self.didCompleteAppTrackingDialog(with: status)
      advance()
    }
  }

  // MARK: - Properties

  private let onboardingFeature: OnboardingFeature
  private let useCase: OnboardingUseCaseType

  // MARK: - Outputs

  public let onboardingItems: [OnboardingItem]

  // MARK: - Init

  public init(
    with bundle: Bundle = .main,
    onboardingFeature: OnboardingFeature
  ) {
    self.onboardingFeature = onboardingFeature
    self.useCase = OnboardingUseCase(for: bundle)

    self.onboardingItems = self.useCase.uiOutputs.onboardingItems

  }

  // MARK: - Inputs

  public func onAppear() {
    self.onboardingFeature.trackPageViewed(.welcome)
  }

  public func getNotifiedTapped() {
    guard self.completionTask == nil else { return }
    let feature = self.onboardingFeature
    let version = self.completionVersion
    self.completionTask = Task { [weak self] in
      let existing = await feature.currentNotificationStatus()
      guard !Task.isCancelled, let self, self.completionVersion == version else { return }
      guard existing != .authorized else { self.completionTask = nil; return }
      feature.trackPermissionsDialogViewed(.onboardingNotificationsDialog)
      _ = await feature.requestNotifications(options: [.alert, .sound, .badge])
      guard !Task.isCancelled, self.completionVersion == version else { return }
      let status = await feature.currentNotificationStatus()
      guard !Task.isCancelled, self.completionVersion == version else { return }
      self.onNotificationCompletion?(status)
    }

    feature.trackButtonTapped(.onboardingGetNotified, item: .enableNotifications)
  }

  public func allowTrackingTapped() {
    if self.onboardingFeature.shouldRequestTrackingAuthorization, let prompt = self.onTrackingPrompt {
      self.onboardingFeature.trackPermissionsDialogViewed(.onboardingAppTrackingDialog)
      prompt()
    }

    self.onboardingFeature.trackButtonTapped(.onboardingAllowTracking, item: .allowTracking)
  }

  public func didCompletePushNotificationsDialog(with authStatus: UNAuthorizationStatus) {
    /// Send analytics event when the user has finished interacting with the PN system dialog. `authStatus` let's insights know whether they allowed or denied permissions.

    self.onboardingFeature.trackPushPermissionCompleted(.onboardingNotificationsDialog, status: authStatus)
  }

  public func didCompleteAppTrackingDialog(with authStatus: ATTrackingManager.AuthorizationStatus) {
    /// Send analytics event if the user has allowed AppTracking permission.
    guard authStatus == .authorized else { return }

    self.onboardingFeature.trackTrackingPermissionCompleted(.onboardingAppTrackingDialog)
  }

  public func goToLoginSignupTapped() {
    self.onboardingFeature.trackButtonTapped(.onboardingSignUpLogIn, item: .loginSignUp)
    self.onboardingFeature.trackButtonTapped(.onboardingClose)
  }

  public func onboardingFlowEnded() {
    self.onboardingFeature.recordCompletion()
    self.onboardingFeature.trackButtonTapped(.onboardingClose)
  }

  public func goToNextItemTapped(item: OnboardingItem) {
    self.onboardingFeature.trackPageViewed(item.type)
    self.onboardingFeature.trackButtonTapped(.onboardingNext, item: item.type)
  }
}
