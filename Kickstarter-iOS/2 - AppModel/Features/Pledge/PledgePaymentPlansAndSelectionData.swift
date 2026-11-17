import GraphAPI
import KsApi

public enum PledgePaymentPlansType: Equatable {
  case pledgeInFull
  case pledgeOverTime
}

public struct PledgePaymentPlansAndSelectionData {
  public var ineligible: Bool
  public var paymentIncrements: [PledgePaymentIncrement]
  public var project: Project
  public var selectedPlan: PledgePaymentPlansType

  public init(
    selectedPlan: PledgePaymentPlansType,
    increments paymentIncrements: [PledgePaymentIncrement] = [],
    ineligible: Bool = false,
    project: Project
  ) {
    self.ineligible = ineligible
    self.paymentIncrements = paymentIncrements
    self.project = project
    self.selectedPlan = selectedPlan
  }

  public var isPledgeOverTime: Bool {
    self.selectedPlan == .pledgeOverTime
  }
}

extension PledgePaymentPlansAndSelectionData {
  public init(
    withPaymentPlanFragment paymentPlan: GraphAPI.BuildPaymentPlanQuery.Data.Project.PaymentPlan,
    selectedPlan: PledgePaymentPlansType,
    project: Project
  ) {
    var increments: [PledgePaymentIncrement] = []

    if let fetchedIncrements = paymentPlan.paymentIncrements {
      increments = fetchedIncrements
        .compactMap { PledgePaymentIncrement(withGraphQLFragment: $0.fragments.paymentIncrementFragment) }
    }

    self.init(
      selectedPlan: selectedPlan,
      increments: increments,
      ineligible: !paymentPlan.amountIsPledgeOverTimeEligible,
      project: project
    )
  }
}
