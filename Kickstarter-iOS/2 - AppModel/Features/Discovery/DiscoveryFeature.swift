import Foundation
import Observation
import KsApi
import Prelude

@MainActor
public protocol DiscoveryProvider {
  func page(parameters: DiscoveryParams, cursor: String?) async throws -> DiscoveryEnvelope
  func activitySample() async throws -> ActivityEnvelope?
}

/// Uses the existing authenticated service and its native async URLSession transport.
@MainActor
public struct AsyncDiscoveryProvider: DiscoveryProvider {
  public init() {}

  public func page(parameters: DiscoveryParams, cursor: String?) async throws -> DiscoveryEnvelope {
    let service = AppEnvironment.current.apiService
    if let cursor { return try await service.discoveryPage(paginationURL: cursor) }
    return try await service.discoveryPage(params: parameters)
  }

  public func activitySample() async throws -> ActivityEnvelope? {
    try await AppEnvironment.current.apiService.discoveryActivitySample()
  }
}

/// One Explore owner, with independent request identities for its four retained feeds.
/// Main-actor updates notify the existing UIKit presentation of changes.
@MainActor @Observable
public final class DiscoveryFeature {
  public var serverEnvironment: EnvironmentType {
    AppEnvironment.current.apiService.serverConfig.environment
  }
  public var isDebugBuild: Bool {
    guard let environment = AppEnvironment.current else { return false }
    return environment.mainBundle.isAlpha || environment.mainBundle.isBeta || environment.mainBundle.isDebug
  }
  public struct PageSnapshot {
    public fileprivate(set) var projects: [Project] = []
    public fileprivate(set) var parameters: DiscoveryParams?
    public fileprivate(set) var isLoading = false
    public fileprivate(set) var error: ErrorEnvelope?
    public fileprivate(set) var hasMore = false
    public fileprivate(set) var activitySample: [Activity] = []
    public fileprivate(set) var activityError: ErrorEnvelope?
  }

  @Observable final class Page {
    var snapshot = PageSnapshot()
    var userID: Int?
    var cursor: String?
    var request: (id: UUID, cursor: String?, task: Task<Void, Never>)?
    var activityRequest: (id: UUID, task: Task<Void, Never>)?
  }

  private var pages: [String: Page] = [:]
  private var recommendationRequest: (id: UUID, userID: Int, task: Task<Bool, Error>)?
  private var recommendationGeneration = 0
  private let provider: any DiscoveryProvider
  private let loadCategories: @MainActor () async throws -> RootCategoriesEnvelope
  private let sleep: @MainActor (TimeInterval) async throws -> Void
  private let currentUser: @MainActor () -> User?
  internal enum Update {
    case projects(DiscoveryParams.Sort, [Project])
    case loading(DiscoveryParams.Sort, Bool)
    case activities(DiscoveryParams.Sort, [Activity])
  }
  @ObservationIgnored private var observers: [(id: UUID, callback: (Update) -> Void)] = []
  internal func observe(_ callback: @escaping (Update) -> Void) -> MainActorObservation {
    let id = UUID()
    self.observers.append((id, callback))
    return MainActorObservation { [weak self] in self?.observers.removeAll { $0.id == id } }
  }
  private func emit(_ update: Update) {
    for observer in self.observers { observer.callback(update) }
  }
  public private(set) var selectedParameters: DiscoveryParams?

  public func isFavoriteCategory(_ id: Int) -> Bool {
    let environment = AppEnvironment.current
    return environment?.ubiquitousStore.favoriteCategoryIds.contains(id) == true ||
      environment?.userDefaults.favoriteCategoryIds.contains(id) == true
  }

  public func toggleFavoriteCategory(_ id: Int) {
    guard let environment = AppEnvironment.current else { return }
    // Preserve the legacy toggle independently in each store, even if they differ.
    for store in [environment.ubiquitousStore, environment.userDefaults] {
      var ids = store.favoriteCategoryIds
      if let index = ids.firstIndex(of: id) {
        ids.remove(at: index)
      } else {
        ids.append(id)
      }
      store.favoriteCategoryIds = ids
    }
  }

  public func claimFavoriteCategoryTip() -> Bool {
    guard let environment = AppEnvironment.current,
          !environment.ubiquitousStore.hasSeenFavoriteCategoryAlert ||
          !environment.userDefaults.hasSeenFavoriteCategoryAlert else { return false }
    environment.ubiquitousStore.hasSeenFavoriteCategoryAlert = true
    environment.userDefaults.hasSeenFavoriteCategoryAlert = true
    return true
  }

  public func dismissPersonalizationCard() {
    AppEnvironment.current.userDefaults.hasDismissedPersonalizationCard = true
  }

  public func cachedOnboardingCategories() -> [KsApi.Category] {
    guard let data = AppEnvironment.current.userDefaults.onboardingCategories else { return [] }
    return (try? JSONDecoder().decode([KsApi.Category].self, from: data)) ?? []
  }

  public func consumeUnseenActivitySample(_ activities: [Activity]) -> [Activity] {
    let store = AppEnvironment.current.userDefaults
    let lastSeenID = store.lastSeenActivitySampleId
    let unseenActivities = activities.filter { $0.id != lastSeenID }
    if let last = unseenActivities.last {
      store.lastSeenActivitySampleId = last.id
    }
    return unseenActivities
  }

  public static func initialParameters(for user: User?) -> DiscoveryParams {
    guard user?.optedOutOfRecommendations == false else {
      return DiscoveryParams.defaults |> DiscoveryParams.lens.includePOTD .~ true
    }
    return DiscoveryParams.recommendedDefaults
  }

  public func initialParameters() -> DiscoveryParams {
    Self.initialParameters(for: self.currentUser())
  }

  public var user: User? { self.currentUser() }

  /// Availability is Discovery state even when the result is rendered as an app shortcut.
  public func hasRecommendations(for user: User?) async throws -> Bool {
    try Task.checkCancellation()
    guard let user else {
      self.resetRecommendationAvailability()
      return false
    }
    if let request = self.recommendationRequest, request.userID == user.id {
      return try await self.recommendationAvailability(
        request.task, generation: self.recommendationGeneration
      )
    }
    self.resetRecommendationAvailability()
    let generation = self.recommendationGeneration
    let id = UUID()
    let provider = self.provider
    let task = Task { @MainActor in
      defer {
        if self.recommendationRequest?.id == id { self.recommendationRequest = nil }
      }
      do {
        let parameters = DiscoveryParams.defaults
          |> DiscoveryParams.lens.recommended .~ true
          |> DiscoveryParams.lens.state .~ .live
          |> DiscoveryParams.lens.perPage .~ 1
        let page = try await provider.page(parameters: parameters, cursor: nil)
        try Task.checkCancellation()
        return page.stats.count > 0
      } catch is CancellationError { throw CancellationError() }
      catch {
        try Task.checkCancellation()
        return false
      }
    }
    self.recommendationRequest = (id, user.id, task)
    return try await self.recommendationAvailability(task, generation: generation)
  }

  private func recommendationAvailability(
    _ task: Task<Bool, Error>, generation: Int
  ) async throws -> Bool {
    let value = try await task.value
    try Task.checkCancellation()
    guard generation == self.recommendationGeneration else { throw CancellationError() }
    return value
  }

  func resetRecommendationAvailability() {
    self.recommendationGeneration += 1
    self.recommendationRequest?.task.cancel()
    self.recommendationRequest = nil
  }

  public var currentUserHasSocialConnections: Bool {
    self.currentUser()?.social == .some(true)
  }

  public func topFilters() -> [DiscoveryParams] {
    let user = self.currentUser()
    var filters = [
      .defaults |> DiscoveryParams.lens.includePOTD .~ true,
      .defaults |> DiscoveryParams.lens.staffPicks .~ true
    ]
    guard let user else { return filters }
    filters.append(.defaults |> DiscoveryParams.lens.starred .~ true)
    if user.optedOutOfRecommendations != true {
      filters.append(
        .defaults
          |> DiscoveryParams.lens.recommended .~ true
          |> DiscoveryParams.lens.backed .~ false
      )
    }
    filters.append(.defaults |> DiscoveryParams.lens.social .~ true)
    return filters
  }

  /// Selection is domain state; screen readiness still decides when to publish it.
  public func selectFilter(_ parameters: DiscoveryParams) {
    self.selectedParameters = parameters
  }

  public init(
    provider: any DiscoveryProvider,
    loadCategories: @escaping @MainActor () async throws -> RootCategoriesEnvelope = {
      try await AppEnvironment.current.apiService.fetchSearchCategories()
    },
    sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { seconds in
      if seconds.isInfinite { try await Task.sleep(nanoseconds: UInt64.max) }
      else if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
      try Task.checkCancellation()
    },
    currentUser: @escaping @MainActor () -> User?
  ) {
    self.provider = provider
    self.loadCategories = loadCategories
    self.sleep = sleep
    self.currentUser = currentUser
  }

  func waitForDeepLinkResponse(_ seconds: TimeInterval) async throws {
    try await self.sleep(seconds)
  }

  func rootCategories() async throws -> RootCategoriesEnvelope {
    try await self.loadCategories()
  }

  public func snapshot(for sort: DiscoveryParams.Sort) -> PageSnapshot {
    self.pages[sort.rawValue]?.snapshot ?? PageSnapshot()
  }

  public func refresh(sort: DiscoveryParams.Sort, parameters: DiscoveryParams) async {
    guard !Task.isCancelled else { return }
    await self.requestRefresh(sort: sort, parameters: parameters).value
  }

  public func loadNextPage(sort: DiscoveryParams.Sort) async {
    guard !Task.isCancelled else { return }
    await self.requestNextPage(sort: sort)?.value
  }

  public func loadActivitySample(sort: DiscoveryParams.Sort) async {
    guard !Task.isCancelled else { return }
    await self.requestActivitySample(sort: sort).value
  }

  /// Same-input callers share work. An explicit refresh/session/environment event
  /// may force a replacement even when its filter values have not changed.
  @discardableResult
  internal func requestRefresh(
    sort: DiscoveryParams.Sort, parameters: DiscoveryParams, force: Bool = false
  ) -> Task<Void, Never> {
    let page = self.page(for: sort)
    var parameters = parameters
    parameters.sort = sort
    if !force, let request = page.request, request.cursor == nil,
       page.userID == self.currentUser()?.id,
       page.snapshot.parameters == parameters { return request.task }
    page.request?.task.cancel()
    page.userID = self.currentUser()?.id
    page.snapshot.parameters = parameters
    page.cursor = nil
    page.snapshot.hasMore = false
    return self.startPage(sort: sort, page: page, parameters: parameters, cursor: nil)
  }

  @discardableResult
  internal func requestNextPage(sort: DiscoveryParams.Sort) -> Task<Void, Never>? {
    let page = self.page(for: sort)
    guard page.userID == self.currentUser()?.id else { return nil }
    if let request = page.request { return request.task }
    guard let parameters = page.snapshot.parameters, let cursor = page.cursor,
          page.snapshot.hasMore else { return nil }
    return self.startPage(sort: sort, page: page, parameters: parameters, cursor: cursor)
  }

  private func startPage(
    sort: DiscoveryParams.Sort, page: Page, parameters: DiscoveryParams, cursor: String?
  ) -> Task<Void, Never> {
    let id = UUID()
    let currentUser = self.currentUser
    let requestedUserID = currentUser()?.id
    let delay = AppEnvironment.current.apiDelayInterval.searchDelaySeconds
    page.snapshot.isLoading = true
    page.snapshot.error = nil
    let task = Task { @MainActor [weak self, provider, sleep] in
      defer {
        if page.request?.id == id {
          page.request = nil
          page.snapshot.isLoading = false
          self?.emit(.loading(sort, false))
        }
      }
      do {
        try Task.checkCancellation()
        guard currentUser()?.id == requestedUserID else { return }
        let response: Result<DiscoveryEnvelope, Error>
        do { response = .success(try await provider.page(parameters: parameters, cursor: cursor)) }
        catch is CancellationError { return }
        catch { response = .failure(error) }
        try Task.checkCancellation()
        try await sleep(delay)
        try Task.checkCancellation()
        guard let self, page.request?.id == id,
              currentUser()?.id == requestedUserID else { return }
        let envelope = try response.get()
        page.snapshot.projects = ((cursor == nil ? [] : page.snapshot.projects) + envelope.projects).distincts()
        page.cursor = envelope.urls.api.moreProjects
        page.snapshot.hasMore = !envelope.projects.isEmpty
        self.emit(.projects(sort, page.snapshot.projects))
      } catch {
        guard page.request?.id == id, !Task.isCancelled, !(error is CancellationError),
              currentUser()?.id == requestedUserID else { return }
        page.snapshot.error = (error as? ErrorEnvelope) ?? .couldNotParseJSON
      }
    }
    page.request = (id, cursor, task)
    self.emit(.loading(sort, true))
    return task
  }

  @discardableResult
  internal func requestActivitySample(sort: DiscoveryParams.Sort) -> Task<Void, Never> {
    let page = self.page(for: sort)
    page.activityRequest?.task.cancel()
    let id = UUID()
    let currentUser = self.currentUser
    let requestedUserID = currentUser()?.id
    let delay = AppEnvironment.current.apiDelayInterval.searchDelaySeconds
    page.snapshot.activityError = nil
    let task = Task { @MainActor [weak self, provider, sleep] in
      defer { if page.activityRequest?.id == id { page.activityRequest = nil } }
      do {
        try Task.checkCancellation()
        guard currentUser()?.id == requestedUserID else { return }
        guard let envelope = try await provider.activitySample() else { return }
        try await sleep(delay)
        try Task.checkCancellation()
        guard let self, page.activityRequest?.id == id,
              currentUser()?.id == requestedUserID else { return }
        page.snapshot.activitySample = envelope.activities
        self.emit(.activities(sort, envelope.activities))
      } catch {
        // Legacy sample failures leave the existing sample unchanged.
        guard page.activityRequest?.id == id, !Task.isCancelled, !(error is CancellationError),
              currentUser()?.id == requestedUserID else { return }
        page.snapshot.activityError = (error as? ErrorEnvelope) ?? .couldNotParseJSON
      }
    }
    page.activityRequest = (id, task)
    return task
  }

  /// Owner-driven cancellation invalidates identity before cancelling transport.
  /// Merely hiding a retained feed does not cancel it (legacy behaviour).
  public func cancel(sort: DiscoveryParams.Sort) {
    guard let page = self.pages[sort.rawValue] else { return }
    let request = page.request
    let activity = page.activityRequest
    page.request = nil
    page.activityRequest = nil
    request?.task.cancel()
    activity?.task.cancel()
    if page.snapshot.isLoading {
      page.snapshot.isLoading = false
      self.emit(.loading(sort, false))
    }
  }

  private func page(for sort: DiscoveryParams.Sort) -> Page {
    if let page = self.pages[sort.rawValue] { return page }
    let page = Page()
    self.pages[sort.rawValue] = page
    return page
  }
}
