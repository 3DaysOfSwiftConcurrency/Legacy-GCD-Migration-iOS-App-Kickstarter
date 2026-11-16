import Observation
import KsApi

@MainActor
@Observable
public final class LoginSignupUseCase {
  public private(set) var isLoggedIn = false
  var onLogin: ((LoginIntent) -> Void)?
  var onSessionChanged: (() -> Void)?
  var onLoginState: ((Bool) -> Void)?
  private let intent: LoginIntent
  private let currentUser: @MainActor () -> User?

  init(
    withLoginIntent intent: LoginIntent,
    currentUser: @escaping @MainActor () -> User?
  ) {
    self.intent = intent
    self.currentUser = currentUser
  }

  public func initialDataAvailable() { self.publishLoginState() }
  public func goToLoginSignupTapped() { self.onLogin?(self.intent) }
  public func userSessionDidChange() {
    self.publishLoginState()
    self.onSessionChanged?()
  }

  private func publishLoginState() {
    self.isLoggedIn = self.currentUser() != nil
    self.onLoginState?(self.isLoggedIn)
  }
}
