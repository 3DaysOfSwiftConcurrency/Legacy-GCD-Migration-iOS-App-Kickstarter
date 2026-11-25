import KsApi

/// Return remote config values either a value from the cloud, if it found one, or an override value from user defaults.
@MainActor
func remoteConfigFeatureIsEnabled(_ feature: RemoteConfigFeature) -> Bool {
  let environment: Environment = AppEnvironment.current
  return remoteConfigFeatureIsEnabled(feature, in: environment)
}

func remoteConfigFeatureIsEnabled(_ feature: RemoteConfigFeature, in environment: Environment) -> Bool {
  if let valueFromDefaults = environment.userDefaults
    .remoteConfigFeatureFlags[feature.rawValue] {
    return valueFromDefaults
  }

  if let valueFromRemoteConfig = environment.remoteConfigClient?
    .isFeatureEnabled(featureKey: feature) {
    return valueFromRemoteConfig
  }

  return false
}

@MainActor
public func featureUseKeychainForOAuthTokenEnabled() -> Bool {
  remoteConfigFeatureIsEnabled(.useKeychainForOAuthToken)
}
