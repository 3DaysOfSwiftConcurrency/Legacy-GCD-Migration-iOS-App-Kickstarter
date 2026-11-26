import Foundation
import KsApi

/// Delivers UI feedback for Settings commands launched by an incoming link.
@MainActor
public final class SettingsLinkPresentation {
  private let settingsFeature: SettingsFeature
  private let presentationDelaySeconds: () -> TimeInterval
  private let waitForPresentationDelay: @MainActor (TimeInterval) async throws -> Void
  private var notificationSaveTasks: [UUID: Task<Void, Never>] = [:]
  private var emailVerification: (id: UUID, task: Task<Void, Never>)?

  public init(
    settingsFeature: SettingsFeature,
    presentationDelaySeconds: @escaping () -> TimeInterval,
    waitForPresentationDelay: @escaping @MainActor (TimeInterval) async throws -> Void = { seconds in
      if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
    }
  ) {
    self.settingsFeature = settingsFeature
    self.presentationDelaySeconds = presentationDelaySeconds
    self.waitForPresentationDelay = waitForPresentationDelay
  }

  deinit {
    self.notificationSaveTasks.values.forEach { $0.cancel() }
    self.emailVerification?.task.cancel()
  }

  func saveNotificationPreference(
    name: String, enabled: Bool, onComplete: @escaping @MainActor () -> Void
  ) {
    guard let request = self.settingsFeature.startNotificationPreferenceSave(named: name, enabled: enabled) else { return }
    let session = self.settingsFeature.sessionFeature
    let userID = session.currentUser?.id
    let generation = session.generation
    let operation = session.wrapOperationForCurrentSession { try await request.value }
    let waitForPresentationDelay = self.waitForPresentationDelay
    let seconds = self.presentationDelaySeconds()
    let id = UUID()
    self.notificationSaveTasks[id] = Task { [weak self] in
      defer { self?.notificationSaveTasks[id] = nil }
      do {
        _ = try await operation()
        try await waitForPresentationDelay(seconds)
        try Task.checkCancellation()
        guard session.isCurrent(userID: userID, generation: generation) else { return }
        onComplete()
      } catch { /* Failed, cancelled or obsolete writes do not report success. */ }
    }
  }

  func verifyEmail(
    token: String, onComplete: @escaping @MainActor (String, Bool) -> Void
  ) {
    self.emailVerification?.task.cancel()
    let request = self.settingsFeature.startEmailVerification(token: token)
    let session = self.settingsFeature.sessionFeature
    let userID = session.currentUser?.id
    let generation = session.generation
    let operation = session.wrapOperationForCurrentSession { try await request.value }
    let waitForPresentationDelay = self.waitForPresentationDelay
    let seconds = self.presentationDelaySeconds()
    let id = UUID()
    let task = Task { [weak self] in
      defer {
        if self?.emailVerification?.id == id { self?.emailVerification = nil }
      }
      let result: Result<EmailVerificationResponseEnvelope, Error>
      do { result = .success(try await operation()) }
      catch { result = .failure(error) }
      do {
        try await waitForPresentationDelay(seconds)
        try Task.checkCancellation()
        guard session.isCurrent(userID: userID, generation: generation) else { return }
        switch result {
        case let .success(response): onComplete(response.message, true)
        case let .failure(error):
          if error is CancellationError { return }
          let message = (error as? ErrorEnvelope)?.errorMessages.first ?? Strings.Something_went_wrong_please_try_again()
          onComplete(message, false)
        }
      } catch { /* A newer request or owner cancellation suppresses presentation. */ }
    }
    self.emailVerification = (id, task)
  }

  func waitForPendingSettingsLinkResponses() async {
    for task in Array(self.notificationSaveTasks.values) { await task.value }
    await self.emailVerification?.task.value
  }
}
