import KsApi
import Prelude

public enum ManagePledgeAction: CaseIterable {
  case editPledgeOverTimePledge
  case changePaymentMethod
  case chooseAnotherReward
  case contactCreator
  case cancelPledge
  case viewRewards
}

struct ManagedPledge {
  let backing: Backing

  var hasPaymentSchedule: Bool { !self.backing.paymentIncrements.isEmpty }

  var needsStandalonePaymentRepair: Bool {
    // Pledges paid in increments use the payment schedule's repair action.
    !self.hasPaymentSchedule && self.backing.status == .errored
  }

  func showsPaymentMethod(viewerIsCreator: Bool) -> Bool {
    !viewerIsCreator && (self.needsStandalonePaymentRepair || self.backing.paymentSource != nil)
  }

  func availableActions(for project: Project, viewerIsCreator: Bool) -> [ManagePledgeAction] {
    if viewerIsCreator { return [.viewRewards] }
    guard project.state == .live else { return [.viewRewards, .contactCreator] }
    guard self.backing.status != .preauth else { return [.contactCreator] }

    let editAction: ManagePledgeAction = self.hasPaymentSchedule || project.isPledgeOverTimeAllowed == true
      ? .editPledgeOverTimePledge : .chooseAnotherReward
    return [.changePaymentMethod, editAction, .contactCreator, .cancelPledge]
  }

  var rewards: [Reward] {
    var rewardIDs: Set<Int> = []
    let rewards = [self.backing.reward ?? .noReward] + (self.backing.addOns ?? [])
    return rewards.filter { rewardIDs.insert($0.id).inserted }
  }

  var rewardMinimum: Double {
    if let rewardsAmount = self.backing.rewardsAmount { return rewardsAmount }
    let baseRewardAmount = self.backing.reward?.minimum ?? 0
    let addOnAmount = (self.backing.addOns ?? []).reduce(0.0) { total, addOn in
      total.addingCurrency(addOn.minimum)
    }
    return baseRewardAmount + addOnAmount
  }
}

struct ManagedPledgeDetails {
  let project: Project
  let pledge: ManagedPledge
  let viewerIsCreator: Bool

  func paymentSelection(context: PledgeViewContext) -> PledgeViewData {
    PledgeViewData(
      project: self.project,
      rewards: self.pledge.rewards,
      bonusSupport: nil,
      selectedShippingRule: nil,
      selectedQuantities: selectedRewardQuantities(in: self.pledge.backing),
      selectedLocationId: self.pledge.backing.locationId,
      refTag: nil,
      context: context
    )
  }
}

extension PledgeFeature {
  func managedPledgeDetails(project: Project, backing: Backing) -> ManagedPledgeDetails {
    ManagedPledgeDetails(
      project: project |> Project.lens.personalization.backing .~ backing,
      pledge: ManagedPledge(backing: backing),
      viewerIsCreator: self.viewerIsCreator(of: project)
    )
  }
}
