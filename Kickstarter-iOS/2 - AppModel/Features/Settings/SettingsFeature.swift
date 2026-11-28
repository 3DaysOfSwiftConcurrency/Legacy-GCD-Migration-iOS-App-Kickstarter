import Foundation
import KsApi
import Prelude

@MainActor
public protocol AccountPreferencesProvider {
  func saveAccountPreferences(_ user: User) async throws -> User
  func fetchProjectNotifications() async throws -> [ProjectNotification]
  func saveProjectNotification(_ notification: ProjectNotification) async throws -> ProjectNotification
  func updateAccount(_ change: SettingsFeature.AccountChange) async throws -> User?
  func fetchEmailUser() async throws -> GraphUser
  func verifyEmail(token: String) async throws -> EmailVerificationResponseEnvelope
}

@MainActor
public struct AsyncAccountPreferencesProvider: AccountPreferencesProvider {
  private let service: any ServiceType
  public init(service: any ServiceType) { self.service = service }
  public func saveAccountPreferences(_ user: User) async throws -> User {
    try await self.service.saveAccountPreferences(user)
  }

  public func verifyEmail(token: String) async throws -> EmailVerificationResponseEnvelope {
    try await self.service.confirmEmail(token: token)
  }

  public func fetchProjectNotifications() async throws -> [ProjectNotification] {
    try await self.service.projectNotificationSettings()
  }

  public func saveProjectNotification(_ notification: ProjectNotification) async throws
    -> ProjectNotification {
    try await self.service.saveProjectNotification(notification)
  }

  public func fetchEmailUser() async throws -> GraphUser { try await self.service.accountEmailUser() }

  public func updateAccount(_ change: SettingsFeature.AccountChange) async throws -> User? {
    switch change {
    case let .email(input): try await self.service.saveEmail(input)
    case let .password(input): try await self.service.savePassword(input)
    case let .initialPassword(input): try await self.service.setInitialPassword(input)
    case let .currency(currency): try await self.service.saveCurrency(.init(chosenCurrency: currency))
    case .sendVerification: try await self.service.requestEmailVerification()
    case let .facebook(token): return try await self.service.connectFacebook(token: token)
    }
    return nil
  }
}

/// Owns ordered preference edits, not credentials or a second current-user store.
/// The legacy endpoint takes a whole User. Edits are applied to the authoritative
/// session user at dispatch, so stale cells cannot undo another screen's edits.
@MainActor
public final class SettingsFeature {
  /// Application-owned reactions to confirmed settings changes. The feature
  /// reports the semantic event without depending on UIKit or NotificationCenter.
  public struct Events {
    let localePreferencesChanged: @MainActor () -> Void

    public init(localePreferencesChanged: @escaping @MainActor () -> Void) {
      self.localePreferencesChanged = localePreferencesChanged
    }

    public static let none = Self(localePreferencesChanged: {})
  }

  /// Commands contain credentials only for their admitted lifetime, never in evidence or persistent state.
  public enum AccountChange: Equatable {
    case email(ChangeEmailInput)
    case password(ChangePasswordInput)
    case initialPassword(CreatePasswordInput)
    case currency(String)
    case sendVerification
    case facebook(String)
  }

  private enum Edit: Equatable {
    case preferences([Change])
    case account(AccountChange)
  }

  public struct Change: Hashable {
    let path: WritableKeyPath<User, Bool?>
    let value: Bool?

    public init(_ attribute: UserAttribute, _ value: Bool?) {
      self.path = attribute.keyPath
      self.value = value
    }

    @MainActor public static func allNewsletters(_ on: Bool) -> [Change] {
      SettingsFeature.newsletters.map { Change(.newsletter($0), on) }
    }
  }

  private struct Account: Equatable {
    let id: Int?
    let generation: Int
    let sourceID: Int
  }

  private struct Pending {
    let id: UUID
    let account: Account
    let edit: Edit
    let task: Task<User, Error>
  }

  private static let newsletters: [Newsletter] = [
    .arts, .games, .happening, .invent, .promo, .weekly, .films, .publishing, .alumni, .music
  ]
  private static var attributes: [UserAttribute] {
    let notifications: [UserAttribute.Notification] = [
      .commentReplies, .comments, .creatorDigest, .creatorTips, .follower, .friendActivity, .messages,
      .mobileComments, .mobileFollower, .mobileFriendActivity, .mobileMarketingUpdate, .mobileMessages,
      .mobilePledgeActivity, .mobilePostLikes, .mobileUpdates, .pledgeActivity, .postLikes, .updates
    ]
    return self.newsletters.map(UserAttribute.newsletter)
      + notifications.map(UserAttribute.notification)
      + [.privacy(.following), .privacy(.recommendations), .privacy(.showPublicProfile)]
  }

  private struct NotificationWrite {
    let id: UUID
    let userID: Int
    let generation: Int
    let email: Bool
    let mobile: Bool
    let task: Task<ProjectNotification, Error>
  }

  private var latestNotificationWriteByID: [Int: NotificationWrite] = [:]
  private var notificationWrites: [UUID: Task<ProjectNotification, Error>] = [:]
  private var notificationWriteRevision = 0
  private let confirmedProjectNotifications = NSCache<NSNumber, NSNumber>()
  private var projectNotificationCacheSession: (userID: Int, generation: Int)?

  private let session: SessionFeature
  private let makeProvider: () -> any AccountPreferencesProvider
  private let hasStoredCredentials: @MainActor () -> Bool
  private let applicationVersion: @MainActor () -> String
  private let identifyUser: @MainActor (User) -> Void
  private let events: Events
  private var accountRefreshDebounceTask: Task<Void, Never>?
  private var activeAccountRefreshTask: Task<Void, Never>?
  private var account: Account?
  private var latestQueuedAccountWrite: Pending?
  private var accountWriteTasks: [UUID: Task<User, Error>] = [:]
  private var accountRefreshTasks: [UUID: Task<User, Error>] = [:]
  private var accountSetupRefreshRequest: (id: UUID, task: Task<Void, Never>)?
  private var pendingEmailUserRead: (
    id: UUID,
    userID: Int?,
    generation: Int,
    revision: Int,
    task: Task<GraphUser, Error>
  )?
  private struct Verification {
    let id: UUID
    let token: String
    let userID: Int?
    let generation: Int
    let task: Task<EmailVerificationResponseEnvelope, Error>
  }

  private var verificationTail: Verification?
  private var verificationWrites: [UUID: Task<EmailVerificationResponseEnvelope, Error>] = [:]
  private var editRevision = 0
  let applicationSettings: ApplicationSettings?
  public var sessionFeature: SessionFeature { self.session }
  public private(set) var lastError: Error?

  public init(
    sessionFeature: SessionFeature,
    applicationSettings: ApplicationSettings? = nil,
    hasStoredCredentials: @escaping @MainActor () -> Bool = { false },
    applicationVersion: @escaping @MainActor () -> String = { "" },
    identifyUser: @escaping @MainActor (User) -> Void = { _ in },
    events: Events = .none,
    makeProvider: @escaping () -> any AccountPreferencesProvider
  ) {
    self.session = sessionFeature
    self.applicationSettings = applicationSettings
    self.hasStoredCredentials = hasStoredCredentials
    self.applicationVersion = applicationVersion
    self.identifyUser = identifyUser
    self.events = events
    self.makeProvider = makeProvider
  }

  public var appVersionString: String { self.applicationVersion() }

  public func identifyUpdatedUser(_ user: User) {
    self.identifyUser(user)
  }


  func scheduleAccountRefresh(onResult: @escaping @MainActor (Result<User?, Error>) -> Void) {
    self.accountRefreshDebounceTask?.cancel()
    let generation = self.session.generation
    self.accountRefreshDebounceTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(5))
        try Task.checkCancellation()
        guard let self, self.session.generation == generation else { return }
        self.beginAccountRefresh(onResult: onResult)
      } catch { /* A newer event superseded this debounce. */ }
    }
  }

  private func beginAccountRefresh(onResult: @escaping @MainActor (Result<User?, Error>) -> Void) {
    self.activeAccountRefreshTask?.cancel()
    let authenticated = self.hasStoredCredentials()
    let userID = self.session.currentUser?.id
    guard authenticated || userID != nil else {
      onResult(.success(nil))
      return
    }
    let generation = self.session.generation
    self.activeAccountRefreshTask = Task { [weak self] in
      guard let self else { return }
      do {
        let user = try await self.performAccountRefresh(
          userID: userID, generation: generation, allowSessionRestore: authenticated
        )
        try Task.checkCancellation()
        guard self.session.isCurrent(userID: user.id, generation: generation) else { return }
        onResult(.success(user))
      } catch {
        guard !Task.isCancelled, !(error is CancellationError),
              self.session.isCurrent(userID: userID, generation: generation) else { return }
        onResult(.failure(error))
      }
    }
  }

  func cancelScheduledAccountRefresh() {
    self.accountRefreshDebounceTask?.cancel()
    self.activeAccountRefreshTask?.cancel()
  }

  func waitForScheduledAccountRefresh() async {
    await self.accountRefreshDebounceTask?.value
    await self.activeAccountRefreshTask?.value
  }

  public func savePreferences(_ changes: [Change], from user: User) async throws -> User {
    try Task.checkCancellation()
    // Once admitted, a preference write outlives its initiating screen/waiter.
    let value = try await self.startPreferencesSave(changes, from: user).value
    try Task.checkCancellation()
    return value
  }

  /// Admit preferences immediately so callers can retain a waiter without owning the write.
  @discardableResult
  public func startPreferencesSave(_ changes: [Change], from user: User) -> Task<User, Error> {
    self.queuePreferenceEdits(changes, from: user).task
  }

  /// Notification URLs carry wire names. Convert only the requested field into
  /// an edit; never enqueue the whole user snapshot supplied by a deep link.
  @discardableResult
  public func startNotificationPreferenceSave(named parameter: String, enabled: Bool) -> Task<User, Error>? {
    guard let user = self.session.currentUser else { return nil }
    let names: [String: UserAttribute.Notification] = [
      "notify_of_backings": .pledgeActivity,
      "notify_of_comment_replies": .commentReplies,
      "notify_of_comments": .comments,
      "notify_of_creator_digest": .creatorDigest,
      "notify_of_creator_edu": .creatorTips,
      "notify_of_follower": .follower,
      "notify_of_friend_activity": .friendActivity,
      "notify_of_messages": .messages,
      "notify_mobile_of_backings": .mobilePledgeActivity,
      "notify_mobile_of_comments": .mobileComments,
      "notify_mobile_of_follower": .mobileFollower,
      "notify_mobile_of_friend_activity": .mobileFriendActivity,
      "notify_mobile_of_marketing_update": .mobileMarketingUpdate,
      "notify_mobile_of_messages": .mobileMessages,
      "notify_mobile_of_post_likes": .mobilePostLikes,
      "notify_mobile_of_updates": .mobileUpdates,
      "notify_of_post_likes": .postLikes,
      "notify_of_updates": .updates
    ]
    // Legacy decoding ignored unknown keys but still saved the unchanged user.
    let changes = names[parameter].map { [Change(.notification($0), enabled)] } ?? []
    return self.startPreferencesSave(changes, from: user)
  }

  private func identity(for user: User) -> Account {
    Account(id: self.session.currentUser?.id, generation: self.session.generation, sourceID: user.id)
  }

  private func isCurrent(_ account: Account) -> Bool {
    self.session.isCurrent(userID: account.id, generation: account.generation)
      && account.id == account.sourceID
  }

  private func preferences(of user: User) -> [Change] {
    Self.attributes.map { Change($0, user[keyPath: $0.keyPath]) }
  }

  private func applying(_ changes: [Change], to user: User) -> User {
    var user = user
    for change in changes { user[keyPath: change.path] = change.value }
    return user
  }

  private func queuePreferenceEdits(_ changes: [Change], from source: User) -> Pending {
    self.queueAccountEdit(.preferences(changes), from: source)
  }

  private func queueAccountEdit(_ edit: Edit, from source: User) -> Pending {
    let account = self.identity(for: source)
    let valid = self.isCurrent(account)
    if valid, self.account != account {
      self.account = account
      self.latestQueuedAccountWrite = nil
      self.lastError = nil
    }
    // Share only the equivalent tail: on/off/on must still execute in order.
    if valid, let tail = self.latestQueuedAccountWrite, tail.account == account, tail.edit == edit { return tail }
    let previous = valid ? self.latestQueuedAccountWrite?.task : nil
    let provider = self.makeProvider()
    let id = UUID()
    if valid {
      self.editRevision += 1
      self.session.invalidateAccountReads()
    }
    let task = Task { [self] in
      if let previous { _ = await previous.result }
      let result: Result<User, Error>
      do {
        guard self.isCurrent(account) else { throw CancellationError() }
        let base = self.session.currentUser ?? source
        let current: User
        switch edit {
        case let .preferences(changes):
          let response = try await provider.saveAccountPreferences(self.applying(changes, to: base))
          guard self.isCurrent(account), response.id == source.id else { throw CancellationError() }
          current = self.applying(self.preferences(of: response), to: self.session.currentUser ?? response)
        case let .account(change):
          let response = try await provider.updateAccount(change)
          guard self.isCurrent(account), response == nil || response?.id == source.id,
                var latest = self.session.currentUser else { throw CancellationError() }
          // Update only confirmed account fields, not a stale server copy of preferences.
          switch change {
          case let .currency(currency): latest.chosenCurrency = currency
          case .initialPassword: latest.needsPassword = false
          case .facebook:
            latest.facebookConnected = response?.facebookConnected
            latest.needsFreshFacebookToken = response?.needsFreshFacebookToken
          case .email, .password, .sendVerification: break
          }
          current = latest
        }
        self.session.commitUser(current, userID: account.id, generation: account.generation)
        self.session.invalidateAccountReads()
        if case .account(.currency(_)) = edit { self.events.localePreferencesChanged() }
        self.lastError = nil
        result = .success(current)
      } catch {
        if self.isCurrent(account), !(error is CancellationError) { self.lastError = error }
        result = .failure(self.isCurrent(account) ? error : CancellationError())
      }
      self.accountWriteTasks[id] = nil
      if self.latestQueuedAccountWrite?.id == id { self.latestQueuedAccountWrite = nil }
      return try result.get()
    }
    let pending = Pending(id: id, account: account, edit: edit, task: task)
    if valid { self.latestQueuedAccountWrite = pending }
    self.accountWriteTasks[id] = task
    return pending
  }

  /// Admit the write synchronously so equivalent requests share and distinct
  /// requests enter the account queue in caller order. The feature owns the task.
  @discardableResult
  public func startAccountUpdate(_ change: AccountChange) throws -> Task<User, Error> {
    try Task.checkCancellation()
    guard let user = self.session.currentUser else { throw CancellationError() }
    return self.queueAccountEdit(.account(change), from: user).task
  }

  public func updateAccount(_ change: AccountChange) async throws -> User {
    let result = try await self.startAccountUpdate(change).value
    try Task.checkCancellation()
    return result
  }

  /// Verification links carry their own token and may be opened while signed out.
  /// They do not establish a login. Distinct links queue; equivalent tails share.
  public func verifyEmail(token: String) async throws -> EmailVerificationResponseEnvelope {
    try Task.checkCancellation()
    let task = self.startEmailVerification(token: token)
    let envelope = try await task.value
    try Task.checkCancellation()
    return envelope
  }

  @discardableResult
  public func startEmailVerification(token: String) -> Task<EmailVerificationResponseEnvelope, Error> {
    let userID = self.session.currentUser?.id
    let generation = self.session.generation
    if let tail = self.verificationTail, tail.token == token,
       tail.userID == userID, tail.generation == generation { return tail.task }
    let previous = self.verificationTail?.task
    let provider = self.makeProvider()
    let id = UUID()
    let task = Task { [self] in
      defer {
        self.verificationWrites[id] = nil
        if self.verificationTail?.id == id { self.verificationTail = nil }
      }
      if let previous { _ = await previous.result }
      do {
        guard self.session.isCurrent(userID: userID, generation: generation)
        else { throw CancellationError() }
        let envelope = try await provider.verifyEmail(token: token)
        guard self.session.isCurrent(userID: userID, generation: generation)
        else { throw CancellationError() }
        self.session.invalidateAccountReads()
        return envelope
      } catch {
        guard self.session.isCurrent(userID: userID, generation: generation)
        else { throw CancellationError() }
        throw error
      }
    }
    self.verificationTail = Verification(
      id: id,
      token: token,
      userID: userID,
      generation: generation,
      task: task
    )
    self.verificationWrites[id] = task
    return task
  }

  func refreshAccountSetup(onEmailAvailable: @escaping @MainActor () -> Void) {
    self.cancelAccountSetupRefresh()
    let userID = self.session.currentUser?.id
    let generation = self.session.generation
    let id = UUID()
    let task = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.accountSetupRefreshRequest?.id == id { self.accountSetupRefreshRequest = nil }
      }
      do {
        while let previous = self.latestQueuedAccountWrite?.task { _ = await previous.result }
        try Task.checkCancellation()
        guard self.session.isCurrent(userID: userID, generation: generation) else { return }
        let setup = try await self.session.refreshGraphUserSetup()
        try Task.checkCancellation()
        if setup.email != nil { onEmailAvailable() }
      } catch { /* Setup failures remain silent. */ }
    }
    self.accountSetupRefreshRequest = (id, task)
  }

  func cancelAccountSetupRefresh() {
    self.accountSetupRefreshRequest?.task.cancel()
  }

  public func loadEmailUser() async throws -> GraphUser {
    try await self.fetchEmailUserForCurrentSession()
  }

  private func fetchEmailUserForCurrentSession(
    beforeDelivery: (@MainActor () async throws -> Void)? = nil
  ) async throws -> GraphUser {
    let generation = self.session.generation
    let userID = self.session.currentUser?.id
    while let previous = self.latestQueuedAccountWrite?.task { _ = await previous.result }
    let revision = self.session.userReadGeneration
    try Task.checkCancellation()
    guard self.session.isCurrent(userID: userID, generation: generation) else { throw CancellationError() }
    let task: Task<GraphUser, Error>
    if let existing = self.pendingEmailUserRead, existing.userID == userID,
       existing.generation == generation, existing.revision == revision {
      task = existing.task
    } else {
      self.pendingEmailUserRead?.task.cancel()
      let id = UUID()
      let provider = self.makeProvider()
      task = Task { [self] in
        defer { if self.pendingEmailUserRead?.id == id { self.pendingEmailUserRead = nil } }
        return try await provider.fetchEmailUser()
      }
      self.pendingEmailUserRead = (id, userID, generation, revision, task)
    }
    func requireCurrentRead() throws {
      try Task.checkCancellation()
      guard revision == self.session.userReadGeneration,
            self.session.isCurrent(userID: userID, generation: generation)
      else { throw CancellationError() }
    }

    let result = await task.result
    try requireCurrentRead()
    if let beforeDelivery {
      if case let .failure(error) = result, error is CancellationError { throw error }
      try await beforeDelivery()
      try requireCurrentRead()
    }
    return try result.get()
  }

  public func loadAccountFields() async throws -> GraphUser {
    try await self.fetchEmailUserForCurrentSession()
  }

  /// Start a session-bound refresh immediately; the caller may cancel this read.
  @discardableResult
  public func startAccountRefresh(allowSessionRestore: Bool = false) -> Task<User, Error> {
    let id = UUID()
    let generation = self.session.generation
    let userID = self.session.currentUser?.id
    let task = Task { [self] in
      defer { self.accountRefreshTasks[id] = nil }
      return try await self.performAccountRefresh(userID: userID, generation: generation, allowSessionRestore: allowSessionRestore)
    }
    self.accountRefreshTasks[id] = task
    return task
  }

  public func refreshAccount() async throws -> User {
    try await self.performAccountRefresh(userID: self.session.currentUser?.id, generation: self.session.generation)
  }

  private func performAccountRefresh(
    userID: Int?,
    generation: Int,
    allowSessionRestore: Bool = false
  ) async throws -> User {
    while let previous = self.latestQueuedAccountWrite?.task { _ = await previous.result }
    let revision = self.editRevision
    try Task.checkCancellation()
    guard self.session.isCurrent(userID: userID, generation: generation)
    else { throw CancellationError() }
    let userReadGeneration = self.session.userReadGeneration
    do {
      let user = try await self.session.refreshCurrentUser()
      try Task.checkCancellation()
      guard revision == self.editRevision, userReadGeneration == self.session.userReadGeneration,
            self.session.isCurrent(userID: userID, generation: generation),
            userID == nil || user.id == userID else { throw CancellationError() }
      self.account = self.identity(for: user)
      self.session.commitRefreshedUser(
        user,
        userID: userID,
        generation: generation,
        allowSessionRestore: allowSessionRestore
      )
      return user
    } catch {
      guard !Task.isCancelled, revision == self.editRevision,
            userReadGeneration == self.session.userReadGeneration,
            self.session.isCurrent(userID: userID, generation: generation)
      else { throw CancellationError() }
      throw error
    }
  }

  // MARK: Project notification settings

  public func loadProjectNotifications() async throws -> [ProjectNotification] {
    let userID = self.session.currentUser?.id
    let generation = self.session.generation
    guard userID != nil else { throw CancellationError() }
    // A fresh list cannot overtake an admitted setting edit.
    while !self.notificationWrites.isEmpty {
      for task in Array(self.notificationWrites.values) { _ = await task.result }
    }
    let revision = self.notificationWriteRevision
    try Task.checkCancellation()
    guard self.session.isCurrent(userID: userID, generation: generation) else { throw CancellationError() }
    let provider = self.makeProvider()
    do {
      let values = try await provider.fetchProjectNotifications()
      try Task.checkCancellation()
      guard revision == self.notificationWriteRevision,
            self.session.isCurrent(userID: userID, generation: generation) else { throw CancellationError() }
      return values
    } catch {
      guard !Task.isCancelled, revision == self.notificationWriteRevision,
            self.session.isCurrent(userID: userID, generation: generation) else { throw CancellationError() }
      throw error
    }
  }

  public func saveProjectNotification(_ notification: ProjectNotification) async throws -> ProjectNotification {
    try Task.checkCancellation()
    let pending = try self.queueProjectNotificationWrite(notification)
    let result = try await pending.task.value
    try Task.checkCancellation()
    guard self.session.isCurrent(userID: pending.userID, generation: pending.generation)
    else { throw CancellationError() }
    return result
  }

  private func queueProjectNotificationWrite(_ notification: ProjectNotification) throws -> NotificationWrite {
    guard let userID = self.session.currentUser?.id else { throw CancellationError() }
    let generation = self.session.generation
    let tail = self.latestNotificationWriteByID[notification.id]
    let sameSession = tail?.userID == userID && tail?.generation == generation
    if sameSession, let tail, tail.email == notification.email, tail.mobile == notification.mobile {
      return tail
    }
    let previous = sameSession ? tail?.task : nil
    let id = UUID()
    let provider = self.makeProvider()
    self.notificationWriteRevision += 1
    let task = Task { [self] in
      if let previous { _ = await previous.result }
      let result: Result<ProjectNotification, Error>
      do {
        guard self.session.isCurrent(userID: userID, generation: generation) else { throw CancellationError() }
        let saved = try await provider.saveProjectNotification(notification)
        guard self.session.isCurrent(userID: userID, generation: generation), saved.id == notification.id
        else { throw CancellationError() }
        if self.projectNotificationCacheSession?.userID != userID
          || self.projectNotificationCacheSession?.generation != generation {
          self.confirmedProjectNotifications.removeAllObjects()
          self.projectNotificationCacheSession = (userID, generation)
        }
        self.confirmedProjectNotifications.setObject(
          NSNumber(value: saved.email && saved.mobile), forKey: NSNumber(value: saved.id)
        )
        result = .success(saved)
      } catch {
        result = .failure(self.session.isCurrent(userID: userID, generation: generation)
          ? error : CancellationError())
      }
      self.notificationWrites[id] = nil
      if self.latestNotificationWriteByID[notification.id]?.id == id { self.latestNotificationWriteByID[notification.id] = nil }
      return try result.get()
    }
    let pending = NotificationWrite(
      id: id, userID: userID, generation: generation,
      email: notification.email, mobile: notification.mobile, task: task
    )
    self.latestNotificationWriteByID[notification.id] = pending
    self.notificationWrites[id] = task
    return pending
  }

  public func cachedProjectNotification(_ notification: ProjectNotification) -> ProjectNotification {
    guard let owner = self.projectNotificationCacheSession,
          self.session.isCurrent(userID: owner.userID, generation: owner.generation),
          let cached = self.confirmedProjectNotifications.object(forKey: NSNumber(value: notification.id))
    else { return notification }
    let on = cached.boolValue
    return notification |> ProjectNotification.lens.email .~ on |> ProjectNotification.lens.mobile .~ on
  }

  /// Admits an ordered write synchronously. Canceling a screen's observer does not cancel it.
  func startProjectNotificationSave(_ notification: ProjectNotification) throws -> Task<ProjectNotification, Error> {
    try self.queueProjectNotificationWrite(notification).task
  }

  /// Waits for owned executions, not presentation scheduler delays.
  func waitForSettingsOperations() async {
    while !self.accountRefreshTasks.isEmpty || self.accountSetupRefreshRequest != nil || !self.accountWriteTasks.isEmpty || !self.verificationWrites.isEmpty || self
      .pendingEmailUserRead != nil || !self.notificationWrites.isEmpty {
      for task in Array(self.notificationWrites.values) { _ = await task.result }
      await self.accountSetupRefreshRequest?.task.value
      let reads = Array(self.accountRefreshTasks.values)
      let writes = Array(self.accountWriteTasks.values)
      let verifications = Array(self.verificationWrites.values)
      for verification in verifications { _ = await verification.result }
      if let task = self.pendingEmailUserRead?.task { _ = await task.result }
      for read in reads { _ = await read.result }
      for write in writes { _ = await write.result }
    }
  }
}
