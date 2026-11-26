import Foundation
import KsApi
import Observation

@MainActor
@Observable
public final class SettingsNewsletterCellViewModel {
  public private(set) var switchIsOn: Bool?
  public private(set) var subscribeToAllSwitchIsOn: Bool?
  public var onOptIn: ((String) -> Void)?
  public var onError: ((String) -> Void)?
  public var onUserUpdated: ((User) -> Void)?
  private let settingsFeature: SettingsFeature
  private var user: User?
  private var newsletter: Newsletter?
  private var revision = 0
  private var saves: [UUID: Task<Void, Never>] = [:]

  public init(settingsFeature: SettingsFeature) {
    self.settingsFeature = settingsFeature
  }

  public func configureWith(value: (newsletter: Newsletter, user: User)) {
    self.newsletter = value.newsletter
    self.configureWith(value: value.user)
  }

  public func configureWith(value user: User) {
    self.user = user
    self.subscribeToAllSwitchIsOn = user.newsletters.arts == true && user.newsletters.games == true
      && user.newsletters.happening == true && user.newsletters.invent == true && user.newsletters.promo == true
      && user.newsletters.weekly == true && user.newsletters.films == true && user.newsletters.publishing == true
      && user.newsletters.alumni == true
    if let newsletter = self.newsletter { self.switchIsOn = user[keyPath: UserAttribute.newsletter(newsletter).keyPath] }
  }

  public func newslettersSwitchTapped(on: Bool) {
    guard let newsletter = self.newsletter else { return }
    if self.settingsFeature.requiresConfiguredCountryNewsletterOptIn, on {
      self.onOptIn?(newsletter.displayableName)
    }
    self.save([.init(.newsletter(newsletter), on)])
  }

  public func allNewslettersSwitchTapped(on: Bool) { self.save(SettingsFeature.Change.allNewsletters(on)) }

  private func save(_ changes: [SettingsFeature.Change]) {
    guard let user = self.user else { return }
    self.revision += 1
    let revision = self.revision
    let id = UUID()
    let settingsFeature = self.settingsFeature
    self.saves[id] = Task { [weak self] in
      defer { self?.saves[id] = nil }
      let result: Result<User, Error>
      do { result = .success(try await settingsFeature.savePreferences(changes, from: user)) }
      catch { result = .failure(error) }
      guard let self, self.revision == revision else { return }
      switch result {
      case let .success(user): self.onUserUpdated?(user)
      case let .failure(error):
        guard !(error is CancellationError) else { return }
        self.onError?((error as? ErrorEnvelope)?.errorMessages.first ?? Strings.profile_settings_error())
      }
    }
  }

  internal func waitForSaves() async { for task in Array(self.saves.values) { await task.value } }
}
