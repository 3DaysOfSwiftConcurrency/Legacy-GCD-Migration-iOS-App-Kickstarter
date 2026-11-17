// Configuration activation support by Matthew Thomas.
import Foundation

/// Retains one remote-configuration activation at a time for the active SDK client.
///
/// SettingsFeature owns this infrastructure and receives activation intents through AppModel.
@MainActor
public final class RemoteConfigurationService {
  private let notificationCenter: NotificationCenter
  private let reportFailure: @MainActor (Error) -> Void
  private var request: (client: ObjectIdentifier, id: UUID, task: Task<Void, Error>)?

  public init(
    notificationCenter: NotificationCenter,
    reportFailure: @escaping @MainActor (Error) -> Void = { _ in }
  ) {
    self.notificationCenter = notificationCenter
    self.reportFailure = reportFailure
  }

  @discardableResult public func activate(client: any RemoteConfigClientType) -> Task<Void, Error> {
    let clientID = ObjectIdentifier(client)
    if let request = self.request, request.client == clientID { return request.task }
    self.request?.task.cancel()
    let id = UUID()
    let task = Task { [self] in
      defer { if self.request?.id == id { self.request = nil } }
      do {
        try Task.checkCancellation()
        try await client.fetchAndActivateAsync()
      } catch {
        try Task.checkCancellation()
        guard !(error is CancellationError), self.request?.id == id else { throw CancellationError() }
        self.reportFailure(error)
        self.notificationCenter.post(name: .ksr_remoteConfigClientConfigurationFailed, object: nil)
        throw error
      }
      try Task.checkCancellation()
      guard self.request?.id == id else { throw CancellationError() }
      self.notificationCenter.post(name: .ksr_remoteConfigClientConfigured, object: nil)
    }
    self.request = (clientID, id, task)
    return task
  }
}
