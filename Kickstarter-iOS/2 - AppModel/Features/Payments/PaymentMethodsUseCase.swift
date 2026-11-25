import KsApi
import Observation

@MainActor
@Observable
public final class PaymentMethodsUseCase {
  public private(set) var selectedPaymentSource: PaymentSourceSelected?
  public private(set) var paymentMethodsViewHidden = true
  public private(set) var paymentMethodChangedAndValid = false
  var onHidden: ((Bool) -> Void)?
  var onConfiguration: ((PledgePaymentMethodsValue) -> Void)?
  var onSelected: ((PaymentSourceSelected?) -> Void)?
  var onValidity: ((Bool) -> Void)?
  private var pledgeViewData: PledgeViewData?
  private var lastKnownLoginState: Bool?
  private var lastSelectedPaymentSource: PaymentSourceSelected?
  private let currentUser: @MainActor () -> User?

  public init(currentUser: @escaping @MainActor () -> User?) {
    self.currentUser = currentUser
  }

  public func configurePaymentMethods(for pledgeViewData: PledgeViewData) {
    self.pledgeViewData = pledgeViewData
    self.lastKnownLoginState = self.currentUser() != nil
    self.sendConfigurationIfAvailable()
    self.publishPaymentMethodsVisibility()
    self.selectedPaymentSource = nil
    self.onSelected?(nil)
    let context = pledgeViewData.context
    self.publishValidity(context.isUpdating && (context == .updateReward || context == .editPledgeOverTime))
    if let source = self.lastSelectedPaymentSource, let reward = pledgeViewData.rewards.first {
      self.publishValidity(paymentMethodValid(project: pledgeViewData.project, reward: reward, paymentSource: source, context: context))
    }
  }

  public func updateLoginState(_ loggedIn: Bool) {
    guard self.lastKnownLoginState != loggedIn else { return }
    self.lastKnownLoginState = loggedIn
    if loggedIn { self.sendConfigurationIfAvailable() }
    self.publishPaymentMethodsVisibility()
  }

  public func selectPaymentSource(_ source: PaymentSourceSelected) {
    self.lastSelectedPaymentSource = source
    self.selectedPaymentSource = source
    self.onSelected?(source)
    guard let pledgeViewData = self.pledgeViewData, let reward = pledgeViewData.rewards.first else { return }
    self.publishValidity(paymentMethodValid(project: pledgeViewData.project, reward: reward, paymentSource: source, context: pledgeViewData.context))
  }

  private func sendConfigurationIfAvailable() {
    guard let pledgeViewData = self.pledgeViewData, !pledgeViewData.context.paymentMethodsViewHidden,
          let reward = pledgeViewData.rewards.first, let user = self.currentUser() else { return }
    self.onConfiguration?((user, pledgeViewData.project, "", reward, pledgeViewData.context, pledgeViewData.refTag))
  }

  private func publishPaymentMethodsVisibility() {
    guard let pledgeViewData = self.pledgeViewData, let loggedIn = self.lastKnownLoginState else { return }
    let hidden = !loggedIn || pledgeViewData.context.paymentMethodsViewHidden
    self.paymentMethodsViewHidden = hidden
    self.onHidden?(hidden)
  }

  private func publishValidity(_ valid: Bool) {
    self.paymentMethodChangedAndValid = valid
    self.onValidity?(valid)
  }
}

private func paymentMethodValid(
  project: Project,
  reward: Reward,
  paymentSource: PaymentSourceSelected,
  context: PledgeViewContext
) -> Bool {
  guard
    let backedPaymentSourceId = project.personalization.backing?.paymentSource?.id,
    context.isUpdating,
    userIsBacking(reward: reward, inProject: project)
  else {
    return true
  }

  if project.personalization.backing?.status == .errored {
    return true
  } else if backedPaymentSourceId != paymentSource.savedCreditCardId {
    return true
  }

  return false
}
