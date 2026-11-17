import Foundation
import KsApi

/// Coordinates account refresh and the application feedback produced by Settings and shortcuts.
@MainActor
final class AccountRefreshCoordinator {
  private let applicationShortcuts: ApplicationShortcutService
  private let settingsFeature: SettingsFeature

  var onForceLogout: (() -> Void)?
  var onPostNotification: ((Notification) -> Void)?
  var onSetApplicationShortcutItems: (([ShortcutItem]) -> Void)?
  var onUpdateCurrentUser: ((User) -> Void)?

  init(applicationShortcuts: ApplicationShortcutService, settingsFeature: SettingsFeature) {
    self.applicationShortcuts = applicationShortcuts
    self.settingsFeature = settingsFeature
  }

  deinit {
    let settingsFeature = self.settingsFeature
    Task { @MainActor in
      settingsFeature.cancelScheduledAccountRefresh()
      settingsFeature.cancelAccountSetupRefresh()
    }
  }

  func refreshAccountAndSetup() {
    self.scheduleUserRefresh()
    self.refreshAccountSetup()
  }

  func refreshAfterSignOut() {
    self.scheduleUserRefresh()
  }

  func currentUserUpdatedInEnvironment() {
    self.onPostNotification?(Notification(name: .ksr_userUpdated, object: nil))
  }

  private func scheduleUserRefresh() {
    self.settingsFeature.scheduleAccountRefresh { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let user):
        if let user { self.onUpdateCurrentUser?(user) }
        self.refreshShortcutItems(for: user)
      case .failure(let error):
        if (error as? ErrorEnvelope)?.ksrCode == .AccessTokenInvalid { self.onForceLogout?() }
      }
    }
  }

  func waitForUserRefresh() async {
    await self.settingsFeature.waitForScheduledAccountRefresh()
  }

  private func refreshShortcutItems(for user: User?) {
    self.applicationShortcuts.refresh(for: user) { [weak self] available in
      self?.onSetApplicationShortcutItems?(
        available ? [.recommendedForYou, .projectsWeLove, .search] : [.projectsWeLove, .search]
      )
    }
  }

  func waitForShortcutUpdate() async { await self.applicationShortcuts.waitForRefresh() }

  private func refreshAccountSetup() {
    self.settingsFeature.refreshAccountSetup {
      NotificationCenter.default.post(.init(name: .ksr_userUpdated))
    }
  }
}
