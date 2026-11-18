import Foundation
import KsApi

@MainActor
public protocol MessagingProvider {
  func page(mailbox: Mailbox, project: Project?, cursor: String?) async throws -> MessageThreadsEnvelope
  func search(query: String, project: Project?) async throws -> MessageThreadsEnvelope
  func thread(id: Int) async throws -> MessageThreadEnvelope
  func thread(backing: Backing) async throws -> MessageThreadEnvelope?
  func backing(id: Int) async throws -> Backing
  func backing(project: Project, user: User) async throws -> Backing
  func markRead(_ thread: MessageThread) async throws -> MessageThread
  func send(body: String, subject: MessageSubject) async throws -> Message
}

@MainActor
public struct AsyncMessagingProvider: MessagingProvider {
  private let service: any ServiceType
  public init(service: any ServiceType) { self.service = service }
  public func page(mailbox: Mailbox, project: Project?, cursor: String?) async throws -> MessageThreadsEnvelope {
    try await self.service.messageThreadsPage(mailbox: mailbox, project: project, cursor: cursor)
  }
  public func search(query: String, project: Project?) async throws -> MessageThreadsEnvelope {
    try await self.service.messageSearch(query: query, project: project)
  }
  public func thread(id: Int) async throws -> MessageThreadEnvelope {
    try await self.service.messageThread(id: id)
  }
  public func thread(backing: Backing) async throws -> MessageThreadEnvelope? {
    try await self.service.messageThread(backing: backing)
  }
  public func backing(id: Int) async throws -> Backing {
    try await self.service.projectDetailsBacking(id: id).backing
  }
  public func backing(project: Project, user: User) async throws -> Backing {
    try await self.service.messageBacking(project: project, user: user)
  }
  public func markRead(_ thread: MessageThread) async throws -> MessageThread {
    try await self.service.readMessageThread(thread)
  }
  public func send(body: String, subject: MessageSubject) async throws -> Message {
    try await self.service.submitMessage(body: body, subject: subject)
  }
}

/// Owns mailbox history, screen reads, and admitted message mutations.
@MainActor
public final class MessagingFeature {
  public let sessionFeature: SessionFeature
  private let makeProvider: () -> any MessagingProvider
  private let responseDelaySeconds: @MainActor () -> TimeInterval
  private let sleep: (TimeInterval) async throws -> Void
  private struct Session: Hashable {
    let userID: Int?
    let generation: Int
  }
  private var session: Session {
    Session(userID: self.sessionFeature.currentUser?.id, generation: self.sessionFeature.generation)
  }
  private func ensureMessagingSessionIsCurrent(_ session: Session) throws {
    try Task.checkCancellation()
    guard self.session == session else { throw CancellationError() }
  }

  public init(
    sessionFeature: SessionFeature, makeProvider: @escaping () -> any MessagingProvider,
    responseDelaySeconds: @escaping @MainActor () -> TimeInterval,
    sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
      if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
    }
  ) {
    self.sessionFeature = sessionFeature
    self.makeProvider = makeProvider
    self.responseDelaySeconds = responseDelaySeconds
    self.sleep = sleep
  }

  public struct MailboxSnapshot {
    public fileprivate(set) var threads: [MessageThread] = []
    public fileprivate(set) var isLoading = false
    public fileprivate(set) var error: ErrorEnvelope?
  }
  private final class MailboxRoute {
    let mailbox: Mailbox
    let project: Project?
    let session: Session
    var snapshot = MailboxSnapshot()
    var cursor: String?
    var request: (id: UUID, task: Task<Void, Never>)?
    init(mailbox: Mailbox, project: Project?, session: Session) {
      self.mailbox = mailbox; self.project = project; self.session = session
    }
  }
  private var mailboxStatesByRoute: [UUID: MailboxRoute] = [:]
  public func snapshot(route: UUID) -> MailboxSnapshot { self.mailboxStatesByRoute[route]?.snapshot ?? MailboxSnapshot() }

  @discardableResult
  public func requestMailbox(
    route: UUID, mailbox: Mailbox, project: Project?, refresh: Bool = false
  ) -> Task<Void, Never> {
    if !refresh, let existing = self.mailboxStatesByRoute[route], existing.mailbox == mailbox,
       existing.project?.id == project?.id, existing.session == self.session,
       let request = existing.request { return request.task }
    let previous = self.mailboxStatesByRoute[route]
    previous?.request?.task.cancel()
    let state = MailboxRoute(mailbox: mailbox, project: project, session: self.session)
    self.mailboxStatesByRoute[route] = state
    return self.startPage(route: route, state: state, cursor: nil)
  }

  @discardableResult
  public func requestNextPage(route: UUID) -> Task<Void, Never>? {
    guard let state = self.mailboxStatesByRoute[route], state.session == self.session else { return nil }
    if let request = state.request { return request.task }
    guard let cursor = state.cursor else { return nil }
    return self.startPage(route: route, state: state, cursor: cursor)
  }

  private func startPage(route: UUID, state: MailboxRoute, cursor: String?) -> Task<Void, Never> {
    let id = UUID()
    let provider = self.makeProvider()
    let delay = self.responseDelaySeconds()
    state.snapshot.isLoading = true
    state.snapshot.error = nil
    let task = Task { [weak self, sleep] in
      guard let self else { return }
      defer {
        if self.mailboxStatesByRoute[route]?.request?.id == id {
          state.request = nil
          state.snapshot.isLoading = false
        }
      }
      do {
        try self.ensureMessagingSessionIsCurrent(state.session)
        let envelope = try await provider.page(mailbox: state.mailbox, project: state.project, cursor: cursor)
        try await sleep(delay)
        try self.ensureMessagingSessionIsCurrent(state.session)
        guard self.mailboxStatesByRoute[route]?.request?.id == id else { return }
        // Preserve the original concatenation and empty-page sentinel.
        state.cursor = envelope.messageThreads.isEmpty ? nil : envelope.urls.api.moreMessageThreads
        state.snapshot.threads += envelope.messageThreads
      } catch {
        guard !Task.isCancelled, self.session == state.session,
              self.mailboxStatesByRoute[route]?.request?.id == id else { return }
        state.snapshot.error = (error as? ErrorEnvelope) ?? .couldNotParseJSON
      }
    }
    state.request = (id, task)
    return task
  }

  public func release(route: UUID) {
    self.mailboxStatesByRoute.removeValue(forKey: route)?.request?.task.cancel()
  }

  public func reset() {
    for route in self.mailboxStatesByRoute.values { route.request?.task.cancel() }
    self.mailboxStatesByRoute = [:]
  }

  public func searchMessageThreads(query: String, project: Project?) async throws -> [MessageThread] {
    guard !query.isEmpty else { return [] }
    let session = self.session
    try self.ensureMessagingSessionIsCurrent(session)
    let value = try await self.makeProvider().search(query: query, project: project)
    try self.ensureMessagingSessionIsCurrent(session)
    return value.messageThreads
  }

  public func thread(id: Int) async throws -> MessageThreadEnvelope? {
    let session = self.session
    try self.ensureMessagingSessionIsCurrent(session)
    let value = try await self.makeProvider().thread(id: id)
    try self.ensureMessagingSessionIsCurrent(session)
    return value
  }

  public func thread(backing: Backing) async throws -> MessageThreadEnvelope? {
    let session = self.session
    try self.ensureMessagingSessionIsCurrent(session)
    let value = try await self.makeProvider().thread(backing: backing)
    try self.ensureMessagingSessionIsCurrent(session)
    return value
  }

  public func backing(id: Int?, project: Project, user: User) async throws -> Backing {
    let session = self.session
    try self.ensureMessagingSessionIsCurrent(session)
    let provider = self.makeProvider()
    let value: Backing
    if let id { value = try await provider.backing(id: id) }
    else { value = try await provider.backing(project: project, user: user) }
    try self.ensureMessagingSessionIsCurrent(session)
    return value
  }

  private struct Destination: Hashable { let id: Int; let isThread: Bool; let session: Session }
  private struct Send {
    let id: UUID
    let body: String
    let task: Task<Message, Error>
  }
  private var sends: [Destination: Send] = [:]
  private var sendTasks: [UUID: Task<Message, Error>] = [:]
  private struct ReadIdentity: Hashable { let threadID: Int; let session: Session }
  private var readWrites: [ReadIdentity: Task<MessageThread, Error>] = [:]

  /// Equivalent pending submissions share the tail command. Distinct bodies
  /// queue in order per destination; failure never retries or blocks the next.
  @discardableResult
  public func requestSend(body: String, subject: MessageSubject) -> Task<Message, Error> {
    let destination: Destination
    switch subject {
    case let .messageThread(thread):
      destination = Destination(id: thread.id, isThread: true, session: self.session)
    case let .project(id, _):
      destination = Destination(id: id, isThread: false, session: self.session)
    }
    let previous = self.sends[destination]
    if let previous, previous.body == body { return previous.task }
    let id = UUID()
    let provider = self.makeProvider()
    let task = Task { [self] in
      defer {
        self.sendTasks[id] = nil
        if self.sends[destination]?.id == id { self.sends[destination] = nil }
      }
      if let previous { _ = await previous.task.result }
      try self.ensureMessagingSessionIsCurrent(destination.session)
      do {
        let message = try await provider.send(body: body, subject: subject)
        try self.ensureMessagingSessionIsCurrent(destination.session)
        return message
      } catch {
        try self.ensureMessagingSessionIsCurrent(destination.session)
        throw error
      }
    }
    self.sends[destination] = Send(id: id, body: body, task: task)
    self.sendTasks[id] = task
    return task
  }

  public func send(body: String, subject: MessageSubject) async throws -> Message {
    try Task.checkCancellation()
    let value = try await self.requestSend(body: body, subject: subject).value
    try Task.checkCancellation()
    return value
  }

  @discardableResult
  public func requestMarkRead(_ thread: MessageThread) -> Task<MessageThread, Error> {
    let key = ReadIdentity(threadID: thread.id, session: self.session)
    if let task = self.readWrites[key] { return task }
    let provider = self.makeProvider()
    let task = Task { [self] in
      defer { self.readWrites[key] = nil }
      try self.ensureMessagingSessionIsCurrent(key.session)
      do {
        let value = try await provider.markRead(thread)
        try self.ensureMessagingSessionIsCurrent(key.session)
        return value
      } catch {
        try self.ensureMessagingSessionIsCurrent(key.session)
        throw error
      }
    }
    self.readWrites[key] = task
    return task
  }

  public func waitForOperations() async {
    while !self.sendTasks.isEmpty || !self.readWrites.isEmpty
      || self.mailboxStatesByRoute.values.contains(where: { $0.request != nil }) {
      for route in Array(self.mailboxStatesByRoute.values) { await route.request?.task.value }
      for task in Array(self.sendTasks.values) { _ = await task.result }
      for task in Array(self.readWrites.values) { _ = await task.result }
      await Task.yield()
    }
  }
}
