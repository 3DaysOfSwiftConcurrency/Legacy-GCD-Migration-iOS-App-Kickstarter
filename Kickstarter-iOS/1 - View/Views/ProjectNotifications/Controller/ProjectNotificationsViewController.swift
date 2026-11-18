import KDS
import KsApi

import Prelude
import UIKit

internal final class ProjectNotificationsViewController: UITableViewController {
  private var settingsFeature: SettingsFeature!
  fileprivate lazy var viewModel = ProjectNotificationsViewModel(settingsFeature: self.settingsFeature)
  fileprivate lazy var dataSource = ProjectNotificationsDataSource(settingsFeature: self.settingsFeature)

  internal static func instantiate(settingsFeature: SettingsFeature) -> ProjectNotificationsViewController {
    let viewController = Storyboard.Settings.instantiate(ProjectNotificationsViewController.self)
    viewController.settingsFeature = settingsFeature
    return viewController
  }

  internal override func viewDidLoad() {
    super.viewDidLoad()

    self.tableView.dataSource = self.dataSource
    self.tableView.delegate = self

    self.tableView.tableHeaderView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: Styles.grid(6)))
    self.tableView.rowHeight = 44.0

    self.viewModel.viewDidLoad()
  }

  override func bindStyles() {
    super.bindStyles()

    _ = self
      |> settingsViewControllerStyle

    _ = self.tableView
      |> \.separatorStyle .~ .singleLine
      |> \.separatorColor .~ LegacyColors.ksr_support_300.uiColor()
      |> \.separatorInset .~ .init(left: Styles.grid(2))
  }

  internal override func bindViewModel() {
    super.bindViewModel()

    self.viewModel.onNotifications = { [weak self] notifications in
      self?.dataSource.load(notifications: notifications)
      self?.tableView.reloadData()
    }
  }

  internal override func tableView(_: UITableView, willDisplay cell: UITableViewCell, forRowAt _: IndexPath) {
    if let cell = cell as? ProjectNotificationCell {
      cell.delegate = self
    }
  }
}

extension ProjectNotificationsViewController: UITabBarDelegate {
  override func tableView(_: UITableView, heightForFooterInSection _: Int) -> CGFloat {
    return 0.1 // Required to remove the footer in UITableViewStyleGrouped
  }
}

extension ProjectNotificationsViewController: ProjectNotificationCellDelegate {
  internal func projectNotificationCell(_: ProjectNotificationCell?, notificationSaveError: String) {
    self.present(
      UIAlertController.genericError(notificationSaveError),
      animated: true,
      completion: nil
    )
  }
}
