import KsApi
import PassKit
import Prelude
import StripePaymentSheet
import UIKit

public enum PaymentMethodsTableViewSection: Int {
  case paymentMethods
  case addNewCard
  case loading
}

public typealias PledgePaymentMethodsValue = (
  user: User,
  project: Project,
  checkoutId: String, /// Used for creating Payment Intents in the Late Pledge flow.
  reward: Reward,
  context: PledgeViewContext,
  refTag: RefTag?
)

public typealias PaymentSheetSetupData = (
  clientSecret: String,
  configuration: PaymentSheet.Configuration
)

public struct PledgePaymentMethodsAndSelectionData {
  public var existingPaymentMethods: [PledgePaymentMethodCellData]
  public var newPaymentMethods: [PledgePaymentMethodCellData]
  public var selectedPaymentMethod: PaymentSourceSelected?
  public var isLoading: Bool
  public var shouldReload: Bool
}

@MainActor
final class PledgePaymentMethodsViewModel {
  enum Event {
    case goToAddCardViaStripeScreen(PaymentSheetSetupData)
    case notifyDelegateCreditCardSelected(PaymentSourceSelected)
    case notifyDelegateLoadPaymentMethodsError(String)
    case reloadPaymentMethods(PledgePaymentMethodsAndSelectionData)
    case updateAddNewCardLoading(Bool)
  }
  var onEvent: ((Event) -> Void)?
  private let paymentsFeature: PaymentsFeature
  private let responseDelay: @MainActor () -> TimeInterval
  private let advertisingContext: @MainActor () -> (id: String, platformVersion: String)?
  private var configuredSession: PaymentsFeature.SessionIdentity?
  private let sleep: @MainActor (TimeInterval) async throws -> Void
  private var configuration: PledgePaymentMethodsValue?
  private var loaded = false
  private var cardsTask: Task<Void, Never>?
  private var setupTask: Task<Void, Never>?
  private var storeTask: Task<Void, Never>?
  private var shouldCancel = true
  private var cancellationKnown = false
  private var cardSelection = CheckoutCardSelection()
  private var lastSelection: PaymentSourceSelected?

  init(
    paymentsFeature: PaymentsFeature,
    responseDelay: @escaping @MainActor () -> TimeInterval,
    advertisingContext: @escaping @MainActor () -> (id: String, platformVersion: String)?,
    sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { seconds in
      if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
    }
  ) {
    self.paymentsFeature = paymentsFeature
    self.responseDelay = responseDelay
    self.advertisingContext = advertisingContext
    self.sleep = sleep
  }

  deinit { self.cardsTask?.cancel(); self.setupTask?.cancel(); self.storeTask?.cancel() }

  var sessionIdentity: PaymentsFeature.SessionIdentity? {
    guard let configuredSession, self.paymentsFeature.sessionIdentity == configuredSession else { return nil }
    return configuredSession
  }

  private func isCurrent(_ identity: PaymentsFeature.SessionIdentity) -> Bool {
    self.sessionIdentity == identity
  }

  func configure(with value: PledgePaymentMethodsValue) {
    let session = self.paymentsFeature.sessionIdentity
    if let previous = self.configuredSession, previous != session {
      self.setupTask?.cancel()
      self.storeTask?.cancel()
      self.shouldCancel = true
      self.cardSelection = CheckoutCardSelection()
      self.lastSelection = nil
    }
    self.configuredSession = session
    self.configuration = value
    if self.loaded { self.loadCards() }
    if self.loaded, self.cancellationKnown { self.onEvent?(.updateAddNewCardLoading(!self.shouldCancel)) }
  }
  func viewDidLoad() {
    self.loaded = true
    if self.configuration != nil {
      self.loadCards()
      if self.cancellationKnown { self.onEvent?(.updateAddNewCardLoading(!self.shouldCancel)) }
    }
  }
  private func loadCards() {
    guard let config = self.configuration, let identity = self.sessionIdentity else { return }
    self.cardsTask?.cancel()
    self.cardSelection.beginLoading()
    self.publish(.init(), isLoading: true)
    let feature = self.paymentsFeature
    let sleep = self.sleep
    self.cardsTask = Task { [weak self] in
      guard self?.isCurrent(identity) == true else { return }
      do {
        let result = try await feature.cards()
        try await sleep(1)
        try Task.checkCancellation()
        guard let self, self.isCurrent(identity),
              let cards = self.cardSelection.load(result.me.storedCards.storedCards, for: config.project)
        else { return }
        self.publish(cards)
      } catch {
        guard !Task.isCancelled, !(error is CancellationError), let self, self.isCurrent(identity) else { return }
        self.publishError(error)
      }
    }
  }
  func paymentSheetDidAdd(clientSecret: String, paymentMethod: String?) {
    guard let identity = self.sessionIdentity else { return }
    self.storeTask?.cancel()
    let feature = self.paymentsFeature
    let delay = self.responseDelay()
    let sleep = self.sleep
    self.storeTask = Task { [weak self] in
      guard self?.isCurrent(identity) == true else { return }
      do {
        let envelope = try await feature.store(secret: clientSecret)
        try await sleep(delay)
        try Task.checkCancellation()
        guard let self, self.isCurrent(identity), envelope.createPaymentSource.isSuccessful,
              let config = self.configuration else { return }
        if let cards = self.cardSelection.add(
          envelope.createPaymentSource.paymentSource, stripePaymentMethodID: paymentMethod, for: config.project
        ) {
          self.publish(cards)
        }
      } catch {
        do { try await sleep(delay) } catch { return }
        guard !Task.isCancelled, !(error is CancellationError), let self, self.isCurrent(identity) else { return }
        self.publishError(error)
      }
    }
  }
  func shouldCancelPaymentSheetAppearance(state: Bool) {
    self.shouldCancel = state
    self.cancellationKnown = true
    if self.configuration != nil, self.loaded { self.onEvent?(.updateAddNewCardLoading(!state)) }
  }
  func willSelectRowAtIndexPath(_ indexPath: IndexPath) -> IndexPath? {
    guard self.sessionIdentity != nil, self.cardSelection.snapshot != nil, indexPath.row >= 0 else { return nil }
    if indexPath.section == PaymentMethodsTableViewSection.addNewCard.rawValue { return indexPath }
    guard indexPath.section == PaymentMethodsTableViewSection.paymentMethods.rawValue else { return nil }
    return self.cardSelection.canSelect(row: indexPath.row) ? indexPath : nil
  }

  func didSelectRowAtIndexPath(_ indexPath: IndexPath) {
    guard self.sessionIdentity != nil else { return }
    if indexPath.section == PaymentMethodsTableViewSection.addNewCard.rawValue {
      self.startSetup()
      return
    }
    guard indexPath.section == PaymentMethodsTableViewSection.paymentMethods.rawValue,
          let cards = self.cardSelection.select(row: indexPath.row) else { return }
    self.shouldCancelPaymentSheetAppearance(state: true)
    self.publish(cards)
  }

  private func startSetup() {
    guard self.loaded, let config = self.configuration, let identity = self.sessionIdentity else { return }
    self.shouldCancelPaymentSheetAppearance(state: false)
    self.setupTask?.cancel()
    let feature = self.paymentsFeature
    let delay = self.responseDelay()
    let sleep = self.sleep
    self.setupTask = Task { [weak self] in
      guard self?.isCurrent(identity) == true else { return }
      do {
        let envelope = try await feature.setupForPledge(projectID: config.project.graphID, context: config.context)
        try await sleep(1 + delay)
        try Task.checkCancellation()
        guard let self, self.isCurrent(identity), !self.shouldCancel else { return }
        var configuration = PaymentSheet.Configuration()
        configuration.merchantDisplayName = Strings.general_accessibility_kickstarter()
        configuration.allowsDelayedPaymentMethods = true
        configuration.defaultBillingDetails.email = feature.billingEmail(for: identity)
        self.onEvent?(.goToAddCardViaStripeScreen((envelope.clientSecret, configuration)))
      } catch {
        do { try await sleep(delay) } catch { return }
        guard !Task.isCancelled, !(error is CancellationError), let self, self.isCurrent(identity) else { return }
        self.publishError(error)
        self.onEvent?(.updateAddNewCardLoading(false))
      }
    }
  }
  private func publish(_ cards: CheckoutCardSelection.Snapshot, isLoading: Bool = false) {
    self.onEvent?(.reloadPaymentMethods(.init(
      existingPaymentMethods: cards.existing, newPaymentMethods: cards.added, selectedPaymentMethod: cards.selected,
      isLoading: isLoading, shouldReload: true
    )))
    if let selected = cards.selected, self.lastSelection != selected {
      self.lastSelection = selected
      self.onEvent?(.notifyDelegateCreditCardSelected(selected))
    }
  }
  private func publishError(_ error: Error) {
    self.onEvent?(.notifyDelegateLoadPaymentMethodsError(((error as? ErrorEnvelope) ?? .couldNotParseJSON).localizedDescription))
  }
  func stripePaymentSheetDidAppear() {
    guard self.loaded, let config = self.configuration, let identity = self.sessionIdentity,
          let advertising = self.advertisingContext() else { return }
    self.paymentsFeature.recordCheckoutAddCardAppearance(
      projectID: config.project.id, advertisingID: advertising.id,
      platformVersion: advertising.platformVersion, session: identity
    )
  }

  func waitForPending() async {
    await self.cardsTask?.value
    await self.setupTask?.value
    await self.storeTask?.value
  }
}
