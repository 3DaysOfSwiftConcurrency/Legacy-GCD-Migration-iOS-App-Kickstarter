import KsApi

import UIKit

internal final class ProjectNotificationsDataSource: ValueCellDataSource {
  private let settingsFeature: SettingsFeature
  private let sessionFeature: SessionFeature

  internal init(settingsFeature: SettingsFeature, sessionFeature: SessionFeature) {
    self.settingsFeature = settingsFeature
    self.sessionFeature = sessionFeature
    super.init()
  }

  internal func load(notifications: [ProjectNotification]) {
    self.set(
      values: notifications,
      cellClass: ProjectNotificationCell.self,
      inSection: 0
    )
  }

  internal override func configureCell(tableCell cell: UITableViewCell, withValue value: Any) {
    switch (cell, value) {
    case let (cell as ProjectNotificationCell, value as ProjectNotification):
      cell.configure(settingsFeature: self.settingsFeature, sessionFeature: self.sessionFeature)
      cell.configureWith(value: value)
    default:
      assertionFailure("Unrecognized (\(type(of: cell)), \(type(of: value))) combo.")
    }
  }
}
