@testable import Kickstarter_iOS
import GraphAPI
@testable import KsApi


@MainActor
public class MockStripeIntentService: StripeIntentServiceType {
  public private(set) var setupIntentRequests: Int = 0
  public private(set) var paymentIntentRequests: Int = 0

  public let paymentsFeature: PaymentsFeature
  public init() {
    let session = SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) })
    self.paymentsFeature = PaymentsFeature(sessionFeature: session, makeProvider: {
      precondition(AppEnvironment.current.apiService is MockService)
      return AsyncPaymentsProvider(service: AppEnvironment.current.apiService)
    })
  }

  public func createPaymentIntent(
    for projectId: String,
    backingId: String,
    checkoutId: String,
    pledgeTotal: Double
  ) -> Task<PaymentIntentEnvelope, Error> {
    assert(
      AppEnvironment.current.apiService is MockService,
      "AppEnvironment.current.apiService should be a MockService when used in test."
    )

    self.paymentIntentRequests += 1

    return self.paymentsFeature.requestIntent(projectID: projectId, backingID: backingId, checkoutID: checkoutId, total: pledgeTotal)
  }

  public func setupIntent(for projectId: String?, context: GraphAPI.StripeIntentContextTypes) async throws -> ClientSecretEnvelope {
    self.setupIntentRequests += 1
    return try await self.paymentsFeature.setup(projectID: projectId, context: context)
  }

}

@MainActor
final class CheckoutPaymentsProvider: PaymentsProvider {
  private(set) var paymentIntentRequests = 0
  private(set) var setupIntentRequests = 0

  private var provider: AsyncPaymentsProvider {
    precondition(AppEnvironment.current.apiService is MockService)
    return AsyncPaymentsProvider(service: AppEnvironment.current.apiService)
  }

  func intent(input: KsApi.CreatePaymentIntentInput) async throws -> PaymentIntentEnvelope {
    self.paymentIntentRequests += 1
    return try await self.provider.intent(input: input)
  }

  func setup(input: KsApi.CreateSetupIntentInput) async throws -> ClientSecretEnvelope {
    self.setupIntentRequests += 1
    return try await self.provider.setup(input: input)
  }

  func cards() async throws -> UserEnvelope<GraphUser> { try await self.provider.cards() }
  func remove(id: String) async throws -> DeletePaymentMethodEnvelope { try await self.provider.remove(id: id) }
  func store(secret: String) async throws -> CreatePaymentSourceEnvelope { try await self.provider.store(secret: secret) }
}
