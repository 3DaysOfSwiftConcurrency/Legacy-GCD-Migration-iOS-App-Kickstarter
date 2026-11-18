import Foundation
import KsApi

@MainActor
public final class TwoFactorViewModel {
  var onFirstResponder: (() -> Void)?
  var onFormValid: ((Bool) -> Void)?
  var onLoading: ((Bool) -> Void)?
  var onLogin: ((AccessTokenEnvelope) -> Void)?
  var onNotification: ((Notification, Notification) -> Void)?
  var onResendSuccess: (() -> Void)?
  var onError: ((String) -> Void)?

  private let authenticationFeature: AuthenticationFeature
  private var emailAddress: String?
  private var password: String?
  private var token: String?
  private var code: String?
  private var lastPublishedFormValidity: Bool?
  private var verifyCodeTask: Task<Void, Never>?
  private var resendTask: Task<Void, Never>?
  private var verificationRequestID = UUID()
  private var resendRequestID = UUID()

  public init(authenticationFeature: AuthenticationFeature) {
    self.authenticationFeature = authenticationFeature
  }
  deinit { self.verifyCodeTask?.cancel(); self.resendTask?.cancel() }

  func codeChanged(_ code: String?) { self.code = code; self.publishValidity(code?.count == 6) }
  func email(_ email: String, password: String) { self.emailAddress = email; self.password = password }
  func facebookToken(_ token: String) { self.token = token }
  func viewDidLoad() { self.onFirstResponder?() }
  func viewWillAppear() { self.publishValidity(false) }
  private func publishValidity(_ value: Bool) {
    guard self.lastPublishedFormValidity != value else { return }
    self.lastPublishedFormValidity = value; self.onFormValid?(value)
  }
  private var credentials: AuthenticationFeature.Credentials? {
    if let email = self.emailAddress, let password = self.password { return .email(email, password: password) }
    if let token = self.token { return .facebook(token) }
    return nil
  }
  func submitPressed() {
    guard let credentials = self.credentials else { return }
    if self.verifyCodeTask != nil { self.verifyCodeTask?.cancel(); self.onLoading?(false) }
    let version = UUID(); self.verificationRequestID = version
    let authenticationFeature = self.authenticationFeature, code = self.code
    self.onLoading?(true)
    self.verifyCodeTask = Task { [weak self] in
      do {
        let result = try await authenticationFeature.authenticate(credentials, code: code)
        guard !Task.isCancelled, let self, self.verificationRequestID == version else { return }
        self.onLogin?(result)
      } catch {
        guard !Task.isCancelled, let self, self.verificationRequestID == version else { return }
        let envelope = error as? ErrorEnvelope ?? .couldNotParseJSON
        self.onError?(envelope.errorMessages.first ?? (envelope.ksrCode == .TfaFailed ? Strings.two_factor_error_message() : Strings.login_errors_unable_to_log_in()))
      }
      guard let self, self.verificationRequestID == version else { return }
      self.verifyCodeTask = nil; self.onLoading?(false)
    }
  }
  func resendPressed() {
    guard let credentials = self.credentials else { return }
    if self.resendTask != nil { self.resendTask?.cancel(); self.onLoading?(false) }
    let version = UUID(); self.resendRequestID = version
    let authenticationFeature = self.authenticationFeature
    self.onLoading?(true)
    self.resendTask = Task { [weak self] in
      do { try await authenticationFeature.requestNewTwoFactorCode(credentials) }
      catch {
        guard !Task.isCancelled, let self, self.resendRequestID == version else { return }
        if (error as? ErrorEnvelope)?.ksrCode == .TfaRequired { self.onResendSuccess?() }
      }
      guard let self, self.resendRequestID == version else { return }
      self.resendTask = nil; self.onLoading?(false)
    }
  }
  func environmentLoggedIn() {
    self.onNotification?(Notification(name: .ksr_sessionStarted), Notification(
      name: .ksr_showNotificationsDialog,
      userInfo: [UserInfoKeys.context: PushNotificationDialog.Context.login]
    ))
  }
  func waitForRequests() async { await self.verifyCodeTask?.value; await self.resendTask?.value }
}
