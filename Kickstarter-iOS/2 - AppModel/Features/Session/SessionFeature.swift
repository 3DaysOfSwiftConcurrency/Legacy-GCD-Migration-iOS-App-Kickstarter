import Foundation
import KsApi

@MainActor
public protocol SessionProvider {
  func fetchGraphUserSetup() async throws -> GraphUserSetup
  func fetchCurrentUser() async throws -> User
  func fetchGraphUser() async throws -> User
  func clearActivityIndicator() async throws -> Int
  func registerDeviceToken(_ token: String) async throws
}

@MainActor
public struct AsyncSessionProvider: SessionProvider {
  private let service: any ServiceType
  public init(service: any ServiceType) { self.service = service }
  public func fetchGraphUserSetup() async throws -> GraphUserSetup { try await self.service.sessionSetup() }
  public func fetchCurrentUser() async throws -> User { try await self.service.sessionUser() }
  public func fetchGraphUser() async throws -> User { try await self.service.sessionGraphUser() }
  public func clearActivityIndicator() async throws -> Int { try await self.service.clearActivityIndicator() }
  public func registerDeviceToken(_ token: String) async throws {
    try await self.service.registerApplicationPushToken(token)
  }
}

/// Owns shared account reads, badge mutations and the current account's device registration.
/// AppEnvironment remains the single credential/current-user store during staged
/// adoption; this Feature deliberately does not introduce a competing user cache.
@MainActor
public final class SessionFeature {
  public enum Operation: Hashable { case user, graphUser, clearActivity }
  private struct Identity: Hashable {
    let operation: Operation
    let userID: Int?
    let sessionGeneration: Int
    let readInvalidationVersion: Int
  }

  struct Storage {
    let currentUser: () -> User?
    let currentUserEmail: () -> String?
    let currentUserPPOSettings: () -> PPOUserSettings?
    let updateUser: @MainActor (User) -> Void
    let login: @MainActor (AccessTokenEnvelope) -> Void
    let applyGraphUserSetup: (GraphUserSetup) -> Void
  }

  private let makeProvider: () -> any SessionProvider
  private let deviceRegistrationDebounce: @MainActor () async throws -> Void
  private var deviceRegistrationDebounceTask: (id: UUID, task: Task<Void, Never>)?
  private var deviceRegistrationDeliveryTask: (id: UUID, task: Task<Void, Never>)?
  private var latestQueuedDeviceRegistration: (
    token: String, userID: Int?, generation: Int, id: UUID, task: Task<String, Error>
  )?
  private let storage: Storage
  private var pendingSetupReads: [Identity: Task<GraphUserSetup, Error>] = [:]
  private var sessionGeneration = 0
  private var userReadInvalidationVersion = 0
  private var setupReadInvalidationVersion = 0
  private var pendingUserOperations: [Identity: Task<User, Error>] = [:]
  public var currentUser: User? { self.storage.currentUser() }
  public var currentUserEmail: String? { self.storage.currentUserEmail() }
  public var currentUserPPOSettings: PPOUserSettings? { self.storage.currentUserPPOSettings() }
  public var generation: Int { self.sessionGeneration }
  public var userReadGeneration: Int { self.userReadInvalidationVersion }

  init(
    makeProvider: @escaping () -> any SessionProvider,
    deviceRegistrationDebounce: @escaping @MainActor () async throws -> Void,
    storage: Storage
  ) {
    self.makeProvider = makeProvider
    self.deviceRegistrationDebounce = deviceRegistrationDebounce
    self.storage = storage
  }

  /// Login/logout is an explicit boundary, including returning to the same ID.
  /// Admitted badge and device-registration writes continue but cannot publish into a newer session.
  public func sessionChanged() {
    self.sessionGeneration += 1
    self.deviceRegistrationDebounceTask?.task.cancel()
    self.deviceRegistrationDeliveryTask?.task.cancel()
    for task in self.pendingSetupReads.values { task.cancel() }
    for (identity, task) in self.pendingUserOperations where identity.operation != .clearActivity { task.cancel() }
  }

  /// Register the device against this session after the existing token debounce.
  /// The native messaging SDK receives its raw token separately at application ingress.
  func scheduleDeviceRegistration(for deviceToken: Data, onRegistered: @escaping @MainActor (String) -> Void) {
    self.deviceRegistrationDebounceTask?.task.cancel()
    let token = deviceToken.map { String(format: "%02.2hhx", $0 as CVarArg) }.joined()
    let debounce = self.deviceRegistrationDebounce
    let generation = self.generation
    let userID = self.currentUser?.id
    let id = UUID()
    let task = Task { [weak self] in
      defer {
        if self?.deviceRegistrationDebounceTask?.id == id { self?.deviceRegistrationDebounceTask = nil }
      }
      do {
        try await debounce()
        try Task.checkCancellation()
        guard let self, self.isCurrentDeviceRegistration(userID: userID, generation: generation) else { return }
        self.deviceRegistrationDeliveryTask?.task.cancel()
        let request = self.startDeviceRegistration(token: token)
        let deliveryID = UUID()
        let delivery = Task { [weak self] in
          defer {
            if self?.deviceRegistrationDeliveryTask?.id == deliveryID { self?.deviceRegistrationDeliveryTask = nil }
          }
          do {
            let registeredToken = try await request.value
            try Task.checkCancellation()
            guard self?.isCurrentDeviceRegistration(userID: userID, generation: generation) == true else { return }
            onRegistered(registeredToken)
          } catch { /* Keep registration failures silent at the application boundary. */ }
        }
        self.deviceRegistrationDeliveryTask = (deliveryID, delivery)
      } catch { /* A newer token or session superseded this debounce. */ }
    }
    self.deviceRegistrationDebounceTask = (id, task)
  }

  func waitForDeviceRegistration() async {
    await self.deviceRegistrationDebounceTask?.task.value
    await self.deviceRegistrationDeliveryTask?.task.value
  }

  /// Equal pending tokens share a request. Changed tokens serialize so the most
  /// recent registration reaches the server last. Admitted writes finish across logout.
  @discardableResult
  func startDeviceRegistration(token: String) -> Task<String, Error> {
    let generation = self.generation
    let userID = self.currentUser?.id
    if let tail = self.latestQueuedDeviceRegistration, tail.token == token,
       self.isCurrentDeviceRegistration(userID: tail.userID, generation: tail.generation) { return tail.task }
    let previous = self.latestQueuedDeviceRegistration?.task
    let id = UUID()
    let provider = self.makeProvider()
    let task = Task { [self] in
      defer { if self.latestQueuedDeviceRegistration?.id == id { self.latestQueuedDeviceRegistration = nil } }
      if let previous { _ = await previous.result }
      try Task.checkCancellation()
      guard self.isCurrentDeviceRegistration(userID: userID, generation: generation) else { throw CancellationError() }
      do {
        try await provider.registerDeviceToken(token)
      } catch {
        guard !Task.isCancelled, self.isCurrentDeviceRegistration(userID: userID, generation: generation)
        else { throw CancellationError() }
        throw error
      }
      try Task.checkCancellation()
      guard self.isCurrentDeviceRegistration(userID: userID, generation: generation),
            self.latestQueuedDeviceRegistration?.id == id else { throw CancellationError() }
      return token
    }
    self.latestQueuedDeviceRegistration = (token, userID, generation, id, task)
    return task
  }

  /// Stored credentials may restore a missing user without replacing the session.
  /// A known account must still match; every login/logout invalidates the generation.
  private func isCurrentDeviceRegistration(userID: Int?, generation: Int) -> Bool {
    self.generation == generation && (userID == nil || self.currentUser?.id == userID)
  }

  /// A completed account-affecting command requires fresh reads, without
  /// pretending that the user logged out or interrupting admitted badge writes.
  public func invalidateAccountReads() {
    self.setupReadInvalidationVersion += 1
    for task in self.pendingSetupReads.values { task.cancel() }
    self.invalidateUserReads()
  }

  /// Badge changes invalidate whole-user snapshots, not unrelated email/setup metadata.
  private func invalidateUserReads() {
    self.userReadInvalidationVersion += 1
    for (identity, task) in self.pendingUserOperations where identity.operation != .clearActivity { task.cancel() }
  }

  public func isCurrent(userID: Int?, generation: Int) -> Bool {
    self.currentUser?.id == userID && self.sessionGeneration == generation
  }

  /// Captures the authenticated session at admission so a completion cannot
  /// publish after logout or account replacement.
  public func wrapOperationForCurrentSession<Value>(_ operation: @escaping @MainActor () async throws -> Value)
    -> @MainActor () async throws -> Value
  {
    let userID = self.currentUser?.id
    let generation = self.sessionGeneration
    return { [self] in
      try Task.checkCancellation()
      guard self.isCurrent(userID: userID, generation: generation) else { throw CancellationError() }
      let value = try await operation()
      try Task.checkCancellation()
      guard self.isCurrent(userID: userID, generation: generation) else { throw CancellationError() }
      return value
    }
  }

  /// Persistence stays behind the existing current-user store. A stale response
  /// must never recreate a logged-out account or update a replacement account.
  public func commitUser(_ user: User, userID: Int?, generation: Int) {
    guard userID == user.id, self.isCurrent(userID: userID, generation: generation) else { return }
    self.storage.updateUser(user)
  }

  /// A stored OAuth token can restore a user absent from legacy defaults. Only
  /// the authenticated lifecycle path opts in; ordinary reads cannot sign in.
  public func commitRefreshedUser(
    _ user: User, userID: Int?, generation: Int, allowSessionRestore: Bool
  ) {
    guard self.isCurrent(userID: userID, generation: generation),
          userID == user.id || (userID == nil && allowSessionRestore) else { return }
    self.storage.updateUser(user)
  }

  /// Commit credentials and user together through the existing store, only if
  /// the session that initiated authentication still owns this completion.
  public func establishSession(
    _ envelope: AccessTokenEnvelope, userID: Int?, generation: Int
  ) throws {
    guard self.isCurrent(userID: userID, generation: generation) else { throw CancellationError() }
    self.sessionChanged()
    self.storage.login(envelope)
  }

  /// Email, feature flags and backing-action metadata belong to the same session
  /// as the user. Only the shared execution commits; observers never replay it.
  public func refreshGraphUserSetup() async throws -> GraphUserSetup {
    try Task.checkCancellation()
    let identity = Identity(
      operation: .user,
      userID: self.currentUser?.id,
      sessionGeneration: self.sessionGeneration,
      readInvalidationVersion: self.setupReadInvalidationVersion
    )
    let task: Task<GraphUserSetup, Error>
    if let existing = self.pendingSetupReads[identity] {
      task = existing
    } else {
      let provider = self.makeProvider()
      task = Task { [self] in
        defer { self.pendingSetupReads[identity] = nil }
        do {
          try Task.checkCancellation()
          let setup = try await provider.fetchGraphUserSetup()
          try Task.checkCancellation()
          guard self.isCurrent(userID: identity.userID, generation: identity.sessionGeneration),
                self.setupReadInvalidationVersion == identity.readInvalidationVersion else { throw CancellationError() }
          self.storage.applyGraphUserSetup(setup)
          return setup
        } catch {
          guard !Task.isCancelled,
                self.isCurrent(userID: identity.userID, generation: identity.sessionGeneration),
                self.setupReadInvalidationVersion == identity.readInvalidationVersion else { throw CancellationError() }
          throw error
        }
      }
      self.pendingSetupReads[identity] = task
    }
    do {
      let setup = try await task.value
      try Task.checkCancellation()
      guard self.isCurrent(userID: identity.userID, generation: identity.sessionGeneration),
            self.setupReadInvalidationVersion == identity.readInvalidationVersion else { throw CancellationError() }
      return setup
    } catch {
      guard !Task.isCancelled,
            self.isCurrent(userID: identity.userID, generation: identity.sessionGeneration),
            self.setupReadInvalidationVersion == identity.readInvalidationVersion else { throw CancellationError() }
      throw error
    }
  }

  public func refreshCurrentUser() async throws -> User {
    try await self.refreshUserOperation(.user)
  }

  public func refreshGraphUser() async throws -> User {
    try await self.refreshUserOperation(.graphUser)
  }

  public func clearActivityIndicatorAndRefreshUser() async throws -> User {
    try await self.refreshUserOperation(.clearActivity)
  }

  private func refreshUserOperation(_ operation: Operation) async throws -> User {
    try Task.checkCancellation()
    let userID = self.currentUser?.id
    let generation = self.sessionGeneration
    let userReadGeneration = self.userReadInvalidationVersion
    do {
      let user = try await self.startUserOperation(operation).value
      try Task.checkCancellation()
      guard self.isCurrent(userID: userID, generation: generation),
            operation == .clearActivity || self.userReadInvalidationVersion == userReadGeneration
      else { throw CancellationError() }
      return user
    } catch {
      guard !Task.isCancelled, self.isCurrent(userID: userID, generation: generation),
            operation == .clearActivity || self.userReadInvalidationVersion == userReadGeneration
      else { throw CancellationError() }
      throw error
    }
  }

  @discardableResult
  public func startCurrentUserFetch() -> Task<User, Error> {
    self.startUserOperation(.user)
  }

  @discardableResult
  public func startGraphUserFetch() -> Task<User, Error> {
    self.startUserOperation(.graphUser)
  }

  /// Clears the server's activity indicator and returns the user with its updated count.
  @discardableResult
  public func startClearActivityIndicator() -> Task<User, Error> {
    self.startUserOperation(.clearActivity)
  }

  private func startUserOperation(_ operation: Operation) -> Task<User, Error> {
    let identity = Identity(
      operation: operation, userID: self.currentUser?.id, sessionGeneration: self.sessionGeneration,
      readInvalidationVersion: operation == .clearActivity ? 0 : self.userReadInvalidationVersion
    )
    if let task = self.pendingUserOperations[identity] { return task }
    let provider = self.makeProvider()
    let task = Task { [self] in
      defer { self.pendingUserOperations[identity] = nil }
      try Task.checkCancellation()
      guard self.isCurrent(userID: identity.userID, generation: identity.sessionGeneration)
      else { throw CancellationError() }
      do {
        let user: User
        switch operation {
        case .user: user = try await provider.fetchCurrentUser()
        case .graphUser: user = try await provider.fetchGraphUser()
        case .clearActivity:
          guard identity.userID != nil else { throw CancellationError() }
          let count = try await provider.clearActivityIndicator()
          guard var current = self.currentUser else { throw CancellationError() }
          current.unseenActivityCount = count
          user = current
        }
        try Task.checkCancellation()
        guard self.isCurrent(userID: identity.userID, generation: identity.sessionGeneration),
              operation == .clearActivity || self.userReadInvalidationVersion == identity.readInvalidationVersion
        else { throw CancellationError() }
        if operation == .clearActivity {
          // Both root-tab and Activity callers share this execution and one commit.
          self.commitUser(user, userID: identity.userID, generation: identity.sessionGeneration)
          self.invalidateUserReads()
        }
        return user
      } catch {
        // An old unauthorized response must not log out a replacement session.
        guard !Task.isCancelled, self.isCurrent(userID: identity.userID, generation: identity.sessionGeneration),
              operation == .clearActivity || self.userReadInvalidationVersion == identity.readInvalidationVersion
        else { throw CancellationError() }
        throw error
      }
    }
    self.pendingUserOperations[identity] = task
    return task
  }
}
