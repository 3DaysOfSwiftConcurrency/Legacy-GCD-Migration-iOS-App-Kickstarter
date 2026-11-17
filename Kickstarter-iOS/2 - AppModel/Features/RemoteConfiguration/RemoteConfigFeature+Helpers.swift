import KsApi

/// Return remote config values either a value from the cloud, if it found one, or an override value from user defaults.
@MainActor
func featureEnabled(feature: RemoteConfigFeature) -> Bool {
  let environment: Environment = AppEnvironment.current
  return featureEnabled(feature: feature, environment: environment)
}

func featureEnabled(feature: RemoteConfigFeature, environment: Environment) -> Bool {
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
public func featureBypassPledgeManagerDecisionPolicyEnabled() -> Bool {
  return featureEnabled(feature: .bypassPledgeManagerDecisionPolicy)
}

@MainActor
public func featureUseKeychainForOAuthTokenEnabled() -> Bool {
  featureEnabled(feature: .useKeychainForOAuthToken)
}
