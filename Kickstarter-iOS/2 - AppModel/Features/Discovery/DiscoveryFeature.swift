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
  private let service: any ServiceType

  public init(service: any ServiceType) { self.service = service }

  public func page(parameters: DiscoveryParams, cursor: String?) async throws -> DiscoveryEnvelope {
    if let cursor { return try await self.service.discoveryPage(paginationURL: cursor) }
    return try await self.service.discoveryPage(params: parameters)
  }

  public func activitySample() async throws -> ActivityEnvelope? {
    try await self.service.discoveryActivitySample()
  }
}

enum DiscoveryCompositionError: Error { case missingCategoryLoader }

/// One Explore owner, with independent request identities for its four retained feeds.
/// Main-actor updates notify the existing UIKit presentation of changes.
@MainActor @Observable
public final class DiscoveryFeature {
  public struct Analytics {
    public let selectedSort: (DiscoveryParams.Sort, DiscoveryParams, DiscoveryParams.Sort) -> Void
    public let discoveryViewed: (DiscoveryParams) -> Void
    public let projectCardClicked: (Project, DiscoveryParams) -> Void

    public init(
      selectedSort: @escaping (DiscoveryParams.Sort, DiscoveryParams, DiscoveryParams.Sort) -> Void,
      discoveryViewed: @escaping (DiscoveryParams) -> Void,
      projectCardClicked: @escaping (Project, DiscoveryParams) -> Void
    ) {
      self.selectedSort = selectedSort
      self.discoveryViewed = discoveryViewed
      self.projectCardClicked = projectCardClicked
    }

    public static let noop = Self(
      selectedSort: { _, _, _ in },
      discoveryViewed: { _ in },
      projectCardClicked: { _, _ in }
    )
  }

  public var serverEnvironment: EnvironmentType { self.resolveServerEnvironment() }
  public var isDebugBuild: Bool { self.resolveIsDebugBuild() }
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
  private var recommendationAvailabilityRequest: (
    id: UUID, userID: Int, accountID: Int?, sessionGeneration: Int, task: Task<Bool, Error>
  )?
  private var recommendationAvailabilityDeliveryTask: (id: UUID, task: Task<Void, Never>)?
  private var recommendationRequestGeneration = 0
  private let provider: any DiscoveryProvider
  private let analytics: Analytics
  private let loadCategories: @MainActor () async throws -> RootCategoriesEnvelope
  private let resolveCategoryCache: @MainActor () -> KSCache
  private let resolveLocalStore: (@MainActor () -> any KeyValueStoreType)?
  private let resolveCloudStore: (@MainActor () -> any KeyValueStoreType)?
  private let resolveServerEnvironment: @MainActor () -> EnvironmentType
  private let resolveIsDebugBuild: @MainActor () -> Bool
  private let responseDelaySeconds: @MainActor () -> TimeInterval
  private let sleep: @MainActor (TimeInterval) async throws -> Void
  private let sessionFeature: SessionFeature
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
    self.resolveCloudStore?().favoriteCategoryIds.contains(id) == true ||
      self.resolveLocalStore?().favoriteCategoryIds.contains(id) == true
  }

  public func toggleFavoriteCategory(_ id: Int) {
    // Preserve the legacy toggle independently in each store, even if they differ.
    for store in [self.resolveCloudStore?(), self.resolveLocalStore?()].compactMap({ $0 }) {
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
    guard let cloudStore = self.resolveCloudStore?(), let localStore = self.resolveLocalStore?(),
          !cloudStore.hasSeenFavoriteCategoryAlert ||
          !localStore.hasSeenFavoriteCategoryAlert else { return false }
    cloudStore.hasSeenFavoriteCategoryAlert = true
    localStore.hasSeenFavoriteCategoryAlert = true
    return true
  }

  public func dismissPersonalizationCard() {
    self.resolveLocalStore?().hasDismissedPersonalizationCard = true
  }

  public func cachedOnboardingCategories() -> [KsApi.Category] {
    guard let data = self.resolveLocalStore?().onboardingCategories else { return [] }
    return (try? JSONDecoder().decode([KsApi.Category].self, from: data)) ?? []
  }

  public func recordSeenAndReturnNewActivitySample(_ activities: [Activity]) -> [Activity] {
    guard let store = self.resolveLocalStore?() else { return activities }
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
    Self.initialParameters(for: self.sessionFeature.currentUser)
  }

  public var user: User? { self.sessionFeature.currentUser }

  /// Availability is Discovery state even when the result is rendered as an app shortcut.
  public func hasRecommendations(for user: User?) async throws -> Bool {
    try Task.checkCancellation()
    guard let user else {
      self.cancelRecommendationAvailabilityRequest()
      return false
    }
    let accountID = self.sessionFeature.currentUser?.id
    let sessionGeneration = self.sessionFeature.generation
    if let request = self.recommendationAvailabilityRequest, request.userID == user.id,
       request.accountID == accountID, request.sessionGeneration == sessionGeneration {
      return try await self.awaitCurrentRecommendationAvailability(
        request.task, generation: self.recommendationRequestGeneration,
        accountID: accountID, sessionGeneration: sessionGeneration
      )
    }
    self.cancelRecommendationAvailabilityRequest()
    let generation = self.recommendationRequestGeneration
    let id = UUID()
    let provider = self.provider
    let task = Task { @MainActor in
      defer {
        if self.recommendationAvailabilityRequest?.id == id { self.recommendationAvailabilityRequest = nil }
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
    self.recommendationAvailabilityRequest = (id, user.id, accountID, sessionGeneration, task)
    return try await self.awaitCurrentRecommendationAvailability(
      task, generation: generation, accountID: accountID, sessionGeneration: sessionGeneration
    )
  }

  private func awaitCurrentRecommendationAvailability(
    _ task: Task<Bool, Error>, generation: Int, accountID: Int?, sessionGeneration: Int
  ) async throws -> Bool {
    let value = try await task.value
    try Task.checkCancellation()
    guard generation == self.recommendationRequestGeneration,
          self.sessionFeature.isCurrent(userID: accountID, generation: sessionGeneration) else {
      throw CancellationError()
    }
    return value
  }

  /// Replaces the application's pending availability delivery without owning UIKit shortcuts.
  @discardableResult
  func refreshRecommendationAvailability(onResult: @escaping @MainActor (Bool) -> Void) -> Task<Void, Never> {
    self.cancelRecommendationRefresh()
    let id = UUID()
    let user = self.sessionFeature.currentUser
    let generation = self.sessionFeature.generation
    let task = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.recommendationAvailabilityDeliveryTask?.id == id { self.recommendationAvailabilityDeliveryTask = nil }
      }
      do {
        try Task.checkCancellation()
        guard self.sessionFeature.isCurrent(userID: user?.id, generation: generation) else { return }
        let available = try await self.hasRecommendations(for: user)
        try Task.checkCancellation()
        guard self.recommendationAvailabilityDeliveryTask?.id == id,
              self.sessionFeature.isCurrent(userID: user?.id, generation: generation) else { return }
        onResult(available)
      } catch { /* Failed or superseded reads leave the application's shortcuts in place. */ }
    }
    self.recommendationAvailabilityDeliveryTask = (id, task)
    return task
  }

  func cancelRecommendationRefresh() {
    self.recommendationAvailabilityDeliveryTask?.task.cancel()
    self.recommendationAvailabilityDeliveryTask = nil
  }

  func waitForRecommendationRefresh() async { await self.recommendationAvailabilityDeliveryTask?.task.value }

  private func cancelRecommendationAvailabilityRequest() {
    self.recommendationRequestGeneration += 1
    self.recommendationAvailabilityRequest?.task.cancel()
    self.recommendationAvailabilityRequest = nil
  }

  func resetRecommendationAvailability() {
    self.cancelRecommendationRefresh()
    self.cancelRecommendationAvailabilityRequest()
  }

  public var currentUserHasSocialConnections: Bool {
    self.sessionFeature.currentUser?.social == .some(true)
  }

  public func topFilters() -> [DiscoveryParams] {
    let user = self.sessionFeature.currentUser
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
    analytics: Analytics = .noop,
    loadCategories: (@MainActor () async throws -> RootCategoriesEnvelope)? = nil,
    categoryCache: (@MainActor () -> KSCache)? = nil,
    localStore: (@MainActor () -> any KeyValueStoreType)? = nil,
    cloudStore: (@MainActor () -> any KeyValueStoreType)? = nil,
    serverEnvironment: @escaping @MainActor () -> EnvironmentType = { .production },
    isDebugBuild: @escaping @MainActor () -> Bool = { false },
    responseDelaySeconds: @escaping @MainActor () -> TimeInterval = { 0 },
    sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { seconds in
      if seconds.isInfinite { try await Task.sleep(nanoseconds: UInt64.max) }
      else if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
      try Task.checkCancellation()
    },
    sessionFeature: SessionFeature
  ) {
    self.provider = provider
    self.analytics = analytics
    self.loadCategories = loadCategories ?? { throw DiscoveryCompositionError.missingCategoryLoader }
    let fallbackCategoryCache = KSCache()
    self.resolveCategoryCache = categoryCache ?? { fallbackCategoryCache }
    self.resolveLocalStore = localStore
    self.resolveCloudStore = cloudStore
    self.resolveServerEnvironment = serverEnvironment
    self.resolveIsDebugBuild = isDebugBuild
    self.responseDelaySeconds = responseDelaySeconds
    self.sleep = sleep
    self.sessionFeature = sessionFeature
  }

  public func selectedSortChanged(
    from previous: DiscoveryParams.Sort,
    parameters: DiscoveryParams,
    to current: DiscoveryParams.Sort
  ) {
    self.analytics.selectedSort(previous, parameters, current)
  }

  public func discoveryViewed(parameters: DiscoveryParams) {
    self.analytics.discoveryViewed(parameters)
  }

  public func projectCardClicked(project: Project, parameters: DiscoveryParams) {
    self.analytics.projectCardClicked(project, parameters)
  }

  func waitForDeepLinkResponse(_ seconds: TimeInterval) async throws {
    try await self.sleep(seconds)
  }

  func rootCategories() async throws -> RootCategoriesEnvelope {
    try await self.loadCategories()
  }

  func makeCategoriesUseCase() -> FetchCategoriesUseCase {
    FetchCategoriesUseCase(
      cache: self.resolveCategoryCache,
      fetch: { try await self.loadCategories().rootCategories },
      responseDelaySeconds: self.responseDelaySeconds,
      sleep: self.sleep
    )
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
       page.userID == self.sessionFeature.currentUser?.id,
       page.snapshot.parameters == parameters { return request.task }
    page.request?.task.cancel()
    page.userID = self.sessionFeature.currentUser?.id
    page.snapshot.parameters = parameters
    page.cursor = nil
    page.snapshot.hasMore = false
    return self.startPage(sort: sort, page: page, parameters: parameters, cursor: nil)
  }

  @discardableResult
  internal func requestNextPage(sort: DiscoveryParams.Sort) -> Task<Void, Never>? {
    let page = self.page(for: sort)
    guard page.userID == self.sessionFeature.currentUser?.id else { return nil }
    if let request = page.request { return request.task }
    guard let parameters = page.snapshot.parameters, let cursor = page.cursor,
          page.snapshot.hasMore else { return nil }
    return self.startPage(sort: sort, page: page, parameters: parameters, cursor: cursor)
  }

  private func startPage(
    sort: DiscoveryParams.Sort, page: Page, parameters: DiscoveryParams, cursor: String?
  ) -> Task<Void, Never> {
    let id = UUID()
    let session = self.sessionFeature
    let requestedUserID = session.currentUser?.id
    let delay = self.responseDelaySeconds()
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
        guard session.currentUser?.id == requestedUserID else { return }
        let response: Result<DiscoveryEnvelope, Error>
        do { response = .success(try await provider.page(parameters: parameters, cursor: cursor)) }
        catch is CancellationError { return }
        catch { response = .failure(error) }
        try Task.checkCancellation()
        try await sleep(delay)
        try Task.checkCancellation()
        guard let self, page.request?.id == id,
              session.currentUser?.id == requestedUserID else { return }
        let envelope = try response.get()
        page.snapshot.projects = ((cursor == nil ? [] : page.snapshot.projects) + envelope.projects).distincts()
        page.cursor = envelope.urls.api.moreProjects
        page.snapshot.hasMore = !envelope.projects.isEmpty
        self.emit(.projects(sort, page.snapshot.projects))
      } catch {
        guard page.request?.id == id, !Task.isCancelled, !(error is CancellationError),
              session.currentUser?.id == requestedUserID else { return }
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
    let session = self.sessionFeature
    let requestedUserID = session.currentUser?.id
    let delay = self.responseDelaySeconds()
    page.snapshot.activityError = nil
    let task = Task { @MainActor [weak self, provider, sleep] in
      defer { if page.activityRequest?.id == id { page.activityRequest = nil } }
      do {
        try Task.checkCancellation()
        guard session.currentUser?.id == requestedUserID else { return }
        guard let envelope = try await provider.activitySample() else { return }
        try await sleep(delay)
        try Task.checkCancellation()
        guard let self, page.activityRequest?.id == id,
              session.currentUser?.id == requestedUserID else { return }
        page.snapshot.activitySample = envelope.activities
        self.emit(.activities(sort, envelope.activities))
      } catch {
        // Legacy sample failures leave the existing sample unchanged.
        guard page.activityRequest?.id == id, !Task.isCancelled, !(error is CancellationError),
              session.currentUser?.id == requestedUserID else { return }
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
