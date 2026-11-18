import Foundation
import KsApi

extension AppModel {
  enum AccountRefreshUpdate {
    case user(User)
    case invalidSession
    case recommendationsAvailable(Bool)
  }

  /// Settings serializes account refresh with preference writes; Discovery owns recommendation reads.
  func refreshAccount(delivering update: @escaping @MainActor (AccountRefreshUpdate) -> Void) {
    self.settingsFeature.scheduleAccountRefresh { [weak self] result in
      guard let self else { return }
      switch result {
      case let .success(user):
        let userID = self.sessionFeature.currentUser?.id
        let generation = self.sessionFeature.generation
        if let user { update(.user(user)) }
        // A synchronous consumer may replace the session while handling the user update.
        guard self.sessionFeature.isCurrent(userID: userID, generation: generation) else { return }
        self.discoveryFeature.refreshRecommendationAvailability {
          update(.recommendationsAvailable($0))
        }
      case let .failure(error):
        if (error as? ErrorEnvelope)?.ksrCode == .AccessTokenInvalid { update(.invalidSession) }
      }
    }
  }

  func refreshAccountAndCheckSetup(delivering update: @escaping @MainActor (AccountRefreshUpdate) -> Void) {
    self.refreshAccount(delivering: update)
    self.settingsFeature.refreshAccountSetup { [weak self] in self?.postUserUpdatedNotification() }
  }

  func postUserUpdatedNotification(notificationCenter: NotificationCenter = .default) {
    notificationCenter.post(.init(name: .ksr_userUpdated, object: nil))
  }
}
