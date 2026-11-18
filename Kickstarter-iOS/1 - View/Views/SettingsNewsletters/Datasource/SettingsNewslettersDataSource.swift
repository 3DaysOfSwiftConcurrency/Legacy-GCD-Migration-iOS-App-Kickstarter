import KsApi

import UIKit

internal final class SettingsNewslettersDataSource: ValueCellDataSource {
  private let settingsFeature: SettingsFeature

  internal init(settingsFeature: SettingsFeature) {
    self.settingsFeature = settingsFeature
    super.init()
  }

  internal enum Section: Int {
    case newsletters
  }

  internal func load(newsletters: [Newsletter], user: User) {
    let section = Section.newsletters.rawValue

    self.clearValues(section: section)

    self.appendRow(value: user, cellClass: SettingsNewslettersTopCell.self, toSection: section)

    _ = newsletters.map { ($0, user) }.map { value in
      self.appendRow(value: value, cellClass: SettingsNewslettersCell.self, toSection: section)
    }
  }

  override func configureCell(tableCell cell: UITableViewCell, withValue value: Any) {
    switch (cell, value) {
    case let (cell as SettingsNewslettersTopCell, value as User):
      cell.configure(settingsFeature: self.settingsFeature)
      cell.configureWith(value: value)
    case let (cell as SettingsNewslettersCell, value as (newsletter: Newsletter, user: User)):
      cell.configure(settingsFeature: self.settingsFeature)
      cell.configureWith(value: value)
    default:
      assertionFailure("Unrecognized (cell, viewModel) combo.")
    }
  }
}
