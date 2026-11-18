import KsApi

extension CreatePaymentSourceSetupIntentInput {
  internal static func input(
    fromIntentClientSecret clientSecret: String,
    reuseable: Bool
  ) -> CreatePaymentSourceSetupIntentInput {
    return CreatePaymentSourceSetupIntentInput(intentClientSecret: clientSecret, reuseable: reuseable)
  }
}
