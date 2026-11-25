import Foundation
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
  struct CheckoutIdentity: Equatable {
    fileprivate let session: PaymentsFeature.SessionIdentity
    fileprivate let revision: UUID
  }

  enum Event {
    case goToAddCardViaStripeScreen(PaymentSheetSetupData, CheckoutIdentity)
    case notifyDelegateCreditCardSelected(PaymentSourceSelected)
    case notifyDelegateLoadPaymentMethodsError(String)
    case reloadPaymentMethods(PledgePaymentMethodsAndSelectionData)
    case updateAddNewCardLoading(Bool)
  }
  var onEvent: ((Event) -> Void)?
  private let paymentsFeature: PaymentsFeature
  private let responseDelay: @MainActor () -> TimeInterval
  private let advertisingContext: @MainActor () -> (id: String, platformVersion: String)?
  private var configuredCheckout: CheckoutIdentity?
  private let sleep: @MainActor (TimeInterval) async throws -> Void
  private var configuration: PledgePaymentMethodsValue?
  private var loaded = false
  private let presentationTasks = PaymentPresentationTasks()
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

  var currentCheckout: CheckoutIdentity? {
    guard let configuredCheckout,
          self.paymentsFeature.sessionIdentity == configuredCheckout.session else { return nil }
    return configuredCheckout
  }

  func isCurrent(_ identity: CheckoutIdentity) -> Bool {
    self.currentCheckout == identity
  }

  func configure(with value: PledgePaymentMethodsValue) {
    let session = self.paymentsFeature.sessionIdentity
    let previous = self.configuration
    if self.configuredCheckout?.session != session ||
      previous?.project.id != value.project.id ||
      previous?.project.personalization.backing?.id != value.project.personalization.backing?.id ||
      previous?.checkoutId != value.checkoutId || previous?.reward.id != value.reward.id ||
      previous?.context != value.context {
      self.configuredCheckout = CheckoutIdentity(session: session, revision: UUID())
      self.presentationTasks.cancel(.cards)
      self.presentationTasks.cancel(.setup)
      self.presentationTasks.cancel(.store)
      self.shouldCancel = true
      self.cardSelection = CheckoutCardSelection()
      self.lastSelection = nil
    }
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
    guard let config = self.configuration, let identity = self.currentCheckout else { return }
    self.cardSelection.beginLoading()
    let feature = self.paymentsFeature
    let sleep = self.sleep
    self.presentationTasks.replace(.cards) { [weak self] in
      guard self?.isCurrent(identity) == true else { return }
      do {
        let result = try await feature.fetchSavedCards()
        try await sleep(1)
        try Task.checkCancellation()
        guard let self, self.isCurrent(identity),
              let cards = self.cardSelection.loadSavedCards(result.me.storedCards.storedCards, for: config.project)
        else { return }
        self.publish(cards, checkout: identity)
      } catch {
        guard !Task.isCancelled, !(error is CancellationError), let self, self.isCurrent(identity) else { return }
        self.publishError(error)
      }
    }
    self.publish(.init(), checkout: identity, isLoading: true)
  }
  func paymentSheetDidAdd(clientSecret: String, paymentMethod: String?, checkout identity: CheckoutIdentity) {
    guard self.isCurrent(identity) else { return }
    let feature = self.paymentsFeature
    let delay = self.responseDelay()
    let sleep = self.sleep
    self.presentationTasks.replace(.store) { [weak self] in
      guard self?.isCurrent(identity) == true else { return }
      do {
        let envelope = try await feature.createPaymentSource(secret: clientSecret)
        try await sleep(delay)
        try Task.checkCancellation()
        guard let self, self.isCurrent(identity), envelope.createPaymentSource.isSuccessful,
              let config = self.configuration else { return }
        if let cards = self.cardSelection.addSavedCard(
          envelope.createPaymentSource.paymentSource, stripePaymentMethodID: paymentMethod, for: config.project
        ) {
          self.publish(cards, checkout: identity)
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
    if state { self.presentationTasks.cancel(.setup) }
    if self.configuration != nil, self.loaded { self.onEvent?(.updateAddNewCardLoading(!state)) }
  }
  func willSelectRowAtIndexPath(_ indexPath: IndexPath) -> IndexPath? {
    guard self.currentCheckout != nil, self.cardSelection.snapshot != nil, indexPath.row >= 0 else { return nil }
    if indexPath.section == PaymentMethodsTableViewSection.addNewCard.rawValue { return indexPath }
    guard indexPath.section == PaymentMethodsTableViewSection.paymentMethods.rawValue else { return nil }
    return self.cardSelection.canSelect(row: indexPath.row) ? indexPath : nil
  }

  func didSelectRowAtIndexPath(_ indexPath: IndexPath) {
    guard let identity = self.currentCheckout else { return }
    if indexPath.section == PaymentMethodsTableViewSection.addNewCard.rawValue {
      self.startSetup()
      return
    }
    guard indexPath.section == PaymentMethodsTableViewSection.paymentMethods.rawValue,
          let cards = self.cardSelection.selectCard(row: indexPath.row) else { return }
    self.shouldCancelPaymentSheetAppearance(state: true)
    self.publish(cards, checkout: identity)
  }

  private func startSetup() {
    guard self.loaded, let config = self.configuration, let identity = self.currentCheckout else { return }
    let feature = self.paymentsFeature
    let delay = self.responseDelay()
    let sleep = self.sleep
    self.presentationTasks.replace(.setup) { [weak self] in
      guard self?.isCurrent(identity) == true else { return }
      do {
        let envelope = try await feature.createCardSetupIntentForPledge(projectID: config.project.graphID, context: config.context)
        try await sleep(1 + delay)
        try Task.checkCancellation()
        guard let self, self.isCurrent(identity), !self.shouldCancel else { return }
        var configuration = PaymentSheet.Configuration()
        configuration.merchantDisplayName = Strings.general_accessibility_kickstarter()
        configuration.allowsDelayedPaymentMethods = true
        configuration.defaultBillingDetails.email = feature.billingEmail(for: identity.session)
        self.onEvent?(.goToAddCardViaStripeScreen((envelope.clientSecret, configuration), identity))
      } catch {
        do { try await sleep(delay) } catch { return }
        guard !Task.isCancelled, !(error is CancellationError), let self, self.isCurrent(identity) else { return }
        self.publishError(error)
        self.onEvent?(.updateAddNewCardLoading(false))
      }
    }
    self.shouldCancelPaymentSheetAppearance(state: false)
  }
  private func publish(
    _ cards: CheckoutCardSelection.Snapshot, checkout identity: CheckoutIdentity, isLoading: Bool = false
  ) {
    guard self.isCurrent(identity) else { return }
    self.onEvent?(.reloadPaymentMethods(.init(
      existingPaymentMethods: cards.existing, newPaymentMethods: cards.added, selectedPaymentMethod: cards.selected,
      isLoading: isLoading, shouldReload: true
    )))
    if self.isCurrent(identity), let selected = cards.selected, self.lastSelection != selected {
      self.lastSelection = selected
      self.onEvent?(.notifyDelegateCreditCardSelected(selected))
    }
  }
  private func publishError(_ error: Error) {
    self.onEvent?(.notifyDelegateLoadPaymentMethodsError(((error as? ErrorEnvelope) ?? .couldNotParseJSON).localizedDescription))
  }
  func stripePaymentSheetDidAppear(checkout identity: CheckoutIdentity) {
    guard self.loaded, self.isCurrent(identity), let config = self.configuration,
          let advertising = self.advertisingContext() else { return }
    self.paymentsFeature.recordCheckoutAddCardAppearance(
      projectID: config.project.id, advertisingID: advertising.id,
      platformVersion: advertising.platformVersion, session: identity.session
    )
  }

  func waitForPending() async { await self.presentationTasks.waitForPending() }
}
