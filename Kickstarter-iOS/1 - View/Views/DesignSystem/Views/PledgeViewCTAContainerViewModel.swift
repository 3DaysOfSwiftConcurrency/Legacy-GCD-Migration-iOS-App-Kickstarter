import Foundation
import KsApi

@MainActor
public final class PledgeViewCTAContainerViewModel {
  private let pledgeFeature: PledgeFeature
  public struct Display {
    let applePayButtonIsHidden: Bool
    let continueButtonIsHidden: Bool
    let submitButtonIsHidden: Bool
    let submitButtonIsEnabled: Bool
    let submitButtonTitle: String
    let pledgeImmediatelyLabelIsHidden: Bool
  }

  public var onApplePay: (() -> Void)?
  public var onContinue: (() -> Void)?
  public var onSubmit: (() -> Void)?
  public var onHelp: ((HelpType) -> Void)?

  public init(pledgeFeature: PledgeFeature) {
    self.pledgeFeature = pledgeFeature
  }

  public func configureWith(value: PledgeViewCTAContainerViewData) -> Display {
    Display(
      applePayButtonIsHidden: value.context.applePayButtonHidden || !value.isLoggedIn,
      continueButtonIsHidden: value.isLoggedIn,
      submitButtonIsHidden: !value.isLoggedIn,
      submitButtonIsEnabled: value.isEnabled,
      submitButtonTitle: value.willRetryPaymentMethod ? Strings.Retry() : value.context.submitButtonTitle,
      pledgeImmediatelyLabelIsHidden: value.context != .latePledge
    )
  }

  public func applePayButtonTapped() { self.onApplePay?() }
  public func continueButtonTapped() { self.onContinue?() }
  public func submitButtonTapped() { self.onSubmit?() }
  public func tapped(_ url: URL) {
    guard let helpType = self.pledgeFeature.helpType(for: url) else { return }
    self.onHelp?(helpType)
  }

  func termsLinks() -> (terms: String, privacy: String, cookie: String)? {
    guard let terms = self.pledgeFeature.helpURLString(for: .terms),
          let privacy = self.pledgeFeature.helpURLString(for: .privacy),
          let cookie = self.pledgeFeature.helpURLString(for: .cookie) else { return nil }
    return (terms, privacy, cookie)
  }
}
