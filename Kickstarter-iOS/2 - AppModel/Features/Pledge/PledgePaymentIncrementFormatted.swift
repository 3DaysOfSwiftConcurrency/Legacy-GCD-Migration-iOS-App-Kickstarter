import Foundation
import KsApi

public struct PledgePaymentIncrementFormatted: Equatable {
  public var incrementChargeNumber: String
  public var amount: String
  public var scheduledCollection: String

  @MainActor
  init(from increment: PledgePaymentIncrement, index: Int) {
    let chargeNumber = String(index + 1)
    self.incrementChargeNumber = Strings.Charge_number(number: chargeNumber)
    self.amount = increment.amount.amountFormattedInProjectNativeCurrency
    self.scheduledCollection = formatScheduledCollectionDate(increment.scheduledCollection)
  }
}

@MainActor
private func formatScheduledCollectionDate(_ collectionTimestamp: TimeInterval) -> String {
  Format.date(
    secondsInUTC: collectionTimestamp,
    dateStyle: .medium,
    timeStyle: .none
  )
}
