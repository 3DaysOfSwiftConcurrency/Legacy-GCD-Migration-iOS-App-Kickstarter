import Experimentation
import KsApi

/// Returns the value for a given Statsig feature flag. User defaults are checked first and,
/// if a value is found, it is returned immediately as an "override" (e.g. via beta tools).
/// Otherwise, the value from the Statsig client is used, falling back to
/// `false` if neither place has a value.
@MainActor
public func statsigFeatureEnabled(feature: StatsigFeature) -> Bool {
  if let valueFromDefaults = AppEnvironment.current.userDefaults
    .statsigFeatureFlags[feature.rawValue] {
    return valueFromDefaults
  }

  if let valueFromStatsig = AppEnvironment.current.statsigClient?
    .isFeatureEnabled(featureKey: feature) {
    return valueFromStatsig
  }

  return false
}

extension StatsigClientType {
  /* Returns all features the app knows about */

  public func allFeatures() -> [StatsigFeature] {
    return StatsigFeature.allCases
  }

  @MainActor
  public func isFeatureEnabled(featureKey key: StatsigFeature) -> Bool {
    self.checkGate(for: key) == true
  }
}
