@testable import Kickstarter_iOS
@testable import KsApi

import PassKit
import StripePayments
import XCTest

@MainActor
final class ApplePayTokenOperationTests: XCTestCase {
  func testPledgeImplementsPassKitAuthorizationSelector() {
    XCTAssertTrue(PledgeViewController.instancesRespond(to: #selector(
      PKPaymentAuthorizationViewControllerDelegate.paymentAuthorizationViewController(_:didAuthorizePayment:handler:)
    )))
  }

  func testBackgroundCallbackAndDuplicatesReplyOnce() async {
    let operation = ApplePayTokenOperation()
    var callback: (@Sendable (ApplePayTokenOutcome) -> Void)?
    var replies: [PKPaymentAuthorizationStatus] = []
    var applies = 0
    operation.start(isCurrent: { true }, begin: { callback = $0 }, apply: {
      MainActor.assertIsolated()
      XCTAssertEqual($0.tokenID, "token")
      applies += 1
      return .success
    }, reply: { replies.append($0.status) })
    let task = operation.task
    let deliver = callback
    await Task.detached {
      deliver?(.init(tokenID: "token", error: nil))
      deliver?(.init(tokenID: "duplicate", error: nil))
    }.value
    await task?.value
    XCTAssertEqual(applies, 1)
    XCTAssertEqual(replies, [.success])
  }

  func testCancellationRepliesFailureWithoutWaitingForSDK() async {
    let operation = ApplePayTokenOperation()
    var callback: (@Sendable (ApplePayTokenOutcome) -> Void)?
    var replies: [PKPaymentAuthorizationStatus] = []
    operation.start(isCurrent: { true }, begin: { callback = $0 }, apply: { _ in
      XCTFail("Cancelled token"); return .success
    }, reply: { replies.append($0.status) })
    let task = operation.task
    operation.cancelObservation()
    await task?.value
    callback?(.init(tokenID: "late", error: nil))
    XCTAssertEqual(replies, [.failure])
  }

  func testReleaseStillRepliesToPassKit() async {
    var operation: ApplePayTokenOperation? = ApplePayTokenOperation()
    weak var weakOperation = operation
    var replies: [PKPaymentAuthorizationStatus] = []
    operation?.start(isCurrent: { true }, begin: { _ in }, apply: { _ in
      XCTFail("Released owner"); return .success
    }, reply: { replies.append($0.status) })
    let task = operation?.task
    operation = nil
    await task?.value
    XCTAssertNil(weakOperation)
    XCTAssertEqual(replies, [.failure])
  }

  func testAccountChangeBeforeTheSessionNotificationSuppressesBackingButRepliesFailure() async {
    let operation = ApplePayTokenOperation()
    var callback: (@Sendable (ApplePayTokenOutcome) -> Void)?
    var currentUser: User? = .template
    let session = SessionFeature(
      makeProvider: { AsyncSessionProvider(service: MockService()) },
      currentUser: { currentUser }, updateUser: { _ in }
    )
    let pledge = PledgeFeature(platform: .live(), sessionFeature: session, makeProvider: {
      AsyncPledgeProvider(service: MockService())
    })
    let admitted = pledge.sessionIdentity
    var replies: [PKPaymentAuthorizationStatus] = []
    operation.start(isCurrent: { pledge.sessionIdentity == admitted }, begin: { callback = $0 }, apply: { _ in
      XCTFail("Obsolete session"); return .success
    }, reply: { replies.append($0.status) })
    let task = operation.task
    currentUser = nil
    XCTAssertEqual(session.generation, admitted.generation)
    callback?(.init(tokenID: "late", error: nil))
    await task?.value
    XCTAssertEqual(replies, [.failure])
  }

  func testReplacementPledgeRejectsNativeCallbacksInTheSameSession() async throws {
    let service = MockService()
    let session = SessionFeature(
      makeProvider: { AsyncSessionProvider(service: service) },
      currentUser: { .template }, updateUser: { _ in }
    )
    let pledge = PledgeFeature(platform: .live(), sessionFeature: session, makeProvider: {
      AsyncPledgeProvider(service: service)
    })
    let viewModel = PledgeViewModel(
      pledgeFeature: pledge,
      authenticationFeature: AuthenticationFeature(
        sessionFeature: session, makeProvider: { AsyncAuthenticationProvider(service: service) }
      ),
      paymentsFeature: PaymentsFeature(
        sessionFeature: session, makeProvider: { AsyncPaymentsProvider(service: service) }
      ),
      analytics: { AppEnvironment.current.ksrAnalytics },
      currencyContext: { .live() },
      hasEligibleApplePayCard: { _ in true },
      responseDelay: { 0 },
      stripePublishableKey: { "fixture" }
    )
    let reward = Reward.noReward
    func selection(bonus: Double) -> PledgeViewData {
      PledgeViewData(
        project: .template, rewards: [reward], bonusSupport: bonus, selectedShippingRule: nil,
        selectedQuantities: [reward.id: 1], selectedLocationId: nil, refTag: nil, context: .pledge
      )
    }
    viewModel.configure(with: selection(bonus: 5))
    let admitted = try XCTUnwrap(viewModel.paymentPresentation)
    let isCurrent: @MainActor () -> Bool = { viewModel.paymentPresentation == admitted }
    let tokenization = ApplePayTokenOperation()
    let confirmation = StripeConfirmationOperation()
    var tokenCallback: (@Sendable (ApplePayTokenOutcome) -> Void)?
    var stripeCallback: (@Sendable (StripeConfirmationOutcome) -> Void)?
    var replies: [PKPaymentAuthorizationStatus] = []
    tokenization.start(isCurrent: isCurrent, begin: { tokenCallback = $0 }, apply: { _ in
      XCTFail("The previous pledge cannot admit a backing"); return .success
    }, reply: { replies.append($0.status) })
    confirmation.start(identity: .init(kind: .setup, clientSecret: "fixture"), isCurrent: isCurrent,
                       begin: { stripeCallback = $0 }, completed: { _ in
      XCTFail("The previous pledge cannot complete a confirmation")
    })

    viewModel.configure(with: selection(bonus: 10))
    XCTAssertEqual(viewModel.paymentPresentation?.session, admitted.session)
    XCTAssertFalse(isCurrent())
    tokenCallback?(.init(tokenID: "fixture", error: nil))
    stripeCallback?(.init(status: .succeeded, error: nil))
    await tokenization.task?.value
    await confirmation.task?.value
    XCTAssertEqual(replies, [.failure])
  }

  func testOverlappingAuthorizationGetsExplicitFailureAndDoesNotDuplicateTokenization() async {
    let operation = ApplePayTokenOperation()
    var starts = 0
    var replies: [PKPaymentAuthorizationStatus] = []
    operation.start(isCurrent: { true }, begin: { _ in starts += 1 }, apply: { _ in .success },
                    reply: { replies.append($0.status) })
    let task = operation.task
    operation.start(isCurrent: { true }, begin: { _ in starts += 1 }, apply: { _ in .success },
                    reply: { replies.append($0.status) })
    XCTAssertEqual(starts, 1)
    XCTAssertEqual(replies, [.failure])
    operation.cancelObservation()
    await task?.value
    XCTAssertEqual(replies, [.failure, .failure])
  }

  func testTokenFailurePreservesErrorAndAllowsLaterAttempt() async {
    let operation = ApplePayTokenOperation()
    for _ in 0..<2 {
      var replies: [PKPaymentAuthorizationStatus] = []
      operation.start(isCurrent: { true }, begin: { $0(.init(tokenID: nil, error: NSError(domain: "stripe", code: 4))) },
                      apply: { outcome in
        XCTAssertNil(outcome.tokenID)
        XCTAssertEqual((outcome.error as NSError?)?.code, 4)
        return .failure
      }, reply: { replies.append($0.status) })
      await operation.task?.value
      XCTAssertEqual(replies, [.failure])
      XCTAssertNil(operation.task)
    }
  }
}
