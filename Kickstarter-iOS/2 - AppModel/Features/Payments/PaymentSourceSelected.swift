public typealias StripePaymentMethodID = String
public typealias KSRCreditCardId = String
public enum PaymentSourceSelected: Equatable {
  case savedCreditCard(KSRCreditCardId, StripePaymentMethodID?)

  public var savedCreditCardId: KSRCreditCardId {
    switch self {
    case let .savedCreditCard(savedCardId, _):
      return savedCardId
    }
  }

  public var stripePaymentMethodId: StripePaymentMethodID? {
    switch self {
    case let .savedCreditCard(_, paymentMethodId):
      return paymentMethodId
    }
  }
}
