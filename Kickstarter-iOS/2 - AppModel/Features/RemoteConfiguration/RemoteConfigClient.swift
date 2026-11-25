import FirebaseCrashlytics
import FirebaseRemoteConfig
import Foundation

public class RemoteConfigClient: RemoteConfigClientType {
  @MainActor static func reportActivationFailure(_ error: Error) {
    let activationError = error as NSError
    if activationError.domain != RemoteConfigErrorDomain || activationError.code != RemoteConfigError.internalError.rawValue {
      Crashlytics.crashlytics().record(error: error)
    }
  }

  @MainActor public func fetchAndActivateAsync() async throws {
    _ = try await self.firebaseRemoteConfig.fetchAndActivate()
  }
  public func fetchAndActivate(completionHandler: (@Sendable (RemoteConfigFetchAndActivateStatus, Error?) -> Void)?) {
    self.firebaseRemoteConfig.fetchAndActivate(completionHandler: completionHandler)
  }

  private var firebaseRemoteConfig: RemoteConfig

  public init(with client: RemoteConfig) {
    self.firebaseRemoteConfig = client
  }

  public func activate(completion: (@Sendable (Bool, Error?) -> Void)?) {
    self.firebaseRemoteConfig.activate(completion: completion)
  }

  public func fetch(completionHandler: (@Sendable (RemoteConfigFetchStatus, Error?) -> Void)?) {
    self.firebaseRemoteConfig.fetch(completionHandler: completionHandler)
  }

  public func setDefaults(_ defaults: [String: NSObject]?) {
    self.firebaseRemoteConfig.setDefaults(defaults)
  }

  public func addOnConfigUpdateListener(remoteConfigUpdateCompletion listener: @escaping @Sendable (
    RemoteConfigUpdate?,
    Error?
  ) -> Void) -> ConfigUpdateListenerRegistration {
    self.firebaseRemoteConfig.addOnConfigUpdateListener(remoteConfigUpdateCompletion: listener)
  }

  public func configValue(forKey key: String?) -> RemoteConfigValue {
    self.firebaseRemoteConfig.configValue(forKey: key)
  }
}
