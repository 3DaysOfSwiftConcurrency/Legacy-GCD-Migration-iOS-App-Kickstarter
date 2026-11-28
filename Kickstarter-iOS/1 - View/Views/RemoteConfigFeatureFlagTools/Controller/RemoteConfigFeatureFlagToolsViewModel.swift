import Experimentation
import Foundation
import KsApi
import Observation

public typealias RemoteConfigFeatures = [(RemoteConfigFeature, Bool)]
public typealias StatsigFeatures = [(StatsigFeature, Bool)]

@MainActor
@Observable
public final class RemoteConfigFeatureFlagToolsViewModel {
  public private(set) var remoteConfigFeatures: RemoteConfigFeatures = []
  public private(set) var statsigFeatures: StatsigFeatures = []
  private let settingsFeature: SettingsFeature
  private var reloadTask: Task<Void, Never>?

  public init(settingsFeature: SettingsFeature) {
    self.settingsFeature = settingsFeature
  }
  public func viewDidLoad() { self.reload() }
  private func scheduleReload() {
    self.reloadTask?.cancel()
    self.reloadTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(1)) } catch { return }
      guard !Task.isCancelled else { return }
      self?.reload()
    }
  }
  public func setFeatureAtIndexEnabled(index: Int, isEnabled: Bool) {
    guard self.remoteConfigFeatures.indices.contains(index) else { return }
    self.settingsFeature.setRemoteConfigurationOverride(self.remoteConfigFeatures[index].0, enabled: isEnabled)
    self.scheduleReload()
  }
  public func setStatsigFeatureAtIndexEnabled(index: Int, isEnabled: Bool) {
    guard self.statsigFeatures.indices.contains(index) else { return }
    self.settingsFeature.setStatsigOverride(self.statsigFeatures[index].0, enabled: isEnabled)
    self.scheduleReload()
  }
  private func reload() {
    self.remoteConfigFeatures = self.settingsFeature.remoteConfigurationFlags
    self.statsigFeatures = self.settingsFeature.statsigFlags
  }
  internal func waitForReload() async { await self.reloadTask?.value }
}
