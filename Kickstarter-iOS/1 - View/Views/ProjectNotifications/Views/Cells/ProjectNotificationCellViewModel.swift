import Foundation
import KsApi
import Prelude

@MainActor
public final class ProjectNotificationCellViewModel {
  var onName: ((String) -> Void)?
  var onSwitch: ((Bool) -> Void)?
  var onError: ((String) -> Void)?
  private let settingsFeature: SettingsFeature
  private let sessionFeature: SessionFeature
  private var notification: ProjectNotification?
  private var presentation: Task<Void, Never>?
  private var revision = UUID()
  private var lastSwitch: Bool?

  public init(settingsFeature: SettingsFeature, sessionFeature: SessionFeature) {
    self.settingsFeature = settingsFeature
    self.sessionFeature = sessionFeature
  }

  private func publishSwitch(_ on: Bool) {
    guard self.lastSwitch != on else { return }
    self.lastSwitch = on
    self.onSwitch?(on)
  }

  public func configureWith(notification: ProjectNotification) {
    self.revision = UUID()
    self.presentation?.cancel()
    let current = self.settingsFeature.cachedProjectNotification(notification)
    self.notification = current
    self.onName?(current.project.name)
    self.publishSwitch(current.email && current.mobile)
  }

  public func notificationTapped(on: Bool) {
    guard let source = self.notification else { return }
    self.publishSwitch(on)
    let edited = source |> ProjectNotification.lens.email .~ on |> ProjectNotification.lens.mobile .~ on
    self.presentation?.cancel()
    let revision = UUID()
    self.revision = revision
    let settingsFeature = self.settingsFeature
    let session = self.sessionFeature
    let userID = session.currentUser?.id
    let generation = session.generation
    guard let command = try? settingsFeature.startProjectNotificationSave(edited) else { return }
    self.presentation = Task { [weak self] in
      let result = await command.result
      guard !Task.isCancelled else { return }
      guard let self, self.revision == revision,
            session.isCurrent(userID: userID, generation: generation) else { return }
      if case let .failure(error) = result, !(error is CancellationError) {
        let confirmed = settingsFeature.cachedProjectNotification(source)
        self.onError?((error as? ErrorEnvelope)?.errorMessages.first ?? Strings.profile_settings_error())
        self.publishSwitch(confirmed.email && confirmed.mobile)
      }
    }
  }

  func waitForPresentation() async { await self.presentation?.value }
}
