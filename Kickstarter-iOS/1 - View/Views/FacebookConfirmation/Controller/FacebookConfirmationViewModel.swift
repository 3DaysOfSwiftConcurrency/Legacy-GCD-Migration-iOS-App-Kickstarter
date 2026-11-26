import Foundation
import KsApi
import Observation

@MainActor
@Observable
public final class FacebookConfirmationViewModel {
  public private(set) var displayEmail = ""
  public private(set) var sendNewsletters = false
  public private(set) var isLoading = false
  public var onLogin: (() -> Void)?
  public var onSignupSuccess: (() -> Void)?
  public var onSignupError: ((String) -> Void)?
  public var onHelp: ((HelpType) -> Void)?

  private let authenticationFeature: AuthenticationFeature
  private var token = ""
  private var signupTask: Task<Void, Never>?
  private var revision = 0
  public var webBaseURL: URL { self.authenticationFeature.webBaseURL }

  public init(authenticationFeature: AuthenticationFeature) {
    self.authenticationFeature = authenticationFeature
  }

  public func viewDidLoad() { self.sendNewsletters = false }
  public func email(_ email: String) { self.displayEmail = email }
  public func facebookToken(_ token: String) { self.token = token }
  public func sendNewslettersToggled(_ newsletters: Bool) { self.sendNewsletters = newsletters }
  public func loginButtonPressed() { self.onLogin?() }
  public func tapped(_ url: URL) {
    guard let helpType = self.authenticationFeature.helpType(for: url) else { return }
    self.onHelp?(helpType)
  }
  public func createAccountButtonPressed() {
    self.signupTask?.cancel()
    self.revision += 1
    let revision = self.revision
    let credentials = AuthenticationFeature.Credentials.facebookSignup(self.token, sendNewsletters: self.sendNewsletters)
    self.isLoading = true
    self.signupTask = Task { [weak self, authenticationFeature] in
      do {
        _ = try await authenticationFeature.authenticate(credentials)
        try Task.checkCancellation()
        guard self?.revision == revision else { return }
        self?.isLoading = false
        guard self?.revision == revision else { return }
        self?.onSignupSuccess?()
      } catch {
        guard let self, !Task.isCancelled, !(error is CancellationError), self.revision == revision else { return }
        self.isLoading = false
        guard self.revision == revision else { return }
        self.onSignupError?((error as? ErrorEnvelope)?.errorMessages.first ?? Strings.facebook_confirmation_could_not_log_in())
      }
    }
  }
  internal func waitForSignup() async { await self.signupTask?.value }
}
