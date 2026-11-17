import AppTrackingTransparency
import Foundation
import UIKit
import UserNotifications

/// Owns onboarding completion and the system permissions requested by onboarding.
@MainActor
public final class OnboardingFeature {
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
  private let trackingAuthorization: () async -> ATTrackingManager.AuthorizationStatus
  private var notificationRequest: PendingNotificationRequest?
  private var trackingRequest: Task<UInt, Never>?

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
    trackingAuthorization: @escaping () async -> ATTrackingManager.AuthorizationStatus = { .notDetermined }
  ) {
    self.completionStore = completionStore
    self.authorizeNotifications = authorizeNotifications
    self.registerNotifications = registerNotifications
    self.notificationStatus = notificationStatus
    self.shouldRequestTracking = shouldRequestTracking
    self.trackingAuthorization = trackingAuthorization
  }

  public var hasSeenOnboarding: Bool { self.completionStore().hasSeenOnboarding }
  public func recordCompletion() { self.completionStore().hasSeenOnboarding = true }
  public var shouldOfferOnboarding: Bool { self.shouldRequestTracking() && !self.hasSeenOnboarding }
  public func currentNotificationStatus() async -> UNAuthorizationStatus { await self.notificationStatus() }

  /// A system prompt is application-scoped. Equal callers share it, while a
  /// different option set waits for the admitted prompt to settle.
  public func requestNotifications(options: UNAuthorizationOptions) async -> Bool {
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
    let task = Task { [trackingAuthorization] in await trackingAuthorization().rawValue }
    self.trackingRequest = task
    let value = await task.value
    self.trackingRequest = nil
    return ATTrackingManager.AuthorizationStatus(rawValue: value) ?? .notDetermined
  }
}
