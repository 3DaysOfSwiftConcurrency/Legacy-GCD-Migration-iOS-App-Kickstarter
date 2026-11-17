import Foundation
import KsApi

@MainActor
public protocol AuthenticationProvider {
  func login(_ credentials: AuthenticationFeature.Credentials, code: String?) async throws
    -> AccessTokenEnvelope
  func resetPassword(email: String) async throws
}

@MainActor
public struct AsyncAuthenticationProvider: AuthenticationProvider {
  private let service: any ServiceType
  public init(service: any ServiceType) { self.service = service }

  public func login(
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

  public func resetPassword(email: String) async throws {
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
    let responseDelaySeconds: @MainActor () -> TimeInterval
    let trackLoginPageViewed: @MainActor () -> Void
    let trackLoginSubmitButtonClicked: @MainActor () -> Void
    let trackLoginToutPageViewed: @MainActor () -> Void
    let trackLoginInitiateButtonClicked: @MainActor () -> Void

    public init(
      webBaseURL: @escaping @MainActor () -> URL,
      oauthClientID: @escaping @MainActor () -> String,
      appleAppID: @escaping @MainActor () -> String,
      responseDelaySeconds: @escaping @MainActor () -> TimeInterval,
      trackLoginPageViewed: @escaping @MainActor () -> Void,
      trackLoginSubmitButtonClicked: @escaping @MainActor () -> Void,
      trackLoginToutPageViewed: @escaping @MainActor () -> Void,
      trackLoginInitiateButtonClicked: @escaping @MainActor () -> Void
    ) {
      self.webBaseURL = webBaseURL
      self.oauthClientID = oauthClientID
      self.appleAppID = appleAppID
      self.responseDelaySeconds = responseDelaySeconds
      self.trackLoginPageViewed = trackLoginPageViewed
      self.trackLoginSubmitButtonClicked = trackLoginSubmitButtonClicked
      self.trackLoginToutPageViewed = trackLoginToutPageViewed
      self.trackLoginInitiateButtonClicked = trackLoginInitiateButtonClicked
    }
  }

  public var webBaseURL: URL { self.platform.webBaseURL() }
  public var responseDelaySeconds: TimeInterval { self.platform.responseDelaySeconds() }
  public func loginToutPageViewed() { self.platform.trackLoginToutPageViewed() }
  public func loginInitiateButtonClicked() { self.platform.trackLoginInitiateButtonClicked() }
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
    var committedGeneration: Int?

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
  private var redirects: [UUID: (url: URL, request: Pending<URL?>)] = [:]
  private var redirectVersions: [UUID: UUID] = [:]
  private let session: SessionFeature
  private let platform: Platform
  private let makeProvider: () -> any AuthenticationProvider
  // The legacy screen allows resend and verification concurrently. A resend
  // must not supersede a submitted code; replacements are scoped per operation.
  private var current: [Operation: Attempt] = [:]
  private var attempts: [UUID: Attempt] = [:]
  private final class ResetAttempt {
    let email: String
    let task: Task<Void, Error>
    var waiters = 0
    init(email: String, task: Task<Void, Error>) { self.email = email; self.task = task }
  }

  private var resetAttempt: ResetAttempt?
  public private(set) var lastError: Error?
  public var sessionGeneration: Int { self.session.generation }

  public init(
    sessionFeature: SessionFeature,
    platform: Platform,
    makeProvider: @escaping () -> any AuthenticationProvider,
    resolveRedirect: @escaping (URL) async throws -> URL? = { try await FirstRedirectResolver.resolve($0) }
  ) {
    self.resolveRedirect = resolveRedirect
    self.session = sessionFeature
    self.platform = platform
    self.makeProvider = makeProvider
  }

  func makeLoginSignup(intent: LoginIntent) -> LoginSignupUseCase {
    LoginSignupUseCase(withLoginIntent: intent, currentUser: { [session] in session.currentUser })
  }

  /// One replaceable email-link read per navigation route. URL is Sendable;
  /// the session and operation identity are checked again after every waiter resumes.
  public func firstRedirect(_ url: URL, route: UUID) async throws -> URL? {
    try Task.checkCancellation()
    let session = Session(userID: self.session.currentUser?.id, generation: self.session.generation)
    let pending: Pending<URL?>
    if let current = self.redirects[route], current.url == url, current.request.session == session {
      pending = current.request
    } else {
      self.releaseEmailRedirect(route: route)
      let id = UUID()
      let task = Task { [self] in
        defer {
          if self.redirects[route]?.request.id == id { self.redirects[route] = nil }
        }
        try self.requireCurrentRedirectSession(session)
        let value = try await self.resolveRedirect(url)
        try self.requireCurrentRedirectSession(session)
        guard self.redirectVersions[route] == id else { throw CancellationError() }
        return value
      }
      pending = Pending(id: id, session: session, task: task)
      self.redirects[route] = (url, pending)
      self.redirectVersions[route] = id
    }
    let value = try await pending.task.value
    try self.requireCurrentRedirectSession(session)
    guard self.redirectVersions[route] == pending.id else { throw CancellationError() }
    return value
  }

  func releaseEmailRedirect(route: UUID) {
    self.redirects.removeValue(forKey: route)?.request.task.cancel()
    self.redirectVersions[route] = nil
  }

  func resetEmailRedirects() {
    for route in Array(self.redirectVersions.keys) { self.releaseEmailRedirect(route: route) }
  }

  private func requireCurrentRedirectSession(_ session: Session) throws {
    try Task.checkCancellation()
    guard self.session.isCurrent(userID: session.userID, generation: session.generation) else {
      throw CancellationError()
    }
  }

  public var signInWithAppleAppID: String { self.platform.appleAppID() }

  public func loginPageViewed() {
    self.platform.trackLoginPageViewed()
  }

  public func loginSubmitButtonClicked() {
    self.platform.trackLoginSubmitButtonClicked()
  }

  public func authenticate(
    _ credentials: Credentials,
    code: String? = nil
  ) async throws -> AccessTokenEnvelope {
    try Task.checkCancellation()
    return try await self.finish(self.admit(credentials, code: code, resend: false))
  }

  public func resendCode(_ credentials: Credentials) async throws {
    try Task.checkCancellation()
    _ = try await self.finish(self.admit(credentials, code: nil, resend: true))
  }

  /// Independent of login/resend. Duplicate pending requests share one send;
  /// changed email replaces presentation. Cancellation cannot unsend an email
  /// or undo account creation on the server; no write is automatically retried.
  public func resetPassword(email: String) async throws {
    try Task.checkCancellation()
    try await self.finishReset(self.admitReset(email: email))
  }

  private func admitReset(email: String) -> ResetAttempt {
    let attempt: ResetAttempt
    if let current = self.resetAttempt, current.email == email {
      attempt = current
    } else {
      self.resetAttempt?.task.cancel()
      let provider = self.makeProvider()
      attempt = ResetAttempt(email: email, task: Task {
        try Task.checkCancellation()
        try await provider.resetPassword(email: email)
      })
      self.resetAttempt = attempt
    }
    attempt.waiters += 1
    return attempt
  }

  private func finishReset(_ attempt: ResetAttempt) async throws {
    defer {
      attempt.waiters -= 1
      if attempt.waiters == 0, self.resetAttempt === attempt { self.resetAttempt = nil }
    }
    do {
      try await attempt.task.value
      try Task.checkCancellation()
      guard self.resetAttempt === attempt else { throw CancellationError() }
    } catch {
      try Task.checkCancellation()
      guard self.resetAttempt === attempt else { throw CancellationError() }
      throw error
    }
  }

  private func admit(_ credentials: Credentials, code: String?, resend: Bool) -> Attempt {
    let operation: Operation = resend ? .resend : .login
    if let current = self.current[operation],
       current.credentials == credentials, current.code == code,
       self.session.isCurrent(userID: current.userID, generation: current.generation) {
      current.waiters += 1
      return current
    }
    self.current[operation]?.task.cancel()
    let provider = self.makeProvider()
    let task = Task {
      try Task.checkCancellation()
      return try await provider.login(credentials, code: code)
    }
    let attempt = Attempt(
      credentials: credentials, code: code, operation: operation,
      userID: self.session.currentUser?.id, generation: self.session.generation, task: task
    )
    attempt.waiters = 1
    self.current[operation] = attempt
    self.attempts[attempt.id] = attempt
    self.lastError = nil
    return attempt
  }

  private func finish(_ attempt: Attempt) async throws -> AccessTokenEnvelope {
    defer {
      attempt.waiters -= 1
      if attempt.waiters == 0 {
        self.attempts[attempt.id] = nil
        if self.current[attempt.operation]?.id == attempt.id { self.current[attempt.operation] = nil }
      }
    }
    do {
      let envelope = try await attempt.task.value
      try Task.checkCancellation()
      guard self.current[attempt.operation]?.id == attempt.id else { throw CancellationError() }
      if let committed = attempt.committedGeneration {
        guard self.session.isCurrent(userID: envelope.user.id, generation: committed)
        else { throw CancellationError() }
      } else {
        guard self.session.isCurrent(userID: attempt.userID, generation: attempt.generation)
        else { throw CancellationError() }
        if attempt.operation == .login {
          // Preserve OAuth's pre-login analytics identity, exactly once for
          // shared callers and only after a complete, current result.
          if case .oauth = attempt.credentials { self.loginSubmitButtonClicked() }
          try self.session.establishSession(
            envelope, userID: attempt.userID, generation: attempt.generation
          )
          attempt.committedGeneration = self.session.generation
        }
      }
      self.lastError = nil
      return envelope
    } catch {
      try Task.checkCancellation()
      guard self.current[attempt.operation]?.id == attempt.id,
            self.session.isCurrent(userID: attempt.userID, generation: attempt.generation)
      else { throw CancellationError() }
      if !(error is CancellationError) { self.lastError = error }
      throw error
    }
  }


}
