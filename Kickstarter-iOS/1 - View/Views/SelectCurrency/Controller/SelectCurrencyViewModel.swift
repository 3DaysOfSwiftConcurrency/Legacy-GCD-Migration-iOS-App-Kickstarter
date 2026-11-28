import Foundation
import KsApi
import Observation

public struct SelectedCurrencyData: Equatable {
  public let currency: Currency
  public let selected: Bool
}

@MainActor
@Observable
public final class SelectCurrencyViewModel {
  public private(set) var currencyRows: [SelectedCurrencyData] = []
  public private(set) var isLoading = false
  public var saveButtonIsEnabled: Bool { self.selected != self.saved && !self.isLoading }
  public var isSelectionEnabled: Bool { !self.isLoading }
  public var onSuccess: (() -> Void)?
  public var onFailure: ((String) -> Void)?
  private let settingsFeature: SettingsFeature
  private var initial: Currency?
  private var saved: Currency?
  private var selected: Currency?
  private var ordered: [Currency] = []
  private var hasLoaded = false
  private var saveTask: Task<Void, Never>?
  private var revision = 0

  public init(settingsFeature: SettingsFeature) {
    self.settingsFeature = settingsFeature
  }
  public func configure(with selectedCurrency: Currency) {
    self.initial = selectedCurrency
    if self.hasLoaded { self.configureCurrencies(selectedCurrency) }
  }
  public func viewDidLoad() {
    self.hasLoaded = true
    if let initial = self.initial { self.configureCurrencies(initial) }
  }
  private func configureCurrencies(_ initial: Currency) {
    self.saved = initial
    self.selected = initial
    self.ordered = currencies(orderedBySelected: initial)
    self.currencyRows = selectedCurrencyData(with: self.ordered, selected: initial)
  }
  public func didSelectCurrency(atIndex index: Int) {
    guard self.isSelectionEnabled, self.ordered.indices.contains(index) else { return }
    let currency = self.ordered[index]
    self.selected = currency
    self.currencyRows = selectedCurrencyData(with: self.ordered, selected: currency)
  }
  public func saveButtonTapped() {
    guard let currency = self.selected, self.saveButtonIsEnabled else { return }
    self.revision += 1
    let revision = self.revision
    self.isLoading = true
    self.saveTask = Task { [weak self, settingsFeature] in
      do {
        _ = try await settingsFeature.updateAccount(.currency(currency.rawValue))
        try Task.checkCancellation()
        guard let self, self.revision == revision else { return }
        self.isLoading = false
        self.saved = currency
        self.onSuccess?()
      } catch {
        guard let self, !Task.isCancelled, !(error is CancellationError), self.revision == revision else { return }
        self.isLoading = false
        self.onFailure?((error as? ErrorEnvelope)?.localizedDescription ?? error.localizedDescription)
      }
    }
  }
  internal func waitForSave() async { await self.saveTask?.value }
}

internal func currencies(orderedBySelected selected: Currency) -> [Currency] {
  return Currency.allCases.sorted(by: { cur1, _ in cur1 == selected })
}

internal func selectedCurrencyData(with currencies: [Currency], selected: Currency)
  -> [SelectedCurrencyData] {
  return currencies.map { currency in .init(currency: currency, selected: currency == selected) }
}
