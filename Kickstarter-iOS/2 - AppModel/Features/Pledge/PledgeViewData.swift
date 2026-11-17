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
