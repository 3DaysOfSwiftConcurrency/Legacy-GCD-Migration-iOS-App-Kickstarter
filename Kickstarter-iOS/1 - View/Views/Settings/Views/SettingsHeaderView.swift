
import Prelude
import UIKit

final class SettingsHeaderView: UITableViewHeaderFooterView {
  @IBOutlet fileprivate var titleLabel: UILabel!

  func configure(title: String) {
    _ = self
      |> \.accessibilityLabel .~ title
      |> \.accessibilityTraits .~ .header
      |> \.isAccessibilityElement .~ true

    _ = self.titleLabel
      |> \.text .~ title
  }

  override func didMoveToSuperview() {
    super.didMoveToSuperview()
    self.applyStyles()
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    self.applyStyles()
  }

  private func applyStyles() {
    _ = self.titleLabel
      |> settingsSectionLabelStyle
  }
}
