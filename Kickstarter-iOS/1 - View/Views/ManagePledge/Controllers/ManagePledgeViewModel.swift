import Foundation
import KsApi
import Prelude

public typealias ManagePledgeViewParamConfigData = (
  projectParam: Param,
  backingParam: Param?
)

public typealias ManagePledgeAlertAction = ManagePledgeAction

@MainActor
public protocol ManagePledgeViewModelInputs {
  func beginRefresh()
  func configureWith(_ params: ManagePledgeViewParamConfigData)
  func cancelPledgeDidFinish(with message: String)
  func fixButtonTapped()
  func menuButtonTapped()
  func menuOptionSelected(with action: ManagePledgeAlertAction)
  func pledgeViewControllerDidUpdatePledgeWithMessage(_ message: String)
  func viewDidLoad()
  func termsOfUseTapped(with helpType: HelpType)
}

@MainActor
public protocol ManagePledgeViewModelOutputs: AnyObject {
  var onPaymentMethod: ((ManagePledgePaymentMethodViewData) -> Void)? { get set }
  var onPledgeSummary: ((ManagePledgeSummaryViewData) -> Void)? { get set }
  var onEndRefreshing: (() -> Void)? { get set }
  var onCancelPledge: ((CancelPledgeViewData) -> Void)? { get set }
  var onChangePaymentMethod: ((PledgeViewData) -> Void)? { get set }
  var onContactCreator: ((MessageSubject, KSRAnalytics.MessageDialogContext) -> Void)? { get set }
  var onFixPaymentMethod: ((PledgeViewData) -> Void)? { get set }
  var onRewards: ((Project) -> Void)? { get set }
  var onEditPledgeOverTime: ((Project) -> Void)? { get set }
  var onLoadProjectAndRewards: ((Project, [Reward]) -> Void)? { get set }
  var onLoadRefreshHeader: (() -> Void)? { get set }
  var onFinish: ((String?) -> Void)? { get set }
  var onPaymentMethodHidden: ((Bool) -> Void)? { get set }
  var onPledgeDetailsLabel: ((String) -> Void)? { get set }
  var onRightBarButtonHidden: ((Bool) -> Void)? { get set }
  var onShowMenu: (([ManagePledgeAlertAction]) -> Void)? { get set }
  var onShowError: ((String) -> Void)? { get set }
  var onShowSuccess: ((String) -> Void)? { get set }
  var onShowHelp: ((HelpType) -> Void)? { get set }
  var onStartRefreshing: (() -> Void)? { get set }
  var onTitle: ((String) -> Void)? { get set }
  var onPlotSchedule: (([PledgePaymentIncrement]) -> Void)? { get set }
  var onPlotScheduleHidden: ((Bool) -> Void)? { get set }
}

@MainActor
public protocol ManagePledgeViewModelType {
  var inputs: ManagePledgeViewModelInputs { get }
  var outputs: ManagePledgeViewModelOutputs { get }
}

@MainActor
private final class ManagePledgeReadIdentity {
  var id: UUID?
}

@MainActor
public final class ManagePledgeViewModel:
  ManagePledgeViewModelType, ManagePledgeViewModelInputs, ManagePledgeViewModelOutputs {
  private let pledgeFeature: PledgeFeature
  private let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
  private var loadedSession: PledgeFeature.SessionIdentity?
  private var configuredParams: ManagePledgeViewParamConfigData?
  private var hasLoadedView = false
  private var rightBarHidden: Bool?
  private var paymentMethodHidden: Bool?
  private var loadedProject: Project?
  private var loadedBacking: Backing?
  private var hasSeenDisallowedCancellation = false
  private let projectRoute = UUID()
  private var projectReadTask: Task<Void, Never>?
  private let projectReadIdentity = ManagePledgeReadIdentity()
  private let backingRoute = UUID()
  private var backingReadTask: Task<Void, Never>?
  private let backingReadIdentity = ManagePledgeReadIdentity()
  deinit {
    self.backingReadTask?.cancel()
    self.projectReadTask?.cancel()
    let pledgeFeature = self.pledgeFeature, projectRoute = self.projectRoute, backingRoute = self.backingRoute
    Task { @MainActor in
      pledgeFeature.releaseRead(route: projectRoute)
      pledgeFeature.releaseRead(route: backingRoute)
    }
  }
  private let analytics: () -> KSRAnalytics
  private let currencyContext: @MainActor () -> PledgeCurrencyContext
  private let hasEligibleApplePayCard: @MainActor (Project) -> Bool
  private let responseDelay: () -> TimeInterval

  public init(
    pledgeFeature: PledgeFeature,
    analytics: @escaping () -> KSRAnalytics,
    currencyContext: @escaping @MainActor () -> PledgeCurrencyContext,
    hasEligibleApplePayCard: @escaping @MainActor (Project) -> Bool,
    responseDelay: @escaping () -> TimeInterval,
    schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, action in
      Task { @MainActor in
        if delay.isInfinite { return }
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        guard !Task.isCancelled else { return }
        action()
      }
    }
  ) {
    self.pledgeFeature = pledgeFeature
    self.analytics = analytics
    self.currencyContext = currencyContext
    self.hasEligibleApplePayCard = hasEligibleApplePayCard
    self.responseDelay = responseDelay
    self.schedule = schedule
  }

  private var displayedPledge: ManagedPledgeDetails? {
    guard self.presentsCurrentSession, let project = self.loadedProject, let backing = self.loadedBacking
    else { return nil }
    return self.pledgeFeature.managedPledgeDetails(project: project, backing: backing)
  }

  private func presentCombined(paymentMethodAlreadyPresented: Bool) {
    guard let details = self.displayedPledge else { return }
    let project = details.project
    let backing = details.pledge.backing
    let rewards = details.pledge.rewards
    let isCreator = details.viewerIsCreator
    self.onLoadProjectAndRewards?(project, rewards)
    self.setRightBarHidden(false)
    self.onTitle?(navigationBarTitle(with: project, userIsCreatorOfProject: isCreator))
    if paymentMethodAlreadyPresented { self.updatePaymentMethodVisibility() }
    self.onPledgeDetailsLabel?(isCreator ? Strings.Pledge_details() : Strings.Your_pledge_details())

    let latestDelivery = rewards.compactMap(\.estimatedDeliveryOn).reduce(0, max)
    let shipping = backing.locationId.flatMap { locationID in
      estimatedShippingText(for: rewards, project: project, locationId: locationID,
                            currency: self.currencyContext(),
                            selectedQuantities: selectedRewardQuantities(in: backing))
    }.map { Strings.About_reward_amount(reward_amount: $0) }
    let received = ManageViewPledgeRewardReceivedViewData(
      project: project, backerCompleted: backing.backerCompleted ?? false,
      estimatedDeliveryOn: latestDelivery, backingState: backing.status, estimatedShipping: shipping,
      pledgeDisclaimerViewHidden: rewards.allSatisfy { $0.estimatedDeliveryOn == nil } || isCreator
    )
    if let summary = managePledgeSummaryViewData(
      with: (project, backing.reward ?? .noReward), backing: backing,
      rewardReceivedWithData: received,
      rewardReceivedViewControllerViewIsHidden: latestDelivery == 0,
      viewerIsCreator: isCreator
    ) { self.onPledgeSummary?(summary) }
    if let reward = backing.reward {
      let checkout = checkoutProperties(
        from: project, baseReward: reward, addOnRewards: rewards,
        selectedQuantities: selectedRewardQuantities(in: backing), additionalPledgeAmount: backing.bonusAmount,
        pledgeTotal: backing.amount, shippingTotal: Double(backing.shippingAmount ?? 0),
        isApplePay: backing.paymentSource?.paymentType == .applePay,
        hasEligibleApplePayCard: self.hasEligibleApplePayCard(project)
      )
      self.analytics().trackManagePledgePageViewed(
        project: project, reward: reward, checkoutData: checkout
      )
    }
  }

  private func presentBacking(_ backing: Backing, replacingBacking: Bool) {
    if !backing.cancelable { self.hasSeenDisallowedCancellation = true }
    if replacingBacking { self.onFinish?(nil) }
    self.onPaymentMethod?(managePledgePaymentMethodViewData(with: backing))
    self.updatePaymentMethodVisibility()
    let enabled = ManagedPledge(backing: backing).hasPaymentSchedule
    self.onPlotScheduleHidden?(!enabled)
    if enabled { self.onPlotSchedule?(backing.paymentIncrements) }
  }

  func waitForReads() async {
    await self.projectReadTask?.value
    await self.backingReadTask?.value
  }

  private func scheduleReadResult(_ action: @escaping @MainActor () -> Void) {
    self.schedule(self.responseDelay(), action)
  }

  private func scheduleRefreshEnd(session: PledgeFeature.SessionIdentity) {
    self.schedule(0.3) { [weak self] in
      guard let self, self.pledgeFeature.sessionIdentity == session else { return }
      self.onEndRefreshing?()
    }
  }

  private func loadBacking(_ backingID: Int) {
    self.backingReadTask?.cancel()
    let pledgeFeature = self.pledgeFeature
    let route = self.backingRoute
    let session = pledgeFeature.sessionIdentity
    let id = UUID()
    self.backingReadIdentity.id = id
    self.backingReadTask = Task { [weak self] in
      do {
        let backing = try await pledgeFeature.backing(route: route, id: backingID)
        try Task.checkCancellation()
        guard pledgeFeature.sessionIdentity == session else { return }
        self?.scheduleReadResult { [weak self] in
          guard let self, self.backingReadIdentity.id == id,
                pledgeFeature.sessionIdentity == session else { return }
          let replacingBacking = self.loadedBacking != nil
          self.loadedBacking = backing
          self.presentCombined(paymentMethodAlreadyPresented: false)
          self.presentBacking(backing, replacingBacking: replacingBacking)
          self.scheduleRefreshEnd(session: session)
        }
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, pledgeFeature.sessionIdentity == session else { return }
        self?.scheduleReadResult { [weak self] in
          guard let self, self.backingReadIdentity.id == id,
                pledgeFeature.sessionIdentity == session else { return }
          self.handleLoadError()
          self.scheduleRefreshEnd(session: session)
        }
      }
    }
  }

  private func loadProject(_ param: Param) {
    self.projectReadTask?.cancel()
    let pledgeFeature = self.pledgeFeature
    let route = self.projectRoute
    let session = pledgeFeature.sessionIdentity
    let id = UUID()
    self.projectReadIdentity.id = id
    self.projectReadTask = Task { [weak self] in
      do {
        let project = try await pledgeFeature.project(route: route, param: param)
        try Task.checkCancellation()
        guard pledgeFeature.sessionIdentity == session else { return }
        self?.scheduleReadResult { [weak self] in
          guard let self, self.projectReadIdentity.id == id,
                pledgeFeature.sessionIdentity == session else { return }
          self.loadedProject = project
          if self.configuredParams?.backingParam == nil, let backingID = project.personalization.backing?.id {
            self.loadBacking(backingID)
          }
          self.presentCombined(paymentMethodAlreadyPresented: true)
        }
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, pledgeFeature.sessionIdentity == session else { return }
        self?.scheduleReadResult { [weak self] in
          guard let self, self.projectReadIdentity.id == id,
                pledgeFeature.sessionIdentity == session else { return }
          self.onEndRefreshing?()
          self.handleLoadError()
        }
      }
    }
  }

  private var presentsCurrentSession: Bool { self.loadedSession == self.pledgeFeature.sessionIdentity }

  private func prepareSession() {
    guard !self.presentsCurrentSession else { return }
    self.resetLoadedPledge()
  }

  private func resetLoadedPledge() {
    self.loadedSession = self.pledgeFeature.sessionIdentity
    self.projectReadTask?.cancel()
    self.projectReadIdentity.id = nil
    self.backingReadTask?.cancel()
    self.backingReadIdentity.id = nil
    self.loadedProject = nil
    self.loadedBacking = nil
    self.hasSeenDisallowedCancellation = false
    self.setRightBarHidden(true)
  }

  public func beginRefresh() {
    self.prepareSession()
    self.onStartRefreshing?()
    self.fetchProjectIfNeeded()
    if let backingParam = self.configuredParams?.backingParam {
      if let id = backingParam.id { self.loadBacking(id) }
    } else if let id = self.loadedProject?.personalization.backing?.id {
      self.loadBacking(id)
    }
  }

  public func configureWith(_ params: ManagePledgeViewParamConfigData) {
    let previous = self.configuredParams
    self.configuredParams = params
    if self.hasLoadedView, let previous,
       previous.projectParam != params.projectParam || previous.backingParam != params.backingParam {
      self.resetLoadedPledge()
    }
    self.publishParamsWhenReady()
  }

  private func publishParamsWhenReady() {
    guard self.hasLoadedView, let params = self.configuredParams else { return }
    self.prepareSession()
    if let id = params.backingParam?.id { self.loadBacking(id) }
    self.setRightBarHidden(true)
    self.onStartRefreshing?()
    self.fetchProjectIfNeeded()
  }

  private func handleLoadError() {
    if self.loadedBacking == nil {
      self.onLoadRefreshHeader?()
      self.setRightBarHidden(true)
    }
    self.onShowError?(Strings.Something_went_wrong_please_try_again())
  }

  private func updatePaymentMethodVisibility() {
    guard let details = self.displayedPledge else { return }
    let hidden = !details.pledge.showsPaymentMethod(viewerIsCreator: details.viewerIsCreator)
    guard self.paymentMethodHidden != hidden else { return }
    self.paymentMethodHidden = hidden
    self.onPaymentMethodHidden?(hidden)
  }

  private func setRightBarHidden(_ hidden: Bool) {
    guard self.rightBarHidden != hidden else { return }
    self.rightBarHidden = hidden
    self.onRightBarButtonHidden?(hidden)
  }

  private func fetchProjectIfNeeded() {
    guard self.hasLoadedView, self.loadedProject == nil, let params = self.configuredParams else { return }
    self.loadProject(params.projectParam)
  }

  public func cancelPledgeDidFinish(with message: String) {
    self.onFinish?(message)
  }

  public func fixButtonTapped() {
    guard let details = self.displayedPledge else { return }
    self.onFixPaymentMethod?(details.paymentSelection(context: .fixPaymentMethod))
  }

  public func menuButtonTapped() {
    guard let details = self.displayedPledge else { return }
    self.onShowMenu?(details.pledge.availableActions(for: details.project, viewerIsCreator: details.viewerIsCreator))
  }

  public func menuOptionSelected(with action: ManagePledgeAlertAction) {
    guard let details = self.displayedPledge else { return }
    let project = details.project
    switch action {
    case .chooseAnotherReward, .viewRewards:
      self.onRewards?(project)
    case .editPledgeOverTimePledge:
      self.onEditPledgeOverTime?(project)
    case .contactCreator:
      self.onContactCreator?(.project(id: project.id, name: project.name), .backerModal)
    case .changePaymentMethod:
      self.onChangePaymentMethod?(details.paymentSelection(context: .changePaymentMethod))
    case .cancelPledge:
      let backing = details.pledge.backing
      if backing.cancelable {
        self.onCancelPledge?(cancelPledgeViewData(with: project, backing: backing))
      }
      if self.hasSeenDisallowedCancellation {
        self.onShowError?(Strings.We_dont_allow_cancelations_that_will_cause_a_project_to_fall_short_of_its_goal_within_the_last_24_hours())
      }
    }
  }

  public func termsOfUseTapped(with helpType: HelpType) {
    self.onShowHelp?(helpType)
  }

  public func pledgeViewControllerDidUpdatePledgeWithMessage(_ message: String) {
    self.beginRefresh()
    self.onShowSuccess?(message)
  }

  public func viewDidLoad() {
    self.hasLoadedView = true
    self.publishParamsWhenReady()
  }

  public var onPaymentMethod: ((ManagePledgePaymentMethodViewData) -> Void)?
  public var onPledgeSummary: ((ManagePledgeSummaryViewData) -> Void)?
  public var onPlotSchedule: (([PledgePaymentIncrement]) -> Void)?
  public var onEndRefreshing: (() -> Void)?
  public var onCancelPledge: ((CancelPledgeViewData) -> Void)?
  public var onChangePaymentMethod: ((PledgeViewData) -> Void)?
  public var onContactCreator: ((MessageSubject, KSRAnalytics.MessageDialogContext) -> Void)?
  public var onFixPaymentMethod: ((PledgeViewData) -> Void)?
  public var onRewards: ((Project) -> Void)?
  public var onEditPledgeOverTime: ((Project) -> Void)?
  public var onLoadProjectAndRewards: ((Project, [Reward]) -> Void)?
  public var onLoadRefreshHeader: (() -> Void)?
  public var onPaymentMethodHidden: ((Bool) -> Void)?
  public var onPledgeDetailsLabel: ((String) -> Void)?
  public var onPlotScheduleHidden: ((Bool) -> Void)?
  public var onFinish: ((String?) -> Void)?
  public var onRightBarButtonHidden: ((Bool) -> Void)?
  public var onShowMenu: (([ManagePledgeAlertAction]) -> Void)?
  public var onShowSuccess: ((String) -> Void)?
  public var onShowError: ((String) -> Void)?
  public var onShowHelp: ((HelpType) -> Void)?
  public var onStartRefreshing: (() -> Void)?
  public var onTitle: ((String) -> Void)?

  public var inputs: ManagePledgeViewModelInputs { return self }
  public var outputs: ManagePledgeViewModelOutputs { return self }
}

// MARK: - Functions

private func navigationBarTitle(
  with project: Project,
  userIsCreatorOfProject: Bool
) -> String {
  if userIsCreatorOfProject {
    return Strings.Pledge_details()
  }

  return project.state == .live ? Strings.Manage_your_pledge() : Strings.Your_pledge()
}

private func cancelPledgeViewData(
  with project: Project,
  backing: Backing
) -> CancelPledgeViewData {
  return .init(
    project: project,
    projectName: project.name,
    omitUSCurrencyCode: project.stats.omitUSCurrencyCode,
    backingId: backing.graphID,
    pledgeAmount: backing.amount
  )
}

private func managePledgePaymentMethodViewData(
  with backing: Backing
) -> ManagePledgePaymentMethodViewData {
  ManagePledgePaymentMethodViewData(
    showFixPaymentButton: ManagedPledge(backing: backing).needsStandalonePaymentRepair,
    expirationDate: backing.paymentSource?.expirationDate,
    lastFour: backing.paymentSource?.lastFour,
    creditCardType: backing.paymentSource?.type,
    paymentType: backing.paymentSource?.paymentType
  )
}

@MainActor
private func managePledgeSummaryViewData(
  with projectAndReward: (Project, Reward),
  backing: Backing,
  rewardReceivedWithData: ManageViewPledgeRewardReceivedViewData,
  rewardReceivedViewControllerViewIsHidden: Bool,
  viewerIsCreator: Bool
) -> ManagePledgeSummaryViewData? {
  let (project, backedReward) = projectAndReward

  guard let backer = backing.backer,
        let deadline = project.dates.deadline else { return nil }

  let isRewardLocalPickup = isRewardLocalPickup(backing.reward)

  return ManagePledgeSummaryViewData(
    backerId: backer.id,
    backerName: backer.name,
    backerSequence: backing.sequence,
    backingState: backing.status,
    bonusAmount: backing.bonusAmount,
    currentUserIsCreatorOfProject: viewerIsCreator,
    isNoReward: backedReward.id == Reward.noReward.id,
    locationName: backing.locationName,
    needsConversion: project.stats.needsConversion,
    omitUSCurrencyCode: project.stats.omitUSCurrencyCode,
    pledgeAmount: backing.amount,
    pledgedOn: backing.pledgedAt,
    currencyCode: project.statsCurrency,
    projectDeadline: deadline,
    projectState: project.state,
    rewardMinimum: ManagedPledge(backing: backing).rewardMinimum,
    rewardReceivedViewControllerViewIsHidden: rewardReceivedViewControllerViewIsHidden,
    rewardReceivedWithData: rewardReceivedWithData,
    shippingAmount: backing.shippingAmount.flatMap(Double.init),
    shippingAmountHidden: backing.reward?.shipping.enabled == false || backing.shippingAmount == 0,
    rewardIsLocalPickup: isRewardLocalPickup,
    paymentIncrements: backing.paymentIncrements,
    project: project
  )
}
