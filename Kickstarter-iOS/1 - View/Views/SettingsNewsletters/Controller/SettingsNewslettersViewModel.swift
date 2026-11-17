import Foundation
import KsApi
import Observation

@MainActor
@Observable
public final class SettingsNewslettersViewModel {
  public var onUser: ((User) -> Void)?
  private let settingsFeature: SettingsFeature
  private var lastLoadedUser: User?
  private var reads: [UUID: Task<Void, Never>] = [:]

  public init(settingsFeature: SettingsFeature) {
    self.settingsFeature = settingsFeature
  }

  public func viewDidLoad() {
    if let user = self.settingsFeature.sessionFeature.currentUser { self.displayLoaded(user) }
    let id = UUID()
    let settingsFeature = self.settingsFeature
    self.reads[id] = Task { [weak self, settingsFeature] in
      defer { self?.reads[id] = nil }
      guard let user = try? await settingsFeature.refresh(), !Task.isCancelled else { return }
      self?.displayLoaded(user)
    }
  }

  private func displayLoaded(_ user: User) {
    guard user != self.lastLoadedUser else { return }
    self.lastLoadedUser = user
    self.onUser?(user)
  }

  public func didUpdate(user: User) { self.onUser?(user) }

  internal func waitForLoads() async {
    for task in Array(self.reads.values) { await task.value }
  }
}
