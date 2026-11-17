@testable import Kickstarter_iOS
import Foundation
import GraphAPI
import PassKit
import Prelude
@testable import KsApi


import XCTest

@MainActor
final class PaymentsFeatureTests: TestCase {
  override var requiresSnapshotReferenceSimulator: Bool { false }
  private let provider = ControlledPaymentsProvider()
  private let session = SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) },
                                       currentUser: { .template }, updateUser: { _ in })
  private lazy var feature = PaymentsFeature(sessionFeature: self.session, makeProvider: { self.provider })

  func testStripePublishableKeyUsesComposedPolicy() {
    let feature = PaymentsFeature(
      sessionFeature: self.session,
      makeProvider: { self.provider },
      stripePublishableKey: { "pk_test_composed" }
    )

    XCTAssertEqual(feature.stripePublishableKey, "pk_test_composed")
  }

  func testApplePayRequestUsesComposedNetworkPolicy() {
    let feature = PaymentsFeature(
      sessionFeature: self.session,
      makeProvider: { self.provider },
      supportedApplePayNetworks: { _ in [.visa, .masterCard] }
    )

    let request = feature.paymentRequest(
      for: Project.template,
      reward: .noReward,
      allRewardsTotal: 0,
      additionalPledgeAmount: 25,
      allRewardsShippingTotal: 0,
      merchantIdentifier: "merchant.fixture"
    )

    XCTAssertEqual(request.supportedNetworks, [.visa, .masterCard])
  }

  override func tearDown() async throws {
    self.session.sessionChanged()
    self.provider.releaseAll()
    await self.feature.waitForOperations()
    try await super.tearDown()
  }

  func testCheckoutCardSelectionPreservesBackingPreferenceAndRejectsDisabledTaps() throws {
    let visa = UserCreditCards.visa
    let amex = UserCreditCards.amex
    let visaBrand = try XCTUnwrap(visa.type?.rawValue)
    let source = Backing.PaymentSource.template |> \.id .~ visa.id
    let backing = Backing.template |> Backing.lens.paymentSource .~ source
    let project = Project.template
      |> \.availableCardTypes .~ [visaBrand]
      |> Project.lens.personalization.backing .~ backing

    var selection = CheckoutCardSelection()
    let cards = try XCTUnwrap(selection.load([amex, visa], for: project))
    XCTAssertEqual(cards.existing.map { $0.card.id }, [visa.id, amex.id])
    XCTAssertEqual(cards.selected?.savedCreditCardId, visa.id)
    XCTAssertFalse(selection.canSelect(row: 1))
    XCTAssertNil(selection.select(row: 1))
    XCTAssertEqual(selection.snapshot?.selected?.savedCreditCardId, visa.id)

    let errored = backing |> Backing.lens.status .~ .errored
    let retryProject = project |> Project.lens.personalization.backing .~ errored
    let retryCards = try XCTUnwrap(selection.load([amex, visa], for: retryProject))
    XCTAssertNil(retryCards.selected)
    XCTAssertEqual(retryCards.existing.first?.isErroredPaymentMethod, true)
  }

  func testCheckoutCardSelectionKeepsDefaultUntilAnEligibleNewCardIsAdded() throws {
    let visa = UserCreditCards.visa
    let amex = UserCreditCards.amex
    let visaBrand = try XCTUnwrap(visa.type?.rawValue)
    let project = Project.template
      |> \.availableCardTypes .~ [visaBrand]
      |> Project.lens.personalization.backing .~ nil
    var selection = CheckoutCardSelection()
    _ = selection.load([visa], for: project)

    let unsupported = try XCTUnwrap(selection.add(amex, stripePaymentMethodID: nil, for: project))
    XCTAssertEqual(unsupported.selected?.savedCreditCardId, visa.id)
    XCTAssertEqual(unsupported.added.first?.isSelected, false)

    var added = visa
    added.stripeCardId = nil
    let supported = try XCTUnwrap(selection.add(added, stripePaymentMethodID: "method-fixture", for: project))
    XCTAssertEqual(supported.selected?.stripePaymentMethodId, "method-fixture")
    XCTAssertEqual(supported.existing.first?.isSelected, false)
    XCTAssertEqual(supported.added.map(\.isSelected), [true, false])
  }

  func testCheckoutTrackingRejectsAnObsoleteSession() {
    var events = 0
    let feature = PaymentsFeature(
      sessionFeature: self.session,
      makeProvider: { self.provider },
      trackThirdPartyEvent: { _ in events += 1 }
    )
    let original = feature.sessionIdentity
    feature.recordCheckoutAddCardAppearance(
      projectID: 17, advertisingID: "fixture", platformVersion: "test", session: original
    )
    XCTAssertEqual(events, 1)

    self.session.sessionChanged()
    feature.recordCheckoutAddCardAppearance(
      projectID: 17, advertisingID: "fixture", platformVersion: "test", session: original
    )
    XCTAssertEqual(events, 1)
  }

  func testDuplicateSetupSharesRequestAndCanceledWaiterDoesNotCancelWrite() async throws {
    let first = Task { try await self.feature.setup(projectID: nil, context: .profileSettings) }
    let second = Task { try await self.feature.setup(projectID: nil, context: .profileSettings) }
    await self.provider.setups.waitFor(1)
    await Task.yield()
    first.cancel()
    try self.provider.setups.finish(0, .success(ClientSecretEnvelope(clientSecret: "fixture")))
    do { _ = try await first.value; XCTFail("Canceled waiter must not receive a secret") }
    catch { XCTAssertTrue(error is CancellationError) }
    let secondSecret = try await second.value.clientSecret
    XCTAssertEqual(secondSecret, "fixture")
    XCTAssertEqual(self.provider.setups.count, 1)
  }

  func testDistinctSetupContextsRemainIndependent() async throws {
    let first = Task { try await self.feature.setupForPledge(projectID: "project", context: .pledge) }
    let second = Task { try await self.feature.setupForPledge(projectID: "project", context: .latePledge) }
    await self.provider.setups.waitFor(2)
    XCTAssertEqual(self.provider.setupInputs.map { $0.setupIntentContext }, [.crowdfundingCheckout, .postCampaignCheckout])
    XCTAssertEqual(self.provider.setupInputs.map { $0.projectId }, ["project", "project"])
    try self.provider.setups.finish(1, .success(ClientSecretEnvelope(clientSecret: "second")))
    try self.provider.setups.finish(0, .success(ClientSecretEnvelope(clientSecret: "first")))
    let firstSecret = try await first.value.clientSecret
    let secondSecret = try await second.value.clientSecret
    XCTAssertEqual(firstSecret, "first")
    XCTAssertEqual(secondSecret, "second")
  }

  func testIntentPreservesAmountCheckoutEncodingAndSharesPendingRequest() async throws {
    let a = Task { try await self.feature.intent(projectID: "project", backingID: "backing", checkoutID: "19", total: 12.5) }
    let b = Task { try await self.feature.intent(projectID: "project", backingID: "backing", checkoutID: "19", total: 12.5) }
    await self.provider.intents.waitFor(1)
    await Task.yield()
    let input = try XCTUnwrap(self.provider.intentInputs.first)
    XCTAssertEqual(input.projectId, "project")
    XCTAssertEqual(input.backingId, "backing")
    XCTAssertEqual(input.amountDollars, "12.50")
    XCTAssertEqual(input.checkoutId, Data("Checkout-19".utf8).base64EncodedString())
    XCTAssertEqual(input.paymentIntentContext, .postCampaignCheckout)
    XCTAssertNil(input.digitalMarketingAttributed)
    try self.provider.intents.finish(0, .success(PaymentIntentEnvelope(clientSecret: "fixture")))
    let firstSecret = try await a.value.clientSecret
    let secondSecret = try await b.value.clientSecret
    XCTAssertEqual(firstSecret, "fixture")
    XCTAssertEqual(secondSecret, "fixture")
    XCTAssertEqual(self.provider.intents.count, 1)
  }

  func testCardWritesStayOrderedAndFailureDoesNotBlockNextCommand() async throws {
    let removal = Task { try await self.feature.remove(id: "old") }
    await self.provider.removals.waitFor(1)
    let storage = Task { try await self.feature.store(secret: "fixture") }
    await Task.yield()
    XCTAssertEqual(self.provider.stores.count, 0)
    try self.provider.removals.finish(0, .failure(ErrorEnvelope.couldNotParseJSON))
    await self.provider.stores.waitFor(1)
    XCTAssertEqual(self.provider.removedIDs, ["old"])
    XCTAssertEqual(self.provider.storedSecrets, ["fixture"])
    try self.provider.stores.finish(0, .success(self.storedCard()))
    do { _ = try await removal.value; XCTFail("Removal should fail") } catch {}
    _ = try await storage.value
    XCTAssertEqual(self.provider.removals.count, 1)
  }

  func testDuplicatePendingCardTailSharesButInterveningWriteDoesNot() async throws {
    let first = Task { try await self.feature.remove(id: "card") }
    await self.provider.removals.waitFor(1)
    let duplicate = Task { try await self.feature.remove(id: "card") }
    await Task.yield()
    let store = Task { try await self.feature.store(secret: "fixture") }
    await Task.yield()
    let again = Task { try await self.feature.remove(id: "card") }
    await Task.yield()
    try self.provider.removals.finish(0, .success(DeletePaymentMethodEnvelope(storedCards: [])))
    await self.provider.stores.waitFor(1)
    try self.provider.stores.finish(0, .success(self.storedCard()))
    await self.provider.removals.waitFor(2)
    try self.provider.removals.finish(1, .success(DeletePaymentMethodEnvelope(storedCards: [])))
    _ = try await first.value
    _ = try await duplicate.value
    _ = try await store.value
    _ = try await again.value
    XCTAssertEqual(self.provider.removals.count, 2)
  }

  func testConcurrentCardWaitersShareAndCancellationLeavesTheOtherReadAlive() async throws {
    let first = try await self.startCardRead()
    await self.provider.cardReads.waitFor(1)
    let second = try await self.startCardRead()
    defer { self.provider.cardReads.releaseAll() }
    XCTAssertEqual(self.provider.cardReads.count, 1)

    first.cancel()
    let cancelled = XCTestExpectation(description: "Canceled card waiter completes before transport")
    let cancellationCheck = Task {
      if case let .failure(error) = await first.result { XCTAssertTrue(error is CancellationError) }
      else { XCTFail("Canceled caller received cards") }
      cancelled.fulfill()
    }
    let completion = await XCTWaiter().fulfillment(of: [cancelled], timeout: 2)
    XCTAssertEqual(completion, .completed)
    guard completion == .completed, self.provider.cardReads.count == 1 else { return }

    try self.provider.cardReads.finish(0, .success(UserEnvelope(me: .template)))
    _ = try await second.value
    await cancellationCheck.value
    XCTAssertEqual(self.provider.cardReads.count, 1)
  }

  func testReadOvertakenByWriteReloadsBeforePublishingToEitherWaiter() async throws {
    let first = try await self.startCardRead()
    await self.provider.cardReads.waitFor(1)
    let write = Task { try await self.feature.remove(id: "card") }
    await self.provider.removals.waitFor(1)
    let second = try await self.startCardRead()
    try self.provider.cardReads.finish(0, .success(UserEnvelope(me: .template)))
    try self.provider.removals.finish(0, .success(DeletePaymentMethodEnvelope(storedCards: [])))
    await self.provider.cardReads.waitFor(2)
    let refreshedUser = GraphUser.template |> \.storedCards .~ UserCreditCards.withCards([])
    try self.provider.cardReads.finish(1, .success(UserEnvelope(me: refreshedUser)))
    let firstResult = try await first.value
    let secondResult = try await second.value
    XCTAssertEqual(firstResult.me.storedCards.storedCards, [])
    XCTAssertEqual(secondResult.me.storedCards.storedCards, [])
    _ = try await write.value
    XCTAssertEqual(self.provider.cardReads.count, 2)
  }

  func testSessionReplacementReleasesOldCardWaitersAndStartsAnIndependentRead() async throws {
    let old = try await self.startCardRead()
    await self.provider.cardReads.waitFor(1)
    self.session.sessionChanged()
    self.feature.sessionChanged()

    let fresh = try await self.startCardRead()
    await self.provider.cardReads.waitFor(2)
    try self.provider.cardReads.finish(1, .success(UserEnvelope(me: .template)))
    _ = try await fresh.value
    if case let .failure(error) = await old.result { XCTAssertTrue(error is CancellationError) }
    else { XCTFail("Previous session received cards") }
    try self.provider.cardReads.finish(0, .success(UserEnvelope(me: .template)))
    XCTAssertEqual(self.provider.cardReads.count, 2)
  }

  private func startCardRead() async throws -> Task<UserEnvelope<GraphUser>, Error> {
    var read: Task<UserEnvelope<GraphUser>, Error>?
    await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
      read = Task {
        started.resume()
        return try await self.feature.cards()
      }
    }
    return try XCTUnwrap(read)
  }

  func testSessionChangeSuppressesOldIntentValueAndQueuedCardWrite() async throws {
    let intent = Task { try await self.feature.intent(projectID: "p", backingID: "b", checkoutID: "c", total: 1) }
    let removal = Task { try await self.feature.remove(id: "old") }
    await self.provider.intents.waitFor(1)
    await self.provider.removals.waitFor(1)
    let queued = Task { try await self.feature.store(secret: "fixture") }
    await Task.yield()
    self.session.sessionChanged()
    try self.provider.intents.finish(0, .success(PaymentIntentEnvelope(clientSecret: "old")))
    try self.provider.removals.finish(0, .failure(ErrorEnvelope.couldNotParseJSON))
    do { _ = try await intent.value; XCTFail("Old intent must not be delivered") }
    catch { XCTAssertTrue(error is CancellationError) }
    do { _ = try await removal.value; XCTFail("Old error must not be delivered") }
    catch { XCTAssertTrue(error is CancellationError) }
    do { _ = try await queued.value; XCTFail("Old queued write must not be delivered") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(self.provider.stores.count, 0)
  }

  func testAwaitableCommandRejectsCanceledCallerWithoutRetryingWrite() async throws {
    let caller = Task { try await self.feature.setup(projectID: nil, context: .profileSettings) }
    await self.provider.setups.waitFor(1)
    caller.cancel()
    try self.provider.setups.finish(0, .success(ClientSecretEnvelope(clientSecret: "fixture")))
    do { _ = try await caller.value; XCTFail("Canceled caller must not receive a secret") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(self.provider.setups.count, 1)
  }

  func testCancelingIntentWaiterDoesNotCancelAdmittedWrite() async throws {
    let request = self.feature.requestIntent(projectID: "p", backingID: "b", checkoutID: "c", total: 1)
    let waiter = Task { try await request.value }
    waiter.cancel()
    await self.provider.intents.waitFor(1)
    try self.provider.intents.finish(0, .success(PaymentIntentEnvelope(clientSecret: "fixture")))
    let intent = try await request.value
    XCTAssertEqual(intent.clientSecret, "fixture")
    XCTAssertEqual(self.provider.intents.count, 1)
    _ = await waiter.result
  }

  func testPublicDemoRejectsEveryPaymentEntryPoint() async {
    let provider = AsyncPaymentsProvider(service: MockService.publicDemo())
    do { _ = try await provider.cards(); XCTFail("Demo must reject payment reads") } catch {}
    do { _ = try await provider.remove(id: "card"); XCTFail("Demo must reject deletion") } catch {}
    do { _ = try await provider.store(secret: "fixture"); XCTFail("Demo must reject card storage") } catch {}
    do { _ = try await provider.setup(input: .init(projectId: nil, context: .profileSettings)); XCTFail("Demo must reject setup") } catch {}
    do { _ = try await provider.intent(input: .init(projectId: "p", backingId: "b", amountDollars: "1.00", checkoutId: "c", digitalMarketingAttributed: nil)); XCTFail("Demo must reject intent") } catch {}
  }

  private func storedCard() -> CreatePaymentSourceEnvelope {
    CreatePaymentSourceEnvelope(createPaymentSource: .init(isSuccessful: true, paymentSource: UserCreditCards.template.storedCards[0]))
  }
}

@MainActor
private final class ControlledPaymentsProvider: PaymentsProvider {
  let cardReads = AccountRequestGate<UserEnvelope<GraphUser>>()
  let removals = AccountRequestGate<DeletePaymentMethodEnvelope>()
  let stores = AccountRequestGate<CreatePaymentSourceEnvelope>()
  let setups = AccountRequestGate<ClientSecretEnvelope>()
  let intents = AccountRequestGate<PaymentIntentEnvelope>()
  var removedIDs: [String] = []
  var storedSecrets: [String] = []
  var setupInputs: [KsApi.CreateSetupIntentInput] = []
  var intentInputs: [KsApi.CreatePaymentIntentInput] = []
  func cards() async throws -> UserEnvelope<GraphUser> { try await self.cardReads.request() }
  func remove(id: String) async throws -> DeletePaymentMethodEnvelope {
    self.removedIDs.append(id)
    return try await self.removals.request()
  }
  func store(secret: String) async throws -> CreatePaymentSourceEnvelope {
    self.storedSecrets.append(secret)
    return try await self.stores.request()
  }
  func setup(input: KsApi.CreateSetupIntentInput) async throws -> ClientSecretEnvelope {
    self.setupInputs.append(input)
    return try await self.setups.request()
  }
  func intent(input: KsApi.CreatePaymentIntentInput) async throws -> PaymentIntentEnvelope {
    self.intentInputs.append(input)
    return try await self.intents.request()
  }
  func releaseAll() {
    self.cardReads.releaseAll(); self.removals.releaseAll(); self.stores.releaseAll()
    self.setups.releaseAll(); self.intents.releaseAll()
  }
}
