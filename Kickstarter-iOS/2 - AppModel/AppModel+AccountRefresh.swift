import Foundation
import KsApi

extension AppModel {
  enum AccountUpdate {
    case user(User)
    case invalidSession
    case recommendationsAvailable(Bool)
  }

  /// Settings serializes account refresh with preference writes; Discovery owns recommendation reads.
  func refreshAccount(onUpdate: @escaping @MainActor (AccountUpdate) -> Void) {
    self.settingsFeature.scheduleAccountRefresh { [weak self] result in
      guard let self else { return }
      switch result {
      case let .success(user):
        let userID = self.sessionFeature.currentUser?.id
        let generation = self.sessionFeature.generation
        if let user { onUpdate(.user(user)) }
        // A synchronous consumer may replace the session while handling the user update.
        guard self.sessionFeature.isCurrent(userID: userID, generation: generation) else { return }
        self.discoveryFeature.refreshRecommendationAvailability {
          onUpdate(.recommendationsAvailable($0))
        }
      case let .failure(error):
        if (error as? ErrorEnvelope)?.ksrCode == .AccessTokenInvalid { onUpdate(.invalidSession) }
      }
    }
  }

  func refreshAccountAndSetup(onUpdate: @escaping @MainActor (AccountUpdate) -> Void) {
    self.refreshAccount(onUpdate: onUpdate)
    self.settingsFeature.refreshAccountSetup { [weak self] in self?.notifyUserUpdated() }
  }

  func notifyUserUpdated(notificationCenter: NotificationCenter = .default) {
    notificationCenter.post(.init(name: .ksr_userUpdated, object: nil))
  }
}
