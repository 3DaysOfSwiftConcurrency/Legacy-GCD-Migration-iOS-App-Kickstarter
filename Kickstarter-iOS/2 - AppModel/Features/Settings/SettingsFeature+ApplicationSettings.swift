// Application settings ownership by Matthew Thomas.
import Experimentation
import Foundation
import KsApi
import Prelude

extension SettingsFeature {
  /// Storage and transport for effective settings. Reads stay live so replacing
  /// the environment does not create a competing cached Config in this Feature.
  public struct ApplicationSettings {
    let configuration: ApplicationConfigurationService
    let remoteConfiguration: RemoteConfigurationService
    let readConfiguration: @MainActor () -> Config?
    let currentCountryCode: @MainActor () -> String?
    let saveConfigurationOverride: @MainActor (Config) -> Void
    let userDefaults: @MainActor () -> any KeyValueStoreType
    let remoteClient: @MainActor () -> (any RemoteConfigClientType)?
    let statsigClient: @MainActor () -> (any StatsigClientType)?
    let installRemoteClient: @MainActor (any RemoteConfigClientType) -> Void
    let notificationCenter: NotificationCenter

    public init(
      configuration: ApplicationConfigurationService,
      remoteConfiguration: RemoteConfigurationService,
      readConfiguration: @escaping @MainActor () -> Config?,
      currentCountryCode: @escaping @MainActor () -> String?,
      saveConfigurationOverride: @escaping @MainActor (Config) -> Void,
      userDefaults: @escaping @MainActor () -> any KeyValueStoreType,
      remoteClient: @escaping @MainActor () -> (any RemoteConfigClientType)? = { nil },
      statsigClient: @escaping @MainActor () -> (any StatsigClientType)? = { nil },
      installRemoteClient: @escaping @MainActor (any RemoteConfigClientType) -> Void = { _ in },
      notificationCenter: NotificationCenter = .default
    ) {
      self.configuration = configuration
      self.remoteConfiguration = remoteConfiguration
      self.readConfiguration = readConfiguration
      self.currentCountryCode = currentCountryCode
      self.saveConfigurationOverride = saveConfigurationOverride
      self.userDefaults = userDefaults
      self.remoteClient = remoteClient
      self.statsigClient = statsigClient
      self.installRemoteClient = installRemoteClient
      self.notificationCenter = notificationCenter
    }
  }

  public var configurationFlags: [(feature: Feature, isEnabled: Bool)]? {
    guard let config = self.applicationSettings?.readConfiguration() else { return nil }
    return config.features.compactMap { key, value in
      Feature(rawValue: key).map { (feature: $0, isEnabled: value) }
    }.sorted { $0.feature.rawValue < $1.feature.rawValue }
  }

  @discardableResult
  public func setConfigurationFlag(_ feature: Feature, enabled: Bool) -> Bool {
    guard let settings = self.applicationSettings, let config = settings.readConfiguration(),
          let current = config.features[feature.rawValue], current != enabled else { return false }
    var features = config.features
    features[feature.rawValue] = enabled
    settings.saveConfigurationOverride(config |> Config.lens.features .~ features)
    settings.notificationCenter.post(name: .ksr_configUpdated, object: nil)
    return true
  }

  public var remoteConfigurationFlags: [(RemoteConfigFeature, Bool)] {
    RemoteConfigFeature.allCases.map { ($0, self.isRemoteConfigurationEnabled($0)) }
  }

  public func isRemoteConfigurationEnabled(_ feature: RemoteConfigFeature) -> Bool {
    let override = self.applicationSettings?.userDefaults().remoteConfigFeatureFlags[feature.rawValue]
    return override ?? self.applicationSettings?.remoteClient()?.isFeatureEnabled(featureKey: feature) ?? false
  }

  public func setRemoteConfigurationOverride(_ feature: RemoteConfigFeature, enabled: Bool) {
    self.applicationSettings?.userDefaults().remoteConfigFeatureFlags[feature.rawValue] = enabled
  }

  public var statsigFlags: [(StatsigFeature, Bool)] {
    StatsigFeature.allCases.map { ($0, self.isStatsigEnabled($0)) }
  }

  public func isStatsigEnabled(_ feature: StatsigFeature) -> Bool {
    let override = self.applicationSettings?.userDefaults().statsigFeatureFlags[feature.rawValue]
    return override ?? self.applicationSettings?.statsigClient()?.checkGate(for: feature) ?? false
  }

  public func setStatsigOverride(_ feature: StatsigFeature, enabled: Bool) {
    self.applicationSettings?.userDefaults().statsigFeatureFlags[feature.rawValue] = enabled
  }

  public var appStoreURL: String? { self.applicationSettings?.readConfiguration()?.iTunesLink }
  public var canOfferAppStoreRating: Bool { self.appStoreURL != nil }
  public var requiresConfiguredCountryNewsletterOptIn: Bool {
    self.applicationSettings?.readConfiguration()?.countryCode == "DE"
  }
  public var requiresCurrentCountryNewsletterOptIn: Bool {
    self.applicationSettings?.currentCountryCode() == "DE"
  }

  /// A prefetch shares the pending read without publishing configuration changes.
  public func requestApplicationSettings() -> Task<Config, Error> {
    guard let settings = self.applicationSettings else { return Task { throw CancellationError() } }
    return settings.configuration.requestConfiguration()
  }

  @discardableResult
  public func requestApplicationSettingsRefresh() -> Task<Config, Error> {
    guard let settings = self.applicationSettings else { return Task { throw CancellationError() } }
    return settings.configuration.refresh()
  }

  public func resetApplicationSettings() { self.applicationSettings?.configuration.reset() }

  @discardableResult
  public func activateRemoteSettings(client: any RemoteConfigClientType) -> Task<Void, Error> {
    guard let settings = self.applicationSettings else { return Task { throw CancellationError() } }
    settings.installRemoteClient(client)
    return settings.remoteConfiguration.activate(client: client)
  }
}
