import Foundation
import GraphAPI
import KsApi
import Observation

@MainActor
public protocol DeveloperExamplesProvider {
  func page(parameters: DiscoveryParams, cursor: String?) async throws -> DiscoveryEnvelope
  func projects() async throws -> [DeveloperExamplesFeature.ProjectItem]
  func project(slug: String) async throws -> DeveloperExamplesFeature.ProjectItem?
}

@MainActor
public struct AsyncDeveloperExamplesProvider: DeveloperExamplesProvider {
  private let service: any ServiceType
  public init(service: any ServiceType) { self.service = service }
  public func page(parameters: DiscoveryParams, cursor: String?) async throws -> DiscoveryEnvelope {
    if let cursor { return try await self.service.discoveryPage(paginationURL: cursor) }
    return try await self.service.discoveryPage(params: parameters)
  }
  public func projects() async throws -> [DeveloperExamplesFeature.ProjectItem] {
    try await self.service.richTextExampleProjects()
  }
  public func project(slug: String) async throws -> DeveloperExamplesFeature.ProjectItem? {
    try await self.service.richTextExampleProject(slug: slug)
  }
}

/// Owns the beta examples' pagination, cached rich-text list and replaceable
/// direct-link reads. Each screen gets a route so independent examples cannot
/// cancel each other. UI adapters only render snapshots and report user intent.
@MainActor @Observable
public final class DeveloperExamplesFeature {
  public struct ProjectData: Identifiable, Hashable {
    public let id: Int
    public let title: String
    public init(id: Int, title: String) {
      self.id = id
      self.title = title
    }
  }
  public typealias ProjectItem = RichTextExampleResponse
  public struct PageSnapshot {
    public var projects: [ProjectData] = []
    public var isLoading = false
    public var cursor: String?
    public var statusText = "Waiting to load"
    public var showProgressView: Bool { self.isLoading || self.cursor != nil }
  }
  public struct RichTextSnapshot {
    public var projects: [ProjectItem] = []
    public var isLoading = true
    public var errorMessage: String?
  }
  private struct Session: Equatable {
    let userID: Int?
    let generation: Int
  }
  private enum PageRequest: Equatable {
    case first(DiscoveryParams)
    case next(String)
  }
  private struct PageWork {
    let id: UUID
    let session: Session
    let request: PageRequest
    let previous: PageSnapshot
    let task: Task<Void, Never>
  }
  private struct ListWork {
    let id: UUID
    let session: Session
    let task: Task<Void, Never>
  }
  // Shared lookup waiters read the completed value from this actor-owned slot.
  @MainActor private final class LookupWork {
    let id = UUID()
    let session: Session
    let slug: String
    var task: Task<Void, Never>?
    var result: Result<ProjectItem?, Error>?
    init(session: Session, slug: String) {
      self.session = session
      self.slug = slug
    }
  }
  public let sessionFeature: SessionFeature
  @ObservationIgnored private let makeProvider: () -> any DeveloperExamplesProvider
  private var paginationSnapshotsByRoute: [UUID: PageSnapshot] = [:]
  private var richTextSnapshotsByRoute: [UUID: RichTextSnapshot] = [:]
  @ObservationIgnored private var pendingPageLoads: [UUID: PageWork] = [:]
  @ObservationIgnored private var pendingRichTextLoads: [UUID: ListWork] = [:]
  @ObservationIgnored private var lookupWork: [UUID: LookupWork] = [:]
  @ObservationIgnored private var latestLookupIDsByRoute: [UUID: UUID] = [:]
  @ObservationIgnored private var listSessions: [UUID: Session] = [:]

  public init(
    sessionFeature: SessionFeature, makeProvider: @escaping () -> any DeveloperExamplesProvider
  ) {
    self.sessionFeature = sessionFeature
    self.makeProvider = makeProvider
  }
  private var session: Session {
    .init(userID: self.sessionFeature.currentUser?.id, generation: self.sessionFeature.generation)
  }
  public func pageSnapshot(route: UUID) -> PageSnapshot { self.paginationSnapshotsByRoute[route] ?? PageSnapshot() }
  public func richTextSnapshot(route: UUID) -> RichTextSnapshot {
    self.richTextSnapshotsByRoute[route] ?? RichTextSnapshot()
  }

  public func loadFirstPage(route: UUID, refreshing: Bool = false) async {
    var parameters = DiscoveryParams.defaults
    if refreshing {
      parameters.staffPicks = true
      parameters.sort = .magic
    }
    await self.requestPage(.first(parameters), route: route).value
  }
  public func loadNextPage(route: UUID) async {
    // A repeated gesture joins the existing load; a terminal page returns now.
    // Neither case waits for a publisher event that may never arrive.
    if let work = self.pendingPageLoads[route], work.session == self.session {
      await work.task.value
    } else if let cursor = self.paginationSnapshotsByRoute[route]?.cursor {
      await self.requestPage(.next(cursor), route: route).value
    }
  }
  private func requestPage(_ request: PageRequest, route: UUID) -> Task<Void, Never> {
    let session = self.session
    if let work = self.pendingPageLoads[route], work.request == request, work.session == session {
      return work.task
    }
    self.cancelPage(route: route)
    let previous = self.pageSnapshot(route: route)
    var loading = previous
    loading.isLoading = true
    loading.statusText = "Loading"
    self.paginationSnapshotsByRoute[route] = loading
    let id = UUID()
    let provider = self.makeProvider()
    let task = Task { [self] in
      defer { if self.pendingPageLoads[route]?.id == id { self.pendingPageLoads[route] = nil } }
      do {
        try Task.checkCancellation()
        guard self.session == session else { throw CancellationError() }
        let envelope: DiscoveryEnvelope
        var values: [ProjectData]
        switch request {
        case .first(let parameters):
          envelope = try await provider.page(parameters: parameters, cursor: nil)
          values = []
        case .next(let cursor):
          envelope = try await provider.page(parameters: .defaults, cursor: cursor)
          values = previous.projects
        }
        try Task.checkCancellation()
        guard self.session == session, self.pendingPageLoads[route]?.id == id else { return }
        // Preserve the example's append behavior, including duplicate IDs.
        values += envelope.projects.map { .init(id: $0.id, title: $0.name) }
        let cursor = envelope.projects.isEmpty ? nil : envelope.urls.api.moreProjects
        self.paginationSnapshotsByRoute[route] = PageSnapshot(
          projects: values, cursor: values.isEmpty ? nil : cursor,
          statusText: values.isEmpty
            ? "No results"
            : cursor == nil
              ? "Loaded all results" : "Got \(values.count) results; more are available")
      } catch {
        guard self.pendingPageLoads[route]?.id == id else { return }
        if Task.isCancelled || error is CancellationError || self.session != session {
          self.paginationSnapshotsByRoute[route] = previous
        } else {
          // Original paginator clears displayed values and cursor on failure.
          let message = (error as? ErrorEnvelope)?.errorMessages.first ?? "Unknown error"
          self.paginationSnapshotsByRoute[route] = PageSnapshot(statusText: "Error: \(message)")
        }
      }
    }
    self.pendingPageLoads[route] = PageWork(
      id: id, session: session, request: request, previous: previous, task: task)
    return task
  }

  public func loadRichTextProjects(route: UUID) async {
    let session = self.session
    if let work = self.pendingRichTextLoads[route], work.session == session {
      await work.task.value
      return
    }
    if self.listSessions[route] == session, let state = self.richTextSnapshotsByRoute[route], !state.projects.isEmpty {
      return
    }
    self.pendingRichTextLoads.removeValue(forKey: route)?.task.cancel()
    self.richTextSnapshotsByRoute[route] = RichTextSnapshot()
    self.listSessions[route] = session
    let id = UUID()
    let provider = self.makeProvider()
    let task = Task { [self] in
      defer { if self.pendingRichTextLoads[route]?.id == id { self.pendingRichTextLoads[route] = nil } }
      do {
        try Task.checkCancellation()
        guard self.session == session else { throw CancellationError() }
        let projects = try await provider.projects()
        try Task.checkCancellation()
        guard self.session == session, self.pendingRichTextLoads[route]?.id == id else { return }
        self.richTextSnapshotsByRoute[route] = RichTextSnapshot(projects: projects, isLoading: false)
      } catch {
        guard self.pendingRichTextLoads[route]?.id == id else { return }
        let cancelled = Task.isCancelled || error is CancellationError || self.session != session
        self.richTextSnapshotsByRoute[route] = RichTextSnapshot(
          isLoading: false,
          errorMessage: cancelled ? nil : error.localizedDescription)
      }
    }
    self.pendingRichTextLoads[route] = ListWork(id: id, session: session, task: task)
    await task.value
  }

  public func lookupProject(input: String, route: UUID) async throws -> ProjectItem? {
    guard let slug = Self.extractSlug(from: input) else {
      self.cancelLookup(route: route)
      return nil
    }
    let session = self.session
    let work: LookupWork
    if let pending = self.lookupWork[route], pending.slug == slug, pending.session == session {
      work = pending
    } else {
      self.cancelLookup(route: route)
      let provider = self.makeProvider()
      work = LookupWork(session: session, slug: slug)
      self.lookupWork[route] = work
      self.latestLookupIDsByRoute[route] = work.id
      work.task = Task { [self] in
        defer { work.task = nil }
        do {
          try Task.checkCancellation()
          guard self.session == session else { throw CancellationError() }
          let project = try await provider.project(slug: slug)
          try Task.checkCancellation()
          guard self.session == session, self.latestLookupIDsByRoute[route] == work.id else {
            throw CancellationError()
          }
          work.result = .success(project)
        } catch { work.result = .failure(error) }
      }
    }
    defer { if self.lookupWork[route]?.id == work.id { self.lookupWork[route] = nil } }
    await work.task?.value
    try Task.checkCancellation()
    guard self.session == session, self.latestLookupIDsByRoute[route] == work.id else {
      throw CancellationError()
    }
    guard let result = work.result else { throw CancellationError() }
    return try result.get()
  }
  public func cancelLookup(route: UUID) {
    self.lookupWork.removeValue(forKey: route)?.task?.cancel()
    self.latestLookupIDsByRoute[route] = nil
  }
  private func cancelPage(route: UUID) {
    guard let work = self.pendingPageLoads.removeValue(forKey: route) else { return }
    work.task.cancel()
    self.paginationSnapshotsByRoute[route] = work.previous
  }
  public func suspend(route: UUID) {
    self.cancelPage(route: route)
    if let work = self.pendingRichTextLoads.removeValue(forKey: route) {
      work.task.cancel()
      self.richTextSnapshotsByRoute[route] = RichTextSnapshot(isLoading: false)
    }
    self.cancelLookup(route: route)
  }
  public func release(route: UUID) {
    self.suspend(route: route)
    self.paginationSnapshotsByRoute[route] = nil
    self.richTextSnapshotsByRoute[route] = nil
    self.listSessions[route] = nil
  }
  public func reset() {
    let routes = Set(self.paginationSnapshotsByRoute.keys).union(self.richTextSnapshotsByRoute.keys).union(self.latestLookupIDsByRoute.keys)
    for route in routes { self.release(route: route) }
  }
  private static func extractSlug(from input: String) -> String? {
    if input.contains("/"), !input.hasPrefix("http"), !input.hasPrefix("https") {
      let parts = input.split(separator: "/").map(String.init)
      if parts.count == 2 { return parts.joined(separator: "/") }
    }
    if let url = URL(string: input),
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    {
      let parts = components.path.split(separator: "/").map(String.init)
      if parts.count >= 3, parts[0].lowercased() == "projects" { return "\(parts[1])/\(parts[2])" }
    }
    return nil
  }
}
