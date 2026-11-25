import Foundation
import KsApi
import Observation

@MainActor
@Observable
public final class ProjectNotificationsViewModel {
  public private(set) var projectNotifications: [ProjectNotification] = []
  var onNotifications: (([ProjectNotification]) -> Void)?
  private let settingsFeature: SettingsFeature
  @ObservationIgnored private var loadingTask: Task<Void, Never>?

  public init(settingsFeature: SettingsFeature) {
    self.settingsFeature = settingsFeature
  }

  public func viewDidLoad() {
    self.loadingTask?.cancel()
    let settingsFeature = self.settingsFeature
    self.loadingTask = Task { [weak self] in
      do {
        let values = try await settingsFeature.loadProjectNotifications()
        try Task.checkCancellation()
        self?.projectNotifications = values
        self?.onNotifications?(values)
      } catch {
        // Preserve the existing list's silent failure behavior.
      }
    }
  }

  func waitForLoading() async { await self.loadingTask?.value }
  deinit { self.loadingTask?.cancel() }
}
