import Foundation
import KsApi

@MainActor
public protocol AuthenticationProvider {
  func authenticate(_ credentials: AuthenticationFeature.Credentials, code: String?) async throws
    -> AccessTokenEnvelope
  func requestPasswordReset(email: String) async throws
}

@MainActor
public struct AsyncAuthenticationProvider: AuthenticationProvider {
  private let service: any ServiceType
  public init(service: any ServiceType) { self.service = service }

  public func authenticate(
    _ credentials: AuthenticationFeature.Credentials, code: String?
  ) async throws -> AccessTokenEnvelope {
    switch credentials {
    case let .email(email, password):
      return try await self.service.authenticate(email: email, password: password, code: code)
    case let .facebook(token):
      return try await self.service.authenticate(facebookAccessToken: token, code: code)
    case let .facebookSignup(token, newsletters):
      return try await self.service.signupFacebook(token: token, sendNewsletters: newsletters)
    case let .apple(appID, firstName, lastName, token):
      let result = try await self.service.authenticateApple(input: SignInWithAppleInput(
        appId: appID, authCode: token, firstName: firstName, lastName: lastName
      ))
      try Task.checkCancellation()
      guard let id = Int(result.signInWithApple.user.uid) else { throw ErrorEnvelope.couldNotParseJSON }
      let user = try await self.service.authenticationUser(id: id)
      try Task.checkCancellation()
      return AccessTokenEnvelope(accessToken: result.signInWithApple.apiAccessToken, user: user)
    case let .oauth(code, verifier):
      let result = try await self.service.exchangeOAuth(params: OAuthTokenExchangeParams(
        temporaryToken: code, codeVerifier: verifier
      ))
      try Task.checkCancellation()
      // The exchanged token is used for this request only. Never persist a
      // partial login before the matching user has been fetched successfully.
      let user = try await self.service.authenticationUser(oauthToken: result.token)
      try Task.checkCancellation()
      return AccessTokenEnvelope(accessToken: result.token, user: user)
    }
  }

  public func requestPasswordReset(email: String) async throws {
    try await self.service.requestPasswordReset(email: email)
  }
}

/// Owns login/verification attempts. Equivalent pending attempts share transport;
/// changed credentials/code replace the older attempt, matching the legacy
/// switch-to-latest interaction. Credentials exist only for the attempt lifetime.
@MainActor
public final class AuthenticationFeature {
  public struct Platform {
    let webBaseURL: @MainActor () -> URL
    let oauthClientID: @MainActor () -> String
    let appleAppID: @MainActor () -> String
    let trackLoginPageViewed: @MainActor () -> Void
    let trackLoginSubmitButtonClicked: @MainActor () -> Void
    let trackLoginToutPageViewed: @MainActor () -> Void
    let trackLoginInitiateButtonClicked: @MainActor () -> Void

    public init(
      webBaseURL: @escaping @MainActor () -> URL,
      oauthClientID: @escaping @MainActor () -> String,
      appleAppID: @escaping @MainActor () -> String,
      trackLoginPageViewed: @escaping @MainActor () -> Void,
      trackLoginSubmitButtonClicked: @escaping @MainActor () -> Void,
      trackLoginToutPageViewed: @escaping @MainActor () -> Void,
      trackLoginInitiateButtonClicked: @escaping @MainActor () -> Void
    ) {
      self.webBaseURL = webBaseURL
      self.oauthClientID = oauthClientID
      self.appleAppID = appleAppID
      self.trackLoginPageViewed = trackLoginPageViewed
      self.trackLoginSubmitButtonClicked = trackLoginSubmitButtonClicked
      self.trackLoginToutPageViewed = trackLoginToutPageViewed
      self.trackLoginInitiateButtonClicked = trackLoginInitiateButtonClicked
    }
  }

  public var webBaseURL: URL { self.platform.webBaseURL() }
  public func trackLoginToutPageView() { self.platform.trackLoginToutPageViewed() }
  public func trackLoginInitiateButtonClick() { self.platform.trackLoginInitiateButtonClicked() }
  func oauthAuthorizationURL(codeChallenge: String, redirectScheme: String) -> URL? {
    let parameters = [
      URLQueryItem(name: "redirect_uri", value: redirectScheme),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: "email"),
      URLQueryItem(name: "client_id", value: self.platform.oauthClientID()),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "code_challenge", value: codeChallenge)
    ]
    var components = URLComponents(url: self.webBaseURL, resolvingAgainstBaseURL: false)
    components?.path = "/oauth/authorizations/new"
    components?.queryItems = parameters
    return components?.url
  }
  public func helpType(for url: URL) -> HelpType? {
    HelpType.allCases.first { url.absoluteString == $0.url(withBaseUrl: self.webBaseURL)?.absoluteString }
  }
  private enum Operation { case login, resend }

  public enum Credentials: Equatable {
    case email(String, password: String)
    case facebook(String)
    case facebookSignup(String, sendNewsletters: Bool)
    case apple(appID: String, firstName: String?, lastName: String?, token: String)
    case oauth(code: String, verifier: String)
  }

  private final class Attempt {
    let id = UUID()
    let credentials: Credentials
    let code: String?
    let operation: Operation
    let userID: Int?
    let generation: Int
    let task: Task<AccessTokenEnvelope, Error>
    var waiters = 0
    var establishedSessionGeneration: Int?

    init(
      credentials: Credentials, code: String?, operation: Operation, userID: Int?, generation: Int,
      task: Task<AccessTokenEnvelope, Error>
    ) {
      self.credentials = credentials
      self.code = code
      self.operation = operation
      self.userID = userID
      self.generation = generation
      self.task = task
    }
  }

  private struct Session: Equatable {
    let userID: Int?
    let generation: Int
  }
  private struct Pending<Value: Sendable> {
    let id: UUID
    let session: Session
    let task: Task<Value, Error>
  }
  private let resolveRedirect: (URL) async throws -> URL?
  private var pendingEmailRedirectsByRoute: [UUID: (url: URL, request: Pending<URL?>)] = [:]
  private var latestEmailRedirectIDsByRoute: [UUID: UUID] = [:]
  private let session: SessionFeature
  private let platform: Platform
  private let makeProvider: () -> any AuthenticationProvider
  // The legacy screen allows resend and verification concurrently. A resend
  // must not supersede a submitted code; replacements are scoped per operation.
  private var currentAttemptsByOperation: [Operation: Attempt] = [:]
  private var attempts: [UUID: Attempt] = [:]
  private final class PasswordResetRequest {
    let email: String
    let task: Task<Void, Error>
    var waiters = 0
    init(email: String, task: Task<Void, Error>) { self.email = email; self.task = task }
  }

  private var passwordResetRequest: PasswordResetRequest?
  public private(set) var lastError: Error?
  public var sessionGeneration: Int { self.session.generation }

  public init(
    sessionFeature: SessionFeature,
    platform: Platform,
    makeProvider: @escaping () -> any AuthenticationProvider,
    resolveRedirect: @escaping (URL) async throws -> URL? = { try await FirstRedirectResolver.fetchRedirectDestination($0) }
  ) {
    self.resolveRedirect = resolveRedirect
    self.session = sessionFeature
    self.platform = platform
    self.makeProvider = makeProvider
  }

  func makeLoginSignupUseCase(intent: LoginIntent) -> LoginSignupUseCase {
    LoginSignupUseCase(withLoginIntent: intent, currentUser: { [session] in session.currentUser })
  }

  /// One replaceable email-link read per navigation route. URL is Sendable;
  /// the session and operation identity are checked again after every waiter resumes.
  public func resolveFirstEmailRedirect(_ url: URL, route: UUID) async throws -> URL? {
    try Task.checkCancellation()
    let session = Session(userID: self.session.currentUser?.id, generation: self.session.generation)
    let pending: Pending<URL?>
    if let current = self.pendingEmailRedirectsByRoute[route], current.url == url, current.request.session == session {
      pending = current.request
    } else {
      self.cancelEmailRedirect(route: route)
      let id = UUID()
      let task = Task { [self] in
        defer {
          if self.pendingEmailRedirectsByRoute[route]?.request.id == id {
            self.pendingEmailRedirectsByRoute[route] = nil
          }
        }
        try self.ensureEmailRedirectSessionIsCurrent(session)
        let value = try await self.resolveRedirect(url)
        try self.ensureEmailRedirectSessionIsCurrent(session)
        guard self.latestEmailRedirectIDsByRoute[route] == id else { throw CancellationError() }
        return value
      }
      pending = Pending(id: id, session: session, task: task)
      self.pendingEmailRedirectsByRoute[route] = (url, pending)
      self.latestEmailRedirectIDsByRoute[route] = id
    }
    let value = try await pending.task.value
    try self.ensureEmailRedirectSessionIsCurrent(session)
    guard self.latestEmailRedirectIDsByRoute[route] == pending.id else { throw CancellationError() }
    return value
  }

  func cancelEmailRedirect(route: UUID) {
    self.pendingEmailRedirectsByRoute.removeValue(forKey: route)?.request.task.cancel()
    self.latestEmailRedirectIDsByRoute[route] = nil
  }

  func cancelAllEmailRedirects() {
    for route in Array(self.latestEmailRedirectIDsByRoute.keys) { self.cancelEmailRedirect(route: route) }
  }

  private func ensureEmailRedirectSessionIsCurrent(_ session: Session) throws {
    try Task.checkCancellation()
    guard self.session.isCurrent(userID: session.userID, generation: session.generation) else {
      throw CancellationError()
    }
  }

  public var signInWithAppleAppID: String { self.platform.appleAppID() }

  public func trackLoginPageView() {
    self.platform.trackLoginPageViewed()
  }

  public func trackLoginSubmitButtonClick() {
    self.platform.trackLoginSubmitButtonClicked()
  }

  public func authenticate(
    _ credentials: Credentials,
    code: String? = nil
  ) async throws -> AccessTokenEnvelope {
    try Task.checkCancellation()
    let attempt = self.startOrReuseAuthenticationAttempt(credentials, code: code, operation: .login)
    return try await self.awaitAuthenticationResult(attempt)
  }

  public func requestNewTwoFactorCode(_ credentials: Credentials) async throws {
    try Task.checkCancellation()
    let attempt = self.startOrReuseAuthenticationAttempt(credentials, code: nil, operation: .resend)
    _ = try await self.awaitAuthenticationResult(attempt)
  }

  /// Independent of login/resend. Duplicate pending requests share one send;
  /// changed email replaces presentation. Cancellation cannot unsend an email
  /// or undo account creation on the server; no write is automatically retried.
  public func requestPasswordReset(email: String) async throws {
    try Task.checkCancellation()
    try await self.awaitPasswordResetRequest(self.startOrReusePasswordResetRequest(email: email))
  }

  private func startOrReusePasswordResetRequest(email: String) -> PasswordResetRequest {
    let attempt: PasswordResetRequest
    if let current = self.passwordResetRequest, current.email == email {
      attempt = current
    } else {
      self.passwordResetRequest?.task.cancel()
      let provider = self.makeProvider()
      attempt = PasswordResetRequest(email: email, task: Task {
        try Task.checkCancellation()
        try await provider.requestPasswordReset(email: email)
      })
      self.passwordResetRequest = attempt
    }
    attempt.waiters += 1
    return attempt
  }

  private func awaitPasswordResetRequest(_ attempt: PasswordResetRequest) async throws {
    defer {
      attempt.waiters -= 1
      if attempt.waiters == 0, self.passwordResetRequest === attempt { self.passwordResetRequest = nil }
    }
    do {
      try await attempt.task.value
      try Task.checkCancellation()
      guard self.passwordResetRequest === attempt else { throw CancellationError() }
    } catch {
      try Task.checkCancellation()
      guard self.passwordResetRequest === attempt else { throw CancellationError() }
      throw error
    }
  }

  private func startOrReuseAuthenticationAttempt(
    _ credentials: Credentials, code: String?, operation: Operation
  ) -> Attempt {
    if let current = self.currentAttemptsByOperation[operation],
       current.credentials == credentials, current.code == code,
       self.session.isCurrent(userID: current.userID, generation: current.generation) {
      current.waiters += 1
      return current
    }
    self.currentAttemptsByOperation[operation]?.task.cancel()
    let provider = self.makeProvider()
    let task = Task {
      try Task.checkCancellation()
      return try await provider.authenticate(credentials, code: code)
    }
    let attempt = Attempt(
      credentials: credentials, code: code, operation: operation,
      userID: self.session.currentUser?.id, generation: self.session.generation, task: task
    )
    attempt.waiters = 1
    self.currentAttemptsByOperation[operation] = attempt
    self.attempts[attempt.id] = attempt
    self.lastError = nil
    return attempt
  }

  private func awaitAuthenticationResult(_ attempt: Attempt) async throws -> AccessTokenEnvelope {
    defer {
      attempt.waiters -= 1
      if attempt.waiters == 0 {
        self.attempts[attempt.id] = nil
        if self.currentAttemptsByOperation[attempt.operation]?.id == attempt.id {
          self.currentAttemptsByOperation[attempt.operation] = nil
        }
      }
    }
    do {
      let envelope = try await attempt.task.value
      try Task.checkCancellation()
      guard self.currentAttemptsByOperation[attempt.operation]?.id == attempt.id else { throw CancellationError() }
      if let committed = attempt.establishedSessionGeneration {
        guard self.session.isCurrent(userID: envelope.user.id, generation: committed)
        else { throw CancellationError() }
      } else {
        guard self.session.isCurrent(userID: attempt.userID, generation: attempt.generation)
        else { throw CancellationError() }
        if attempt.operation == .login {
          // Preserve OAuth's pre-login analytics identity, exactly once for
          // shared callers and only after a complete, current result.
          if case .oauth = attempt.credentials { self.trackLoginSubmitButtonClick() }
          try self.session.establishSession(
            envelope, userID: attempt.userID, generation: attempt.generation
          )
          attempt.establishedSessionGeneration = self.session.generation
        }
      }
      self.lastError = nil
      return envelope
    } catch {
      try Task.checkCancellation()
      guard self.currentAttemptsByOperation[attempt.operation]?.id == attempt.id,
            self.session.isCurrent(userID: attempt.userID, generation: attempt.generation)
      else { throw CancellationError() }
      if !(error is CancellationError) { self.lastError = error }
      throw error
    }
  }


}
