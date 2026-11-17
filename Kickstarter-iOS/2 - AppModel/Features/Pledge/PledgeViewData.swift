import KsApi

public typealias SelectedRewardId = Int
public typealias SelectedRewardQuantity = Int
public typealias SelectedRewardQuantities = [SelectedRewardId: SelectedRewardQuantity]

public struct PledgeViewData: Equatable {
  public let project: Project
  public let rewards: [Reward]
  public let bonusSupport: Double?
  public let selectedShippingRule: ShippingRule?
  public let selectedQuantities: SelectedRewardQuantities
  public let selectedLocationId: Int?
  public let refTag: RefTag?
  public let context: PledgeViewContext

  func retriesExistingPayment(with payment: PaymentSourceSelected?) -> Bool {
    self.context == .fixPaymentMethod &&
      self.project.personalization.backing?.paymentSource?.id == payment?.savedCreditCardId
  }

  func backingRequests(
    payment: PaymentSourceSelected?, plan: PledgePaymentPlansType, applePay: ApplePayParams?
  ) -> (create: CreateBackingData, update: UpdateBackingData?)? {
    guard let total = PledgeAmounts(self).total else { return nil }
    let paymentID = payment?.savedCreditCardId
    let incremental = plan == .pledgeOverTime
    let create: CreateBackingData = (
      project: self.project, rewards: self.rewards, pledgeTotal: total,
      selectedQuantities: self.selectedQuantities, shippingRule: self.selectedShippingRule,
      paymentSourceId: paymentID, setupIntentClientSecret: nil, applePayParams: applePay,
      refTag: self.refTag, incremental: incremental
    )
    let update: UpdateBackingData? = self.project.personalization.backing.map { backing in
      (
        backing: backing, rewards: self.rewards, pledgeTotal: total,
        selectedQuantities: self.selectedQuantities, shippingRule: self.selectedShippingRule,
        paymentSourceId: paymentID, setupIntentClientSecret: nil, applePayParams: applePay,
        pledgeContext: self.context, incremental: incremental
      )
    }
    return (create: create, update: update)
  }
}

public typealias CreateBackingData = (
  project: Project,
  rewards: [Reward],
  pledgeTotal: Double,
  selectedQuantities: SelectedRewardQuantities,
  shippingRule: ShippingRule?,
  paymentSourceId: String?,
  setupIntentClientSecret: String?,
  applePayParams: ApplePayParams?,
  refTag: RefTag?,
  incremental: Bool?
)
public typealias UpdateBackingData = (
  backing: Backing,
  rewards: [Reward],
  pledgeTotal: Double,
  selectedQuantities: SelectedRewardQuantities,
  shippingRule: ShippingRule?,
  paymentSourceId: String?,
  setupIntentClientSecret: String?,
  applePayParams: ApplePayParams?,
  pledgeContext: PledgeViewContext,
  incremental: Bool
)

struct PledgeAmounts {
  let rewards: Double
  let shipping: Double
  let bonus: Double
  let total: Double?

  init(_ data: PledgeViewData) {
    let calculatedRewards = calculateAllRewardsTotal(addOnRewards: data.rewards, selectedQuantities: data.selectedQuantities)
    rewards = data.context == .fixPaymentMethod
      ? data.project.personalization.backing?.rewardsAmount ?? calculatedRewards
      : calculatedRewards
    shipping = data.selectedShippingRule.map {
      calculateShippingTotal(shippingRule: $0, addOnRewards: data.rewards, quantities: data.selectedQuantities)
    } ?? data.project.personalization.backing?.shippingAmount ?? 0
    bonus = data.bonusSupport ?? data.project.personalization.backing?.bonusAmount ?? 0
    total = data.context == .fixPaymentMethod
      ? data.project.personalization.backing?.amount
      : calculatePledgeTotal(pledgeAmount: bonus, shippingCost: shipping, addOnRewardsTotal: rewards)
  }
}

struct PostCampaignAmounts {
  let rewards: Double
  let shipping: Double
  let total: Double

  init(_ data: PledgeViewData) {
    rewards = calculateAllRewardsTotal(addOnRewards: data.rewards, selectedQuantities: data.selectedQuantities)
    shipping = data.selectedShippingRule.map {
      calculateShippingTotal(shippingRule: $0, addOnRewards: data.rewards, quantities: data.selectedQuantities)
    } ?? 0
    total = calculatePledgeTotal(pledgeAmount: data.bonusSupport ?? 0, shippingCost: shipping, addOnRewardsTotal: rewards)
  }
}
