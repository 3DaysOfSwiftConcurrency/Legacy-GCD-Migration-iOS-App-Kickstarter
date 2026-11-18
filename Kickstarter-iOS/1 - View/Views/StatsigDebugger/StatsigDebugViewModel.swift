import Foundation
import Observation

@MainActor
@Observable
final class StatsigDebugViewModel {
  private let settingsFeature: SettingsFeature

  init(settingsFeature: SettingsFeature = AppModel.shared.settingsFeature) {
    self.settingsFeature = settingsFeature
  }

  var isStatsigEnabled: Bool {
    self.settingsFeature.hasStatsigClient
  }

  func reload() {
    self.settingsFeature.reloadStatsig()
  }

  func showDebugger() {
    self.settingsFeature.showStatsigDebugger()
  }
}
