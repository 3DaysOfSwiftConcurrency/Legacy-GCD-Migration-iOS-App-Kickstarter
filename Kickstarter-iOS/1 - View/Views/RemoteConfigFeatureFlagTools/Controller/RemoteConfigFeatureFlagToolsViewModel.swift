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
  private let sleep: () async throws -> Void

  public init(
    settingsFeature: SettingsFeature,
    sleep: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }
  ) {
    self.settingsFeature = settingsFeature
    self.sleep = sleep
  }
  public func viewDidLoad() { self.reload() }
  private func scheduleReload() {
    self.reloadTask?.cancel()
    self.reloadTask = Task { [weak self, sleep] in
      do {
        try await sleep()
        try Task.checkCancellation()
        self?.reload()
      } catch { }
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
