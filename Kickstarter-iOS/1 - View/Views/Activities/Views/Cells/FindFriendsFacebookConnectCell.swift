import Observation
import FacebookLogin
import KDS

import Prelude
import UIKit

@MainActor
protocol FindFriendsFacebookConnectCellDelegate: AnyObject {
  func findFriendsFacebookConnectCellDidFacebookConnectUser()
  func findFriendsFacebookConnectCellDidDismissHeader()
  func findFriendsFacebookConnectCellShowErrorAlert(_ alert: AlertError)
}

internal final class FindFriendsFacebookConnectCell: UITableViewCell, ValueCell {
  @IBOutlet fileprivate var cardView: UIView!
  @IBOutlet fileprivate var closeButton: UIButton!
  @IBOutlet fileprivate var containerView: UIView!
  @IBOutlet fileprivate var facebookConnectButton: UIButton!
  @IBOutlet fileprivate var subtitleLabel: UILabel!
  @IBOutlet fileprivate var titleLabel: UILabel!

  internal weak var delegate: FindFriendsFacebookConnectCellDelegate?

  fileprivate var viewModel: FindFriendsFacebookConnectCellViewModel?

  internal lazy var fbLoginManager: LoginManager = {
    let manager = LoginManager()
    manager.defaultAudience = .friends
    return manager
  }()

  internal func configureWith(value: FriendsSource) {
    guard let viewModel else {
      preconditionFailure("FindFriendsFacebookConnectCell requires SettingsFeature composition.")
    }
    viewModel.configureWith(source: value)
  }

  internal func configure(settingsFeature: SettingsFeature, sessionFeature: SessionFeature) {
    guard self.viewModel == nil else { return }
    let viewModel = FindFriendsFacebookConnectCellViewModel(
      settingsFeature: settingsFeature,
      sessionFeature: sessionFeature
    )
    self.viewModel = viewModel
    self.observeState()
    viewModel.onAttemptLogin = { [weak self] in self?.attemptFacebookLogin() }
    viewModel.onDismiss = { [weak self] in self?.delegate?.findFriendsFacebookConnectCellDidDismissHeader() }
    viewModel.onConnected = { [weak self] in self?.delegate?.findFriendsFacebookConnectCellDidFacebookConnectUser() }
    viewModel.onError = { [weak self] in self?.delegate?.findFriendsFacebookConnectCellShowErrorAlert($0) }
  }

  private func observeState() {
    guard let viewModel = self.viewModel else { return }
    withObservationTracking {
      self.closeButton.isHidden = viewModel.hideCloseButton
      self.titleLabel.text = viewModel.title
      self.subtitleLabel.text = viewModel.subtitle
      self.facebookConnectButton.setTitle(viewModel.buttonTitle, for: .normal)
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.observeState() }
    }
  }

  internal override func bindStyles() {
    super.bindStyles()

    _ = self
      |> feedTableViewCellStyle

    _ = self.cardView
      |> cardStyle()

    _ = self.containerView
      |> UIView.lens.layoutMargins .~ .init(all: Styles.grid(2))

    self.containerView.backgroundColor = Colors.Background.Surface.primary.uiColor()

    _ = self.titleLabel
      |> UILabel.lens.font .~ .ksr_headline(size: 14)
      |> UILabel.lens.textColor .~ LegacyColors.ksr_support_700.uiColor()
      |> UILabel.lens.contentCompressionResistancePriority(for: .vertical) .~ .required

    _ = self.subtitleLabel
      |> UILabel.lens.font .~ .ksr_subhead(size: 12)
      |> UILabel.lens.textColor .~ LegacyColors.ksr_support_400.uiColor()

    _ = self.closeButton
      |> UIButton.lens.tintColor .~ LegacyColors.ksr_support_700.uiColor()
      |> UIButton.lens.targets .~ [(self, action: #selector(self.closeButtonTapped), .touchUpInside)]
      |> UIButton.lens.contentEdgeInsets .~ .init(
        top: Styles.grid(1), left: Styles.grid(3),
        bottom: Styles.grid(3), right: Styles.grid(2)
      )

    _ = self.facebookConnectButton
      |> facebookButtonStyle
      |> UIButton.lens.targets .~ [
        (self, action: #selector(self.facebookConnectButtonTapped), .touchUpInside)
      ]
      |> UIButton.lens.contentCompressionResistancePriority(for: .vertical) .~ .required
  }

  // MARK: - Facebook Login

  fileprivate func attemptFacebookLogin() {
    self.fbLoginManager.logIn(
      permissions: ["public_profile", "email", "user_friends"], from: nil
    ) { result, error in
      if let error = error {
        self.viewModel?.facebookLoginFail(error: error)
      } else if let result = result, !result.isCancelled {
        self.viewModel?.facebookLoginSuccess(result: result)
      }
    }
  }

  @objc func closeButtonTapped() {
    self.viewModel?.closeButtonTapped()
  }

  @objc func facebookConnectButtonTapped() {
    self.viewModel?.facebookConnectButtonTapped()
  }
}
