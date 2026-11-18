// Configuration activation support by Matthew Thomas.
import Foundation

/// Retains one remote-configuration activation at a time for the active SDK client.
///
/// SettingsFeature owns this infrastructure and receives activation intents through AppModel.
@MainActor
public final class RemoteConfigurationService {
  private let notificationCenter: NotificationCenter
  private let reportFailure: @MainActor (Error) -> Void
  private var pendingActivation: (client: ObjectIdentifier, activationID: UUID, task: Task<Void, Error>)?

  public init(
    notificationCenter: NotificationCenter,
    reportFailure: @escaping @MainActor (Error) -> Void = { _ in }
  ) {
    self.notificationCenter = notificationCenter
    self.reportFailure = reportFailure
  }

  @discardableResult public func activate(client: any RemoteConfigClientType) -> Task<Void, Error> {
    let clientID = ObjectIdentifier(client)
    if let request = self.pendingActivation, request.client == clientID { return request.task }
    self.pendingActivation?.task.cancel()
    let activationID = UUID()
    let task = Task { [self] in
      defer { if self.pendingActivation?.activationID == activationID { self.pendingActivation = nil } }
      do {
        try Task.checkCancellation()
        try await client.fetchAndActivateAsync()
      } catch {
        try Task.checkCancellation()
        guard !(error is CancellationError), self.pendingActivation?.activationID == activationID else { throw CancellationError() }
        self.reportFailure(error)
        self.notificationCenter.post(name: .ksr_remoteConfigClientConfigurationFailed, object: nil)
        throw error
      }
      try Task.checkCancellation()
      guard self.pendingActivation?.activationID == activationID else { throw CancellationError() }
      self.notificationCenter.post(name: .ksr_remoteConfigClientConfigured, object: nil)
    }
    self.pendingActivation = (clientID, activationID, task)
    return task
  }
}
