import Foundation
import UserNotifications

@MainActor
public protocol PushRegistrationType {
  static func register(
    for options: UNAuthorizationOptions,
    requestAuthorization: @escaping @MainActor (UNAuthorizationOptions) async -> Bool,
    completion: @escaping @MainActor (Bool) -> Void
  ) -> Task<Void, Never>?
  static func hasAuthorizedNotifications(completion: @escaping @MainActor (Bool) -> Void) -> Task<Void, Never>?
}
