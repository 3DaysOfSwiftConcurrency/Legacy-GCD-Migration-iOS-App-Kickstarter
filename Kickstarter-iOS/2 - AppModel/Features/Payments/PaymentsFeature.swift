import Foundation
import GraphAPI
import KsApi
import PassKit

@MainActor
public protocol PaymentsProvider {
  func fetchSavedCards() async throws -> UserEnvelope<GraphUser>
  func removePaymentMethod(id: String) async throws -> DeletePaymentMethodEnvelope
  func createPaymentSource(secret: String) async throws -> CreatePaymentSourceEnvelope
  func createSetupIntent(input: KsApi.CreateSetupIntentInput) async throws -> ClientSecretEnvelope
  func createPaymentIntent(input: KsApi.CreatePaymentIntentInput) async throws -> PaymentIntentEnvelope
}

@MainActor
public struct AsyncPaymentsProvider: PaymentsProvider {
  private let service: any ServiceType
  public init(service: any ServiceType) { self.service = service }
  public func fetchSavedCards() async throws -> UserEnvelope<GraphUser> { try await self.service.paymentCards() }
  public func removePaymentMethod(id: String) async throws -> DeletePaymentMethodEnvelope {
    try await self.service.removePaymentMethod(id: id)
  }
  public func createPaymentSource(secret: String) async throws -> CreatePaymentSourceEnvelope {
    try await self.service.storePaymentMethod(secret: secret)
  }
  public func createSetupIntent(input: KsApi.CreateSetupIntentInput) async throws -> ClientSecretEnvelope {
    try await self.service.paymentSetupIntent(input: input)
  }
  public func createPaymentIntent(input: KsApi.CreatePaymentIntentInput) async throws -> PaymentIntentEnvelope {
    try await self.service.paymentIntent(input: input)
  }
}

/// Owns stored-card operations and intent creation. An admitted mutation outlives
/// its screen observer; cancellation cannot undo a server-accepted write.
/// There is no automatic retry or claim of server-side idempotency.
@MainActor
public final class PaymentsFeature {
  private let sessionFeature: SessionFeature
  private let makeProvider: () -> any PaymentsProvider
  private let trackThirdPartyEvent: @MainActor (KsApi.TriggerThirdPartyEventInput) -> Void
  private let supportedApplePayNetworks: @MainActor (Project) -> [PKPaymentNetwork]
  private let stripeKey: @MainActor () -> String
  private let pledgeCurrencyContext: @MainActor () -> PledgeCurrencyContext?
  private let launchedCountryPolicy: @MainActor () -> LaunchedCountries
  private let applePayEligibility: @MainActor (Project) -> Bool
  private let responseDelay: @MainActor () -> TimeInterval

  public init(
    sessionFeature: SessionFeature,
    makeProvider: @escaping () -> any PaymentsProvider,
    trackThirdPartyEvent: @escaping @MainActor (KsApi.TriggerThirdPartyEventInput) -> Void = { _ in },
    supportedApplePayNetworks: @escaping @MainActor (Project) -> [PKPaymentNetwork] = { _ in [] },
    stripePublishableKey: @escaping @MainActor () -> String = { "" },
    currencyContext: @escaping @MainActor () -> PledgeCurrencyContext? = { nil },
    launchedCountries: @escaping @MainActor () -> LaunchedCountries = { LaunchedCountries() },
    hasEligibleApplePayCard: @escaping @MainActor (Project) -> Bool = { _ in false },
    responseDelaySeconds: @escaping @MainActor () -> TimeInterval = { 0 }
  ) {
    self.sessionFeature = sessionFeature
    self.makeProvider = makeProvider
    self.trackThirdPartyEvent = trackThirdPartyEvent
    self.supportedApplePayNetworks = supportedApplePayNetworks
    self.stripeKey = stripePublishableKey
    self.pledgeCurrencyContext = currencyContext
    self.launchedCountryPolicy = launchedCountries
    self.applePayEligibility = hasEligibleApplePayCard
    self.responseDelay = responseDelaySeconds
  }

  public var stripePublishableKey: String { self.stripeKey() }
  public var currencyContext: PledgeCurrencyContext? { self.pledgeCurrencyContext() }
  public var responseDelaySeconds: TimeInterval { self.responseDelay() }

  public func makeSessionValidityCheck() -> @MainActor () -> Bool {
    let session = self.sessionIdentity
    return { [weak self] in self?.sessionIdentity == session }
  }

  public func hasEligibleApplePayCard(for project: Project) -> Bool {
    self.applePayEligibility(project)
  }

  public func paymentRequest(
    for project: Project,
    reward: Reward,
    allRewardsTotal: Double,
    additionalPledgeAmount: Double,
    allRewardsShippingTotal: Double,
    merchantIdentifier: String
  ) -> PKPaymentRequest {
    PKPaymentRequest.paymentRequest(
      for: project,
      reward: reward,
      allRewardsTotal: allRewardsTotal,
      additionalPledgeAmount: additionalPledgeAmount,
      allRewardsShippingTotal: allRewardsShippingTotal,
      merchantIdentifier: merchantIdentifier,
      supportedNetworks: self.supportedApplePayNetworks(project),
      launchedCountries: self.launchedCountryPolicy()
    )
  }

  public func paymentRequest(for data: PostCampaignPaymentAuthorizationData) -> PKPaymentRequest {
    PKPaymentRequest.paymentRequest(
      for: data,
      supportedNetworks: self.supportedApplePayNetworks(data.project),
      launchedCountries: self.launchedCountryPolicy()
    )
  }

  func billingEmail(for session: SessionIdentity) -> String? {
    guard self.sessionIdentity == session else { return nil }
    return self.sessionFeature.currentUserEmail
  }

  func recordCheckoutAddCardAppearance(
    projectID: Int, advertisingID: String, platformVersion: String, session: SessionIdentity
  ) {
    guard self.sessionIdentity == session else { return }
    var platformInfo = Array(repeating: "", count: 16)
    platformInfo[0] = "i2"
    platformInfo[4] = platformVersion
    self.trackThirdPartyEvent(.init(
      deviceId: advertisingID, eventName: ThirdPartyEventInputName.AddNewPaymentMethod.rawValue,
      projectId: String(projectID), pledgeAmount: nil, shipping: nil, transactionId: nil,
      userId: session.userID.map(String.init) ?? "",
      appData: .init(advertiserTrackingEnabled: true, applicationTrackingEnabled: true, extinfo: platformInfo),
      clientMutationId: ""
    ))
  }

  func createCardSetupIntentForPaymentSettings() async throws -> ClientSecretEnvelope {
    try await self.createSetupIntent(projectID: nil, context: .profileSettings)
  }

  func createCardSetupIntentForPledge(projectID: String, context: PledgeViewContext) async throws -> ClientSecretEnvelope {
    try await self.createSetupIntent(
      projectID: projectID, context: context == .latePledge ? .postCampaignCheckout : .crowdfundingCheckout
    )
  }

  func makePaymentMethodsSelection() -> PaymentMethodsUseCase {
    PaymentMethodsUseCase(currentUser: { [sessionFeature] in sessionFeature.currentUser })
  }

  struct SessionIdentity: Hashable, Sendable {
    let userID: Int?
    let generation: Int
  }
  var sessionIdentity: SessionIdentity {
    SessionIdentity(userID: self.sessionFeature.currentUser?.id, generation: self.sessionFeature.generation)
  }
  private func requireCurrent(_ session: SessionIdentity) throws {
    try Task.checkCancellation()
    guard self.sessionIdentity == session else { throw CancellationError() }
  }

  private enum Command: Hashable {
    case remove(String)
    case store(String)
    case setup(String?, String)
    case intent(String, String, String, String)
    var changesCards: Bool {
      switch self { case .remove, .store: return true; default: return false }
    }
  }
  private enum Value: Sendable {
    case removed(DeletePaymentMethodEnvelope)
    case stored(CreatePaymentSourceEnvelope)
    case setup(ClientSecretEnvelope)
    case intent(PaymentIntentEnvelope)
  }
  private struct Identity: Hashable { let session: SessionIdentity; let command: Command }
  private struct Pending { let id: UUID; let task: Task<Value, Error> }
  private var pending: [Identity: Pending] = [:]
  private var commands: [UUID: Task<Value, Error>] = [:]
  private var latestCardWriteBySession: [SessionIdentity: Pending] = [:]
  private var cardWriteRevision = 0

  private struct CardReadResult: Sendable {
    let revision: Int
    let cards: Result<UserEnvelope<GraphUser>, Error>
  }

  private struct CardRead {
    let id: UUID
    let task: Task<Void, Never>
    var waiters: [UUID: CheckedContinuation<CardReadResult, Error>]
  }

  private var cardReads: [SessionIdentity: CardRead] = [:]


  private func startPaymentCommand(_ command: Command, operation: @escaping @MainActor (any PaymentsProvider) async throws -> Value)
    -> Task<Value, Error> {
    let identity = Identity(session: self.sessionIdentity, command: command)
    let previous = command.changesCards ? self.latestCardWriteBySession[identity.session] : nil
    if let existing = self.pending[identity],
       !command.changesCards || previous?.id == existing.id { return existing.task }
    let id = UUID()
    let provider = self.makeProvider()
    if command.changesCards { self.cardWriteRevision += 1 }
    let task = Task { [self] in
      defer {
        self.commands[id] = nil
        if self.pending[identity]?.id == id { self.pending[identity] = nil }
        if self.latestCardWriteBySession[identity.session]?.id == id { self.latestCardWriteBySession[identity.session] = nil }
      }
      if let previous { _ = await previous.task.result }
      try self.requireCurrent(identity.session)
      do {
        let value = try await operation(provider)
        try self.requireCurrent(identity.session)
        return value
      } catch {
        try self.requireCurrent(identity.session)
        throw error
      }
    }
    let entry = Pending(id: id, task: task)
    self.pending[identity] = entry
    self.commands[id] = task
    if command.changesCards { self.latestCardWriteBySession[identity.session] = entry }
    return task
  }

  /// Equivalent reads within one session share a fetch and any reload required by a
  /// card write. A canceled waiter leaves the fetch alive while anyone still needs it.
  public func fetchSavedCards() async throws -> UserEnvelope<GraphUser> {
    let session = self.sessionIdentity
    while true {
      let result = try await self.waitForCardRead(in: session)
      try self.requireCurrent(session)
      if result.revision == self.cardWriteRevision { return try result.cards.get() }
    }
  }

  private func waitForCardRead(in session: SessionIdentity) async throws -> CardReadResult {
    try self.requireCurrent(session)
    let waiter = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        if self.cardReads[session] != nil {
          self.cardReads[session]?.waiters[waiter] = continuation
          return
        }
        let readID = UUID()
        let task = Task { [self] in
          let result: Result<CardReadResult, Error>
          do { result = .success(try await self.readCardsAfterWrites(in: session)) }
          catch { result = .failure(error) }
          guard self.cardReads[session]?.id == readID,
                let finished = self.cardReads.removeValue(forKey: session) else { return }
          for waiter in finished.waiters.values { waiter.resume(with: result) }
        }
        self.cardReads[session] = CardRead(id: readID, task: task, waiters: [waiter: continuation])
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard let self, let continuation = self.cardReads[session]?.waiters.removeValue(forKey: waiter)
        else { return }
        if self.cardReads[session]?.waiters.isEmpty == true {
          self.cardReads.removeValue(forKey: session)?.task.cancel()
        }
        continuation.resume(throwing: CancellationError())
      }
    }
  }

  private func readCardsAfterWrites(in session: SessionIdentity) async throws -> CardReadResult {
    while true {
      try self.requireCurrent(session)
      if let previous = self.latestCardWriteBySession[session] {
        _ = await previous.task.result
        continue
      }
      let revision = self.cardWriteRevision
      let result: Result<UserEnvelope<GraphUser>, Error>
      do { result = .success(try await self.makeProvider().fetchSavedCards()) }
      catch { result = .failure(error) }
      try self.requireCurrent(session)
      if revision == self.cardWriteRevision { return CardReadResult(revision: revision, cards: result) }
    }
  }

  func sessionChanged() {
    let current = self.sessionIdentity
    for session in Array(self.cardReads.keys) where session != current {
      guard let read = self.cardReads.removeValue(forKey: session) else { continue }
      read.task.cancel()
      for waiter in read.waiters.values { waiter.resume(throwing: CancellationError()) }
    }
  }

  public func removePaymentMethod(id: String) async throws -> DeletePaymentMethodEnvelope {
    try Task.checkCancellation()
    let session = self.sessionIdentity
    let value = try await self.startPaymentCommand(.remove(id)) { .removed(try await $0.removePaymentMethod(id: id)) }.value
    try self.requireCurrent(session)
    guard case let .removed(envelope) = value else { preconditionFailure("Payment command type mismatch") }
    return envelope
  }
  public func createPaymentSource(secret: String) async throws -> CreatePaymentSourceEnvelope {
    try Task.checkCancellation()
    let session = self.sessionIdentity
    let value = try await self.startPaymentCommand(.store(secret)) { .stored(try await $0.createPaymentSource(secret: secret)) }.value
    try self.requireCurrent(session)
    guard case let .stored(envelope) = value else { preconditionFailure("Payment command type mismatch") }
    return envelope
  }
  public func createSetupIntent(projectID: String?, context: GraphAPI.StripeIntentContextTypes) async throws -> ClientSecretEnvelope {
    try Task.checkCancellation()
    let session = self.sessionIdentity
    let value = try await self.startPaymentCommand(.setup(projectID, context.rawValue)) {
      .setup(try await $0.createSetupIntent(input: KsApi.CreateSetupIntentInput(projectId: projectID, context: context)))
    }.value
    try self.requireCurrent(session)
    guard case let .setup(envelope) = value else { preconditionFailure("Payment command type mismatch") }
    return envelope
  }
  public func createPaymentIntent(projectID: String, backingID: String, checkoutID: String, total: Double) async throws -> PaymentIntentEnvelope {
    try Task.checkCancellation()
    let task = self.startPaymentIntentCreation(projectID: projectID, backingID: backingID, checkoutID: checkoutID, total: total)
    let value = try await task.value
    try Task.checkCancellation()
    return value
  }

  /// Admit the intent immediately; cancellation of a screen's waiter does not cancel the write.
  public func startPaymentIntentCreation(projectID: String, backingID: String, checkoutID: String, total: Double) -> Task<PaymentIntentEnvelope, Error> {
    let session = self.sessionIdentity
    let amount = String(format: "%.2f", total)
    let request = self.startPaymentCommand(.intent(projectID, backingID, checkoutID, amount)) {
      .intent(try await $0.createPaymentIntent(input: KsApi.CreatePaymentIntentInput(
        projectId: projectID, backingId: backingID, amountDollars: amount,
        checkoutId: encodeToBase64("Checkout-\(checkoutID)"), digitalMarketingAttributed: nil
      )))
    }
    return Task { [self] in
      let value = try await request.value
      try self.requireCurrent(session)
      guard case let .intent(envelope) = value else { preconditionFailure("Payment command type mismatch") }
      return envelope
    }
  }

  public func waitForPaymentOperations() async {
    while !self.commands.isEmpty || !self.cardReads.isEmpty {
      for task in Array(self.commands.values) { _ = await task.result }
      for read in Array(self.cardReads.values) { await read.task.value }
    }
  }
}
