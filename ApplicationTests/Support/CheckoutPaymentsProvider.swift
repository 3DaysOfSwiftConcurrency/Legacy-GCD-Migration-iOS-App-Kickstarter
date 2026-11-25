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

  func createPaymentIntent(input: KsApi.CreatePaymentIntentInput) async throws -> PaymentIntentEnvelope {
    self.paymentIntentRequests += 1
    return try await self.provider.createPaymentIntent(input: input)
  }

  func createSetupIntent(input: KsApi.CreateSetupIntentInput) async throws -> ClientSecretEnvelope {
    self.setupIntentRequests += 1
    return try await self.provider.createSetupIntent(input: input)
  }

  func fetchSavedCards() async throws -> UserEnvelope<GraphUser> { try await self.provider.fetchSavedCards() }
  func removePaymentMethod(id: String) async throws -> DeletePaymentMethodEnvelope {
    self.removeRequests += 1
    return try await self.provider.removePaymentMethod(id: id)
  }
  func createPaymentSource(secret: String) async throws -> CreatePaymentSourceEnvelope {
    self.storeRequests += 1
    return try await self.provider.createPaymentSource(secret: secret)
  }
}
