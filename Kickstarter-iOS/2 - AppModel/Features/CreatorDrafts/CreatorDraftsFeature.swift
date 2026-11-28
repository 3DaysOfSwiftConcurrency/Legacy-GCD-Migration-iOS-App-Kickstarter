import Foundation
import KsApi
import Prelude

@MainActor
public protocol CreatorDraftsProvider {
  func fetchDraft(project: Project) async throws -> UpdateDraft
  func saveDraft(draft: UpdateDraft, title: String, body: String, isPublic: Bool) async throws -> UpdateDraft
  func uploadDraftImage(file: URL, draft: UpdateDraft) async throws -> UpdateDraft.Image
  func removeDraftImage(image: UpdateDraft.Image, draft: UpdateDraft) async throws -> UpdateDraft.Image
}

@MainActor
public struct AsyncCreatorDraftsProvider: CreatorDraftsProvider {
  private let service: any ServiceType
  public init(service: any ServiceType) { self.service = service }
  public func fetchDraft(project: Project) async throws -> UpdateDraft { try await self.service.creatorDraft(project: project) }
  public func saveDraft(draft: UpdateDraft, title: String, body: String, isPublic: Bool) async throws -> UpdateDraft {
    try await self.service.saveCreatorDraft(draft, title: title, body: body, isPublic: isPublic)
  }
  public func uploadDraftImage(file: URL, draft: UpdateDraft) async throws -> UpdateDraft.Image {
    try await self.service.addCreatorDraftImage(file: file, draft: draft)
  }
  public func removeDraftImage(image: UpdateDraft.Image, draft: UpdateDraft) async throws -> UpdateDraft.Image {
    try await self.service.removeCreatorDraftImage(image, draft: draft)
  }
}

/// The server remains the durable draft store. This Feature coordinates draft reads
/// and ordered edits; abandoning observation cannot undo an admitted edit.
@MainActor
public final class CreatorDraftsFeature {
  private struct Key: Hashable {
    let projectID: Int
    let userID: Int?
    let generation: Int
  }
  private final class Route {
    let key: Key
    var read: (id: UUID, revision: Int, task: Task<Void, Never>)?
    init(key: Key) { self.key = key }
  }
  private enum Command: Equatable {
    case save(title: String, body: String, isPublic: Bool)
    case add(URL)
    case remove(Int)
  }
  private enum Outcome: Sendable {
    case saved(UpdateDraft)
    case image(UpdateDraft.Image)
  }
  private struct Pending {
    let id: UUID
    let command: Command
    let draftID: Int
    let task: Task<Outcome, Error>
  }
  public let sessionFeature: SessionFeature
  private let makeProvider: () -> any CreatorDraftsProvider
  private var routes: [UUID: Route] = [:]
  private var cachedDraftsByKey: [Key: UpdateDraft] = [:]
  private var editVersionsByDraft: [Key: Int] = [:]
  private var latestQueuedEditsByDraft: [Key: Pending] = [:]
  private var draftEditTasks: [UUID: Task<Outcome, Error>] = [:]
  private var draftLoadTasks: [UUID: Task<Void, Never>] = [:]
  public enum Event {
    case load(Result<UpdateDraft, ErrorEnvelope>)
    case attachments([UpdateDraft.Attachment])
  }
  private var draftEventListenersByRoute: [UUID: @MainActor (Event) -> Void] = [:]

  public func observe(route: UUID, onEvent: @escaping @MainActor (Event) -> Void) {
    self.draftEventListenersByRoute[route] = onEvent
  }

  public init(
    sessionFeature: SessionFeature, makeProvider: @escaping () -> any CreatorDraftsProvider
  ) {
    self.sessionFeature = sessionFeature
    self.makeProvider = makeProvider
  }
  private func isCurrent(_ key: Key) -> Bool {
    self.sessionFeature.isCurrent(userID: key.userID, generation: key.generation)
  }
  private func ensureDraftSessionIsCurrent(_ key: Key) throws {
    try Task.checkCancellation()
    guard self.isCurrent(key) else { throw CancellationError() }
  }
  public func release(route: UUID) {
    self.routes.removeValue(forKey: route)?.read?.task.cancel()
    self.draftEventListenersByRoute[route] = nil
  }
  public func resetForSessionChange() {
    for state in self.routes.values { state.read?.task.cancel() }
    self.routes.removeAll()
    self.cachedDraftsByKey.removeAll()
    self.editVersionsByDraft.removeAll()
  }
  public func loadDraft(project: Project, route: UUID) async { await self.startDraftLoad(project: project, route: route).value }

  @discardableResult
  public func startDraftLoad(project: Project, route: UUID) -> Task<Void, Never> {
    let key = Key(projectID: project.id, userID: self.sessionFeature.currentUser?.id, generation: self.sessionFeature.generation)
    let revision = self.editVersionsByDraft[key, default: 0]
    if let state = self.routes[route], state.key == key, let read = state.read, read.revision == revision {
      return read.task
    }
    self.routes.removeValue(forKey: route)?.read?.task.cancel()
    let state = Route(key: key)
    self.routes[route] = state
    let id = UUID()
    let provider = self.makeProvider()
    let predecessor = self.latestQueuedEditsByDraft[key]?.task
    let task = Task { [self] in
      defer { self.draftLoadTasks[id] = nil; if state.read?.id == id { state.read = nil } }
      do {
        if let predecessor { _ = await predecessor.result }
        try self.ensureDraftSessionIsCurrent(key)
        let draft = try await provider.fetchDraft(project: project)
        try self.ensureDraftSessionIsCurrent(key)
        guard self.routes[route] === state, self.editVersionsByDraft[key, default: 0] == revision else { return }
        self.cachedDraftsByKey[key] = draft
        self.draftEventListenersByRoute[route]?(.load(.success(draft)))
        self.publishAttachments(key: key)
      } catch {
        guard !Task.isCancelled, !(error is CancellationError), self.isCurrent(key),
              self.routes[route] === state, self.editVersionsByDraft[key, default: 0] == revision else { return }
        self.draftEventListenersByRoute[route]?(.load(.failure((error as? ErrorEnvelope) ?? .couldNotParseJSON)))
      }
    }
    state.read = (id, revision, task)
    self.draftLoadTasks[id] = task
    return task
  }

  public func saveDraft(route: UUID, title: String, body: String, isPublic: Bool) async throws -> UpdateDraft {
    let value = try await self.performDraftEdit(.save(title: title, body: body, isPublic: isPublic), route: route)
    guard case .saved(let draft) = value else { throw ErrorEnvelope.couldNotParseJSON }
    return draft
  }
  public func uploadDraftImage(file: URL, route: UUID) async throws -> UpdateDraft.Image {
    let value = try await self.performDraftEdit(.add(file), route: route)
    guard case .image(let image) = value else { throw ErrorEnvelope.couldNotParseJSON }
    return image
  }
  public func removeDraftImage(imageID: Int, route: UUID) async throws -> UpdateDraft.Image {
    let value = try await self.performDraftEdit(.remove(imageID), route: route)
    guard case .image(let image) = value else { throw ErrorEnvelope.couldNotParseJSON }
    return image
  }
  private func performDraftEdit(_ command: Command, route: UUID) async throws -> Outcome {
    try Task.checkCancellation()
    guard let state = self.routes[route] else { throw CancellationError() }
    do {
      let value = try await self.startDraftEdit(command, state: state).value
      try self.ensureDraftSessionIsCurrent(state.key)
      guard self.routes[route] === state else { throw CancellationError() }
      return value
    } catch {
      try self.ensureDraftSessionIsCurrent(state.key)
      guard self.routes[route] === state else { throw CancellationError() }
      throw error
    }
  }

  private func startDraftEdit(_ command: Command, state: Route) throws -> Task<Outcome, Error> {
    let key = state.key
    try self.ensureDraftSessionIsCurrent(key)
    guard let admittedDraft = self.cachedDraftsByKey[key] else { throw ErrorEnvelope.couldNotParseJSON }
    let previous = self.latestQueuedEditsByDraft[key]
    if let previous, previous.command == command, previous.draftID == admittedDraft.update.id { return previous.task }
    let id = UUID()
    let provider = self.makeProvider()
    self.editVersionsByDraft[key, default: 0] += 1
    let task = Task { [self] in
      defer { self.draftEditTasks[id] = nil; if self.latestQueuedEditsByDraft[key]?.id == id { self.latestQueuedEditsByDraft[key] = nil } }
      if let previous { _ = await previous.task.result }
      try self.ensureDraftSessionIsCurrent(key)
      guard var draft = self.cachedDraftsByKey[key], draft.update.id == admittedDraft.update.id else { throw CancellationError() }
      let outcome: Outcome
      do {
        switch command {
        case let .save(title, body, isPublic):
          if draft.update.title != title || draft.update.body != body || draft.update.isPublic != isPublic {
            draft = try await provider.saveDraft(draft: draft, title: title, body: body, isPublic: isPublic)
          }
          outcome = .saved(draft)
        case .add(let file):
          let image = try await provider.uploadDraftImage(file: file, draft: draft)
          draft = draft |> UpdateDraft.lens.images .~ (draft.images.filter { $0.id != image.id } + [image])
          outcome = .image(image)
        case .remove(let id):
          guard let image = draft.images.first(where: { $0.id == id }) else { throw ErrorEnvelope.couldNotParseJSON }
          let removed = try await provider.removeDraftImage(image: image, draft: draft)
          draft = draft |> UpdateDraft.lens.images .~ draft.images.filter { $0.id != removed.id }
          outcome = .image(removed)
        }
        try self.ensureDraftSessionIsCurrent(key)
        self.cachedDraftsByKey[key] = draft
        try self.ensureDraftSessionIsCurrent(key)
        self.publishAttachments(key: key)
        return outcome
      } catch {
        try self.ensureDraftSessionIsCurrent(key)
        throw error
      }
    }
    self.latestQueuedEditsByDraft[key] = Pending(id: id, command: command, draftID: admittedDraft.update.id, task: task)
    self.draftEditTasks[id] = task
    return task
  }

  private func publishAttachments(key: Key) {
    guard let draft = self.cachedDraftsByKey[key], self.isCurrent(key) else { return }
    let attachments = draft.images.map(UpdateDraft.Attachment.image) + (draft.video.map { [.video($0)] } ?? [])
    for (route, state) in self.routes where state.key == key {
      self.draftEventListenersByRoute[route]?(.attachments(attachments))
    }
  }

  public func waitForDraftOperations() async {
    while !self.draftLoadTasks.isEmpty || !self.draftEditTasks.isEmpty {
      for task in Array(self.draftLoadTasks.values) { await task.value }
      for task in Array(self.draftEditTasks.values) { _ = await task.result }
    }
  }
}
