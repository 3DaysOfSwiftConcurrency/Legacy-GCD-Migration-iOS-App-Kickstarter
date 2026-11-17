// Application settings composition by Matthew Thomas.
import Foundation
import KsApi

extension ApplicationConfigurationService {
  public static func live() -> ApplicationConfigurationService {
    ApplicationConfigurationService(
      load: { try await AppEnvironment.current.apiService.applicationConfiguration() },
      installVisitorCookies: {
        guard let environment = AppEnvironment.current else { return }
        let visitorID = (environment.device.identifierForVendor ?? UUID()).uuidString
        let server = environment.apiService.serverConfig
        let domains = [server.webBaseUrl.host, server.apiBaseUrl.host].compactMap { $0 }
        for domain in domains {
          if let cookie = HTTPCookie(properties: [
            .name: "vis", .value: visitorID, .domain: domain,
            .path: "/", .version: 0, .expires: Date.distantFuture, .secure: true
          ]) {
            environment.cookieStorage.setCookie(cookie)
          }
        }
      },
      debugFeatureFlags: {
        guard let environment = AppEnvironment.current, !environment.mainBundle.isRelease else { return [:] }
        return environment.config?.features ?? [:]
      },
      applyConfiguration: { config in
        AppEnvironment.updateConfig(config)
        NotificationCenter.default.post(name: .ksr_configUpdated, object: nil)
      }
    )
  }
}

extension SettingsFeature.ApplicationSettings {
  static func live(
    configuration: ApplicationConfigurationService,
    remoteConfiguration: RemoteConfigurationService
  ) -> Self {
    Self(
      configuration: configuration, remoteConfiguration: remoteConfiguration,
      readConfiguration: { AppEnvironment.current.config },
      saveConfigurationOverride: { config in
        // Existing DebugData has whole-config precedence; update it before applying.
        AppEnvironment.updateDebugData(DebugData(config: config))
        AppEnvironment.updateConfig(config)
      },
      userDefaults: { AppEnvironment.current.userDefaults },
      remoteClient: { AppEnvironment.current.remoteConfigClient },
      statsigClient: { AppEnvironment.current.statsigClient },
      installRemoteClient: { AppEnvironment.updateRemoteConfigClient($0) }
    )
  }
}
