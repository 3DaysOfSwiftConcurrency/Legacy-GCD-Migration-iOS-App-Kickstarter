import Foundation
import KsApi
import Observation

public typealias FeatureEnabled = (feature: Feature, isEnabled: Bool)

@MainActor
@Observable
public final class FeatureFlagToolsViewModel {
  public private(set) var reloadWithData: [Features] = []
  private let settingsFeature: SettingsFeature
  private var sortedFeatures: [FeatureEnabled] = []
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
    guard self.sortedFeatures.indices.contains(index),
          self.settingsFeature.setConfigurationFlag(self.sortedFeatures[index].feature, enabled: isEnabled)
    else { return }
    self.scheduleReload()
  }
  private func reload() {
    guard let features = self.settingsFeature.configurationFlags else { return }
    self.sortedFeatures = features
    self.reloadWithData = features.map { [$0.feature.rawValue: $0.isEnabled] }
  }
  internal func waitForReload() async { await self.reloadTask?.value }
}

public func featureEnabledFromDictionaries(_ dictionaryArray: [Features]) -> [FeatureEnabled] {
  return dictionaryArray.compactMap { dictionary -> (Feature, Bool)? in
    dictionary.compactMap { key, value in
      guard let feature = Feature(rawValue: key) else { return nil }
      return (feature, value)
    }
    .first
  }
}
