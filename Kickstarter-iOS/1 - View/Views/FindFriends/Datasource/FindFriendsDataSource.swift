import KsApi

import Prelude
import UIKit

internal final class FindFriendsDataSource: ValueCellDataSource {
  private let friendsFeature: FriendsFeature
  private let settingsFeature: SettingsFeature

  init(friendsFeature: FriendsFeature, settingsFeature: SettingsFeature) {
    self.friendsFeature = friendsFeature
    self.settingsFeature = settingsFeature
    super.init()
  }

  fileprivate enum Section: Int {
    case facebookConnect
    case stats
    case friends
  }

  internal func facebookConnect(source: FriendsSource, visible: Bool) {
    self.set(
      values: visible ? [source] : [],
      cellClass: FindFriendsFacebookConnectCell.self,
      inSection: Section.facebookConnect.rawValue
    )
  }

  internal func stats(stats: FriendStatsEnvelope, source: FriendsSource) {
    self.set(
      values: [(stats, source)],
      cellClass: FindFriendsStatsCell.self,
      inSection: Section.stats.rawValue
    )
  }

  internal func friends(_ friends: [User], source: FriendsSource) {
    let friendAndSource = friends.map { (friend: $0, source: source) }

    self.set(
      values: friendAndSource,
      cellClass: FindFriendsFriendFollowCell.self,
      inSection: Section.friends.rawValue
    )
  }

  override func configureCell(tableCell cell: UITableViewCell, withValue value: Any) {
    switch (cell, value) {
    case let (cell as FindFriendsStatsCell, value as (FriendStatsEnvelope, FriendsSource)):
      cell.configureWith(value: value)
    case let (cell as FindFriendsFriendFollowCell, value as (User, FriendsSource)):
      cell.configure(friendsFeature: self.friendsFeature)
      cell.configureWith(value: value)
    case let (cell as FindFriendsFacebookConnectCell, value as FriendsSource):
      cell.configure(settingsFeature: self.settingsFeature)
      cell.configureWith(value: value)
    default:
      assertionFailure("Unrecognized combo: \(cell), \(value)")
    }
  }
}
