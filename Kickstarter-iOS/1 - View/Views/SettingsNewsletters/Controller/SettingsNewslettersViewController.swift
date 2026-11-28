import KDS
import KsApi

import Prelude
import UIKit

internal final class SettingsNewslettersViewController: UIViewController {
  private var settingsFeature: SettingsFeature!
  private var sessionFeature: SessionFeature!
  fileprivate lazy var dataSource = SettingsNewslettersDataSource(settingsFeature: self.settingsFeature)
  fileprivate lazy var viewModel = SettingsNewslettersViewModel(
    settingsFeature: self.settingsFeature,
    sessionFeature: self.sessionFeature
  )

  @IBOutlet fileprivate var tableView: UITableView!

  internal static func instantiate(
    settingsFeature: SettingsFeature, sessionFeature: SessionFeature
  ) -> SettingsNewslettersViewController {
    let viewController = Storyboard.SettingsNewsletters.instantiate(SettingsNewslettersViewController.self)
    viewController.settingsFeature = settingsFeature
    viewController.sessionFeature = sessionFeature
    return viewController
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    self.tableView.register(nib: .SettingsNewslettersTopCell)
    self.tableView.register(nib: .SettingsNewslettersCell)
    self.tableView.dataSource = self.dataSource
    self.tableView.delegate = self
    self.tableView.tableHeaderView = nil
    self.tableView.tableFooterView = nil
    self.applyStyles()
    self.configureBindings()
    self.viewModel.viewDidLoad()
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    self.applyStyles()
  }

  private func applyStyles() {
    _ = self.view
      |> \.backgroundColor .~ LegacyColors.ksr_support_100.uiColor()

    _ = self.tableView
      |> \.backgroundColor .~ LegacyColors.ksr_support_100.uiColor()
      |> UITableView.lens.separatorStyle .~ .none
      |> UITableView.lens.estimatedRowHeight .~ 127
      |> UITableView.lens.allowsSelection .~ false

    self.title = Strings.Newsletters()
  }

  private func configureBindings() {
    self.viewModel.onUser = { [weak self] user in
      self?.dataSource.load(newsletters: Newsletter.allCases, user: user)
      self?.tableView.reloadData()
    }
  }
}

extension SettingsNewslettersViewController: UITableViewDelegate {
  internal func tableView(_: UITableView, willDisplay cell: UITableViewCell, forRowAt _: IndexPath) {
    if let cell = cell as? SettingsNewslettersTopCell, cell.delegate == nil {
      cell.delegate = self
    } else if let cell = cell as? SettingsNewslettersCell, cell.delegate == nil {
      cell.delegate = self
    }
  }
}

extension SettingsNewslettersViewController: SettingsNewslettersCellDelegate {
  func failedToUpdateUser(_ message: String) {
    let errorAlert = UIAlertController.genericError(message)
    self.present(errorAlert, animated: true, completion: nil)
  }

  func didUpdate(user: User) {
    self.viewModel.didUpdate(user: user)
  }

  func shouldShowOptInAlert(_ newsletterName: String) {
    let optInAlert = UIAlertController.newsletterOptIn(newsletterName)
    self.present(optInAlert, animated: true, completion: nil)
  }
}

extension SettingsNewslettersViewController: SettingsNewslettersTopCellDelegate {
  func didUpdateAllNewsletters(user: User) {
    self.viewModel.didUpdate(user: user)
  }

  func failedToUpdateAllNewsletters(_ message: String) {
    let errorAlert = UIAlertController.genericError(message)
    self.present(errorAlert, animated: true, completion: nil)
  }
}
