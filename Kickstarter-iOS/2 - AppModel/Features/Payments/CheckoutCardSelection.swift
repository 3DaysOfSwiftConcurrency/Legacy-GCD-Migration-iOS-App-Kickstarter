import KsApi

public typealias CheckoutPaymentCard = (
  card: UserCreditCards.CreditCard,
  isEnabled: Bool,
  isSelected: Bool,
  projectCountry: String,
  isErroredPaymentMethod: Bool
)

struct CheckoutCardSelection {
  struct Snapshot {
    var existing: [CheckoutPaymentCard] = []
    var added: [CheckoutPaymentCard] = []
    var selected: PaymentSourceSelected?
  }

  private var initial: Snapshot?
  private var addedCards: [UserCreditCards.CreditCard] = []
  private(set) var snapshot: Snapshot?

  mutating func beginLoading() {
    self.snapshot = Snapshot()
  }

  mutating func load(_ cards: [UserCreditCards.CreditCard], for project: Project) -> Snapshot? {
    guard let allowedTypes = project.availableCardTypes else { return nil }
    let backing = project.personalization.backing
    let backedCardID = backing?.paymentSource?.id
    let ordered = cards.filter { $0.id == backedCardID } + cards.filter { $0.id != backedCardID }
    let rows = Self.rankedCards(ordered, for: project, allowedTypes: allowedTypes)
    let selectedCard: UserCreditCards.CreditCard?
    if let backing {
      selectedCard = backing.status == .errored ? nil : rows.first { $0.card.id == backedCardID }?.card
    } else {
      selectedCard = rows.first(where: \.isEnabled)?.card
    }
    let result = Snapshot(
      existing: Self.markSelection(rows, selectedCard),
      selected: selectedCard.map(Self.paymentSource)
    )
    self.initial = result
    self.snapshot = result
    return result
  }

  mutating func add(
    _ savedCard: UserCreditCards.CreditCard, stripePaymentMethodID: String?, for project: Project
  ) -> Snapshot? {
    guard let allowedTypes = project.availableCardTypes else { return nil }
    var card = savedCard
    if card.stripeCardId == nil { card.stripeCardId = stripePaymentMethodID }
    self.addedCards.insert(card, at: 0)
    guard var result = self.initial else { return nil }
    let rows = Self.rankedCards(self.addedCards, for: project, allowedTypes: allowedTypes)
    result.added = rows
    if let first = rows.first, first.isEnabled {
      result.existing = Self.markSelection(result.existing, nil)
      result.added = Self.markSelection(rows, first.card)
      result.selected = Self.paymentSource(first.card)
    } else if let first = rows.first, project.personalization.backing != nil {
      // Retain the legacy default for a backing when none of the added cards is supported.
      result.added = Self.markSelection(rows, first.card)
      result.selected = Self.paymentSource(first.card)
    }
    self.snapshot = result
    return result
  }

  func canSelect(row: Int) -> Bool {
    guard let snapshot = self.snapshot else { return false }
    return self.card(at: row, in: snapshot)?.isEnabled == true
  }

  mutating func select(row: Int) -> Snapshot? {
    guard var snapshot = self.snapshot, let entry = self.card(at: row, in: snapshot),
          entry.isEnabled else { return nil }
    let fromAdded = row < snapshot.added.count
    snapshot.added = Self.markSelection(snapshot.added, fromAdded ? entry.card : nil)
    snapshot.existing = Self.markSelection(snapshot.existing, fromAdded ? nil : entry.card)
    snapshot.selected = Self.paymentSource(entry.card)
    self.snapshot = snapshot
    return snapshot
  }

  private func card(at row: Int, in snapshot: Snapshot) -> CheckoutPaymentCard? {
    guard row >= 0 else { return nil }
    if row < snapshot.added.count { return snapshot.added[row] }
    let existingIndex = row - snapshot.added.count
    return snapshot.existing.indices.contains(existingIndex) ? snapshot.existing[existingIndex] : nil
  }

  private static func rankedCards(
    _ cards: [UserCreditCards.CreditCard], for project: Project, allowedTypes: [String]
  ) -> [CheckoutPaymentCard] {
    let backing = project.personalization.backing
    let country = project.location?.displayableName ?? ""
    let rows = cards.compactMap { card -> CheckoutPaymentCard? in
      guard let brand = card.type?.rawValue else { return nil }
      return (
        card: card, isEnabled: allowedTypes.contains(brand), isSelected: false, projectCountry: country,
        isErroredPaymentMethod: card.id == backing?.paymentSource?.id && backing?.status == .errored
      )
    }
    return rows.filter(\.isEnabled) + rows.filter { !$0.isEnabled }
  }

  private static func markSelection(
    _ cards: [CheckoutPaymentCard], _ selected: UserCreditCards.CreditCard?
  ) -> [CheckoutPaymentCard] {
    cards.map { card in
      var row = card
      row.isSelected = row.card == selected
      return row
    }
  }

  private static func paymentSource(_ card: UserCreditCards.CreditCard) -> PaymentSourceSelected {
    guard let stripeCardID = card.stripeCardId, !stripeCardID.isEmpty else {
      assert(false, "Expected stripeCardId to be set. Late pledges may fail if this value is missing.")
      return .savedCreditCard(card.id, nil)
    }
    return .savedCreditCard(card.id, stripeCardID)
  }
}
