import FirebaseRemoteConfig
import Foundation

private class MockRemoteConfigValue: RemoteConfigValue {
  var isEnabled = false

  override var boolValue: Bool { self.isEnabled }
}

public class MockRemoteConfigClient: RemoteConfigClientType {
  @MainActor public func fetchAndActivateAsync() async throws {
    throw URLError(.unsupportedURL)
  }
  public func fetchAndActivate(completionHandler _: (
    @Sendable (RemoteConfigFetchAndActivateStatus, Error?)
      -> Void
  )?) {}

  public var features: [String: Bool]

  public init() {
    self.features = [:]
  }

  public func activate(completion _: (@Sendable (Bool, Error?) -> Void)?) {}

  public func configValue(forKey key: String?) -> RemoteConfigValue {
    let mockConfigValue = MockRemoteConfigValue()

    guard let flagKey = key else {
      return mockConfigValue
    }

    mockConfigValue.isEnabled = self.features[flagKey] == true

    return mockConfigValue
  }

  public func fetch(completionHandler _: (@Sendable (RemoteConfigFetchStatus, Error?) -> Void)?) {}

  public func setDefaults(_: [String: NSObject]?) {}

  public func addOnConfigUpdateListener(remoteConfigUpdateCompletion _: @escaping @Sendable (
    RemoteConfigUpdate?,
    Error?
  ) -> Void) -> ConfigUpdateListenerRegistration {
    return ConfigUpdateListenerRegistration()
  }
}
