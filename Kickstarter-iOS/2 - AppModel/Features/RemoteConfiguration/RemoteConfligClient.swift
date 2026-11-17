import FirebaseCrashlytics
import FirebaseRemoteConfig
import Foundation

public class RemoteConfigClient: RemoteConfigClientType {
  @MainActor static func reportActivationFailure(_ error: Error) {
    let value = error as NSError
    if value.domain != RemoteConfigErrorDomain || value.code != RemoteConfigError.internalError.rawValue {
      Crashlytics.crashlytics().record(error: error)
    }
  }

  @MainActor public func fetchAndActivateAsync() async throws {
    _ = try await self.sharedClient.fetchAndActivate()
  }
  public func fetchAndActivate(completionHandler: (@Sendable (RemoteConfigFetchAndActivateStatus, Error?) -> Void)?) {
    self.sharedClient.fetchAndActivate(completionHandler: completionHandler)
  }

  private var sharedClient: RemoteConfig

  public init(with client: RemoteConfig) {
    self.sharedClient = client
  }

  public func activate(completion: (@Sendable (Bool, Error?) -> Void)?) {
    self.sharedClient.activate(completion: completion)
  }

  public func fetch(completionHandler: (@Sendable (RemoteConfigFetchStatus, Error?) -> Void)?) {
    self.sharedClient.fetch(completionHandler: completionHandler)
  }

  public func setDefaults(_ defaults: [String: NSObject]?) {
    self.sharedClient.setDefaults(defaults)
  }

  public func addOnConfigUpdateListener(remoteConfigUpdateCompletion listener: @escaping @Sendable (
    RemoteConfigUpdate?,
    Error?
  ) -> Void) -> ConfigUpdateListenerRegistration {
    self.sharedClient.addOnConfigUpdateListener(remoteConfigUpdateCompletion: listener)
  }

  public func configValue(forKey key: String?) -> RemoteConfigValue {
    self.sharedClient.configValue(forKey: key)
  }
}
