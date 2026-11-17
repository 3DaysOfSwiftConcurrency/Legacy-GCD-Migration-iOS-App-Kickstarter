@testable import Kickstarter_iOS
import GraphAPI
@testable import KsApi

@MainActor
final class CheckoutPaymentsProvider: PaymentsProvider {
  private(set) var paymentIntentRequests = 0
  private(set) var setupIntentRequests = 0
  private(set) var storeRequests = 0
  private(set) var removeRequests = 0

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
  func remove(id: String) async throws -> DeletePaymentMethodEnvelope {
    self.removeRequests += 1
    return try await self.provider.remove(id: id)
  }
  func store(secret: String) async throws -> CreatePaymentSourceEnvelope {
    self.storeRequests += 1
    return try await self.provider.store(secret: secret)
  }
}
