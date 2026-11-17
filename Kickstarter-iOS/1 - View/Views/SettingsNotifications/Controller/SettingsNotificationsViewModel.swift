import Foundation
import KsApi
import Observation

@MainActor
@Observable
public final class SettingsNotificationsViewModel {
  public var onUser: ((User) -> Void)?
  public var onPickerHidden: ((Bool) -> Void)?
  public var onPickerSelection: ((EmailFrequency) -> Void)?
  public var onError: ((String) -> Void)?
  public var onManageProjects: (() -> Void)?
  private let settingsFeature: SettingsFeature
  private let sleep: (TimeInterval) async throws -> Void
  private var initialUser: User?
  private var pickerHidden: Bool?
  private var reads: [UUID: Task<Void, Never>] = [:]
  private var saves: [UUID: Task<Void, Never>] = [:]
  private var revision = 0

  public init(settingsFeature: SettingsFeature, sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
    if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
  }) {
    self.settingsFeature = settingsFeature
    self.sleep = sleep
  }

  public var currentUser: User? { self.settingsFeature.sessionFeature.currentUser }

  public func viewDidLoad() {
    if let user = self.settingsFeature.sessionFeature.currentUser { self.displayInitial(user) }
    let id = UUID()
    let settingsFeature = self.settingsFeature
    self.reads[id] = Task { [weak self, settingsFeature] in
      defer { self?.reads[id] = nil }
      guard let user = try? await settingsFeature.refresh(), !Task.isCancelled else { return }
      self?.displayInitial(user)
    }
  }

  private func displayInitial(_ user: User) {
    self.initialUser = user
    self.display(user)
  }

  private func display(_ user: User) {
    self.onUser?(user)
    self.setPickerHidden(true)
    if let digest = user[keyPath: UserAttribute.notification(.creatorDigest).keyPath] {
      self.onPickerSelection?(digest ? .dailySummary : .twiceADaySummary)
    }
  }

  private func setPickerHidden(_ hidden: Bool) {
    guard self.pickerHidden != hidden else { return }
    self.pickerHidden = hidden
    self.onPickerHidden?(hidden)
  }

  public func didSelectRow(cellType: SettingsNotificationCellType) {
    if cellType == .emailFrequency { self.setPickerHidden(false) }
    if cellType == .projectNotifications { self.onManageProjects?() }
  }

  public func didSelectEmailFrequency(frequency: EmailFrequency) {
    self.setPickerHidden(true)
    guard let source = self.initialUser else { return }
    self.revision += 1
    let revision = self.revision
    let id = UUID()
    let settingsFeature = self.settingsFeature
    let sleep = self.sleep
    let delay = AppEnvironment.current.apiDelayInterval.searchDelaySeconds
    self.saves[id] = Task { [weak self] in
      defer { self?.saves[id] = nil }
      let result: Result<User, Error>
      do {
        result = .success(try await settingsFeature.save([.init(.notification(.creatorDigest), frequency == .dailySummary)],
                                                         from: source))
      } catch { result = .failure(error) }
      do { try await sleep(delay) } catch { return }
      guard let self, self.revision == revision else { return }
      switch result {
      case let .success(user): self.display(user)
      case let .failure(error):
        guard !(error is CancellationError) else { return }
        self.onError?((error as? ErrorEnvelope)?.errorMessages.first ?? Strings.profile_settings_error())
      }
    }
  }

  public func dismissPickerTap() { self.setPickerHidden(true) }
  public func updateUser(user: User) {
    AppEnvironment.current.identify(user: user)
    self.display(user)
  }
  public func failedToUpdateUser(error: String) { self.onError?(error) }
  public func shouldSelectRow(for cellType: SettingsNotificationCellType) -> Bool {
    cellType == .projectNotifications || cellType == .emailFrequency
  }
  internal func waitForLoads() async { for task in Array(self.reads.values) { await task.value } }
  internal func waitForSaves() async { for task in Array(self.saves.values) { await task.value } }
}
