import Foundation
import KsApi

/// Delivers UI feedback for Settings commands launched by an incoming link.
@MainActor
public final class SettingsLinkPresentation {
  private let settingsFeature: SettingsFeature
  private let responseDelay: () -> TimeInterval
  private let sleep: @MainActor (TimeInterval) async throws -> Void
  private var notificationTasks: [UUID: Task<Void, Never>] = [:]
  private var verification: (id: UUID, task: Task<Void, Never>)?

  public init(
    settingsFeature: SettingsFeature,
    responseDelay: @escaping () -> TimeInterval,
    sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { seconds in
      if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
    }
  ) {
    self.settingsFeature = settingsFeature
    self.responseDelay = responseDelay
    self.sleep = sleep
  }

  deinit {
    self.notificationTasks.values.forEach { $0.cancel() }
    self.verification?.task.cancel()
  }

  func updateNotification(
    name: String, enabled: Bool, onComplete: @escaping @MainActor () -> Void
  ) {
    guard let request = self.settingsFeature.requestNotification(named: name, enabled: enabled) else { return }
    let session = self.settingsFeature.sessionFeature
    let userID = session.currentUser?.id
    let generation = session.generation
    let operation = session.sessionBound { try await request.value }
    let delay = self.sleep
    let seconds = self.responseDelay()
    let id = UUID()
    self.notificationTasks[id] = Task { [weak self] in
      defer { self?.notificationTasks[id] = nil }
      do {
        _ = try await operation()
        try await delay(seconds)
        try Task.checkCancellation()
        guard session.isCurrent(userID: userID, generation: generation) else { return }
        onComplete()
      } catch { /* Failed, cancelled or obsolete writes do not report success. */ }
    }
  }

  func verifyEmail(
    token: String, onComplete: @escaping @MainActor (String, Bool) -> Void
  ) {
    self.verification?.task.cancel()
    let request = self.settingsFeature.requestVerification(token: token)
    let session = self.settingsFeature.sessionFeature
    let userID = session.currentUser?.id
    let generation = session.generation
    let operation = session.sessionBound { try await request.value }
    let delay = self.sleep
    let seconds = self.responseDelay()
    let id = UUID()
    let task = Task { [weak self] in
      defer {
        if self?.verification?.id == id { self?.verification = nil }
      }
      let result: Result<EmailVerificationResponseEnvelope, Error>
      do { result = .success(try await operation()) }
      catch { result = .failure(error) }
      do {
        try await delay(seconds)
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
    self.verification = (id, task)
  }

  func waitForOperations() async {
    for task in Array(self.notificationTasks.values) { await task.value }
    await self.verification?.task.value
  }
}
