import Foundation
import KsApi

private enum KSRAnalyticsIdentityTraitValue: Equatable {
  case string(String)
  case bool(Bool)

  var value: Any {
    switch self {
    case let .string(value): return value
    case let .bool(value): return value
    }
  }
}

public struct KSRAnalyticsIdentityData: Equatable {
  public let userId: Int
  private let name: String
  private let notifications: User.Notifications

  init(_ user: User) {
    self.userId = user.id
    self.name = user.name
    self.notifications = user.notifications
  }

  public static func == (lhs: KSRAnalyticsIdentityData, rhs: KSRAnalyticsIdentityData) -> Bool {
    guard lhs.userId == rhs.userId else { return false }

    let uniqueTraits = lhs.uniqueTraits(comparedTo: rhs)

    return uniqueTraits.isEmpty
  }

  func uniqueTraits(comparedTo otherData: KSRAnalyticsIdentityData?) -> [String: Any] {
    var changedTraits: [String: Any] = [:]
    let previousTraits = otherData?.traits ?? [:]

    for key in self.traits.keys where self.traits[key] != previousTraits[key] {
      changedTraits[key] = self.traits[key]?.value
    }

    return changedTraits
  }

  var allTraits: [String: Any] {
    return self.traits.mapValues { $0.value }
  }

  fileprivate var traits: [String: KSRAnalyticsIdentityTraitValue] {
    let notifications = self.notifications.encode()
      .mapValues { ($0 as? Bool).flatMap(KSRAnalyticsIdentityTraitValue.bool) }
      .compactMapValues { $0 }

    return [
      "name": .string(self.name)
    ]
    .withAllValuesFrom(notifications)
  }
}

extension KSRAnalyticsIdentityData: Codable {
  private enum CodingKeys: String, CodingKey {
    case userId
    case name
    case notifications
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.userId, forKey: .userId)
    try container.encode(self.name, forKey: .name)

    let notificationsJSON = try JSONSerialization.data(withJSONObject: self.notifications.encode(), options: [])
    try container.encode(notificationsJSON, forKey: .notifications)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    self.userId = try container.decode(Int.self, forKey: .userId)
    self.name = try container.decode(String.self, forKey: .name)

    let notificationsJSON = try container.decode(Data.self, forKey: .notifications)
    self.notifications = try JSONDecoder().decode(User.Notifications.self, from: notificationsJSON)
  }
}
