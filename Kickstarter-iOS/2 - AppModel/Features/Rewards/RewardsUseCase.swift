import Foundation

@MainActor
public final class RewardsUseCase {
  private var hasTokenValue = false
  private var secretRewardToken: String?
  private let isLoggedIn: @MainActor () -> Bool
  var onLogin: ((LoginIntent) -> Void)?
  var onRewards: (() -> Void)?

  public init(isLoggedIn: @escaping @MainActor () -> Bool) {
    self.isLoggedIn = isLoggedIn
  }

  func configure(secretRewardToken: String?) {
    self.hasTokenValue = true
    self.secretRewardToken = secretRewardToken
  }

  func goToRewardsTapped() {
    guard self.hasTokenValue else { return }
    if let token = self.secretRewardToken, !token.isEmpty, !self.isLoggedIn() {
      self.onLogin?(.backProject)
    } else {
      self.onRewards?()
    }
  }
}
