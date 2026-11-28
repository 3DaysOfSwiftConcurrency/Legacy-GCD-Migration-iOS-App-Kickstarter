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
