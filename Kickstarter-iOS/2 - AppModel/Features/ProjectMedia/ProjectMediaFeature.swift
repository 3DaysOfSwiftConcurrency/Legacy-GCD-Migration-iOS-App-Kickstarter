import Foundation
import KsApi
import Observation
import UIKit

@MainActor
public protocol ProjectMediaProvider {
  func report(project: any HasProjectWebURL, completed: Bool) async throws -> VoidEnvelope
  func feed() async throws -> [VideoFeedItem]
  func setWatched(id: String, watched: Bool) async throws -> WatchProjectResponseEnvelope
}

@MainActor
public struct AsyncProjectMediaProvider: ProjectMediaProvider {
  private let service: any ServiceType
  public init(service: any ServiceType) { self.service = service }
  public func report(project: any HasProjectWebURL, completed: Bool) async throws -> VoidEnvelope {
    try await self.service.reportVideoEvent(project: project, completed: completed)
  }

  public func feed() async throws -> [VideoFeedItem] {
    let data = try await self.service.projectVideoFeed()
    return data.map { VideoFeedItem(response: $0) }
  }

  public func setWatched(id: String, watched: Bool) async throws -> WatchProjectResponseEnvelope {
    try await self.service.setProjectWatched(id: id, watched: watched)
  }
}

/// Playback counter requests are independent events, not replaceable searches.
/// Start and completion may both be in flight; neither cancels the other.
@MainActor
public final class ProjectMediaFeature {
  private let connectivity: ConnectivityService
  private let settingsFeature: SettingsFeature

  public var isVideoFeedAvailable: Bool {
    self.settingsFeature.isStatsigEnabled(.videoFeed) && self.connectivity.connectivity != .none
  }

  /// Consumers receive availability, not the network classification or flag rule.
  /// The initial value is synchronous. Every connectivity event reads the current
  /// flag; each screen suppresses repeated presentation values independently.
  public func observeVideoFeedAvailability(
    _ observer: @escaping @MainActor (Bool) -> Void
  ) -> MainActorObservation {
    return self.connectivity.source.observe { [weak self] _ in
      guard let self else { return }
      observer(self.isVideoFeedAvailable)
    }
  }

  public var webBaseURL: URL { self.readWebBaseURL() }
  public struct SavePrompts {
    let tipState: @MainActor () -> (today: Date, hasSeenTip: Bool)?
    let recordTip: @MainActor () -> Void
    let canShowNotification: @MainActor () -> Bool

    public init(
      tipState: @escaping @MainActor () -> (today: Date, hasSeenTip: Bool)?,
      recordTip: @escaping @MainActor () -> Void,
      canShowNotification: @escaping @MainActor () -> Bool
    ) {
      self.tipState = tipState
      self.recordTip = recordTip
      self.canShowNotification = canShowNotification
    }
  }
  private let readWebBaseURL: @MainActor () -> URL
  private let analytics: @MainActor () -> KSRAnalytics?
  private let watchResponseDelaySeconds: @MainActor () -> TimeInterval
  private let savePrompts: SavePrompts?
  private struct ImageKey: Hashable { let route: UUID; let url: URL }
  private var pendingImageLoads: [ImageKey: (id: UUID, task: Task<UIImage, Error>)] = [:]
  private let loadImage: @MainActor (URL) async throws -> UIImage

  public func requestImage(route: UUID, url: URL) -> Task<UIImage, Error> {
    let key = ImageKey(route: route, url: url)
    if let pending = self.pendingImageLoads[key] { return pending.task }
    let id = UUID()
    let load = self.loadImage
    let task = Task { [weak self] in
      defer { if self?.images[key]?.id == id { self?.images[key] = nil } }
      try Task.checkCancellation()
      let image = try await load(url)
      try Task.checkCancellation()
      guard self?.images[key]?.id == id else { throw CancellationError() }
      return image
    }
    self.pendingImageLoads[key] = (id, task)
    return task
  }

  public func cancelImages(route: UUID) {
    for key in self.pendingImageLoads.keys.filter({ $0.route == route }) {
      self.pendingImageLoads.removeValue(forKey: key)?.task.cancel()
    }
  }

  deinit { self.pendingImageLoads.values.forEach { $0.task.cancel() } }

  private struct PreparationKey: Hashable { let route: UUID; let slot: String }
  private struct Preparation {
    let id: UUID
    let url: URL
    let thumbnail: URL?
    let task: Task<PreparedProjectMedia, Error>
  }
  private var pendingPlaybackPreparations: [PreparationKey: Preparation] = [:]
  private let preparePlayback: @MainActor (URL, URL?) async throws -> PreparedProjectMedia

  /// Each page/element owns an independent player. Equivalent requests for that
  /// slot share pending work; changed URLs replace it without affecting other rows.
  public func requestPlaybackPreparation(
    route: UUID, slot: String, url: URL, thumbnail: URL?
  ) -> Task<PreparedProjectMedia, Error> {
    let key = PreparationKey(route: route, slot: slot)
    if let pending = self.pendingPlaybackPreparations[key], pending.url == url, pending.thumbnail == thumbnail {
      return pending.task
    }
    self.pendingPlaybackPreparations[key]?.task.cancel()
    let id = UUID()
    let prepare = self.preparePlayback
    let task = Task { [self] in
      defer { if self.pendingPlaybackPreparations[key]?.id == id { self.pendingPlaybackPreparations[key] = nil } }
      try Task.checkCancellation()
      let result = try await prepare(url, thumbnail)
      try Task.checkCancellation()
      guard self.pendingPlaybackPreparations[key]?.id == id else { throw CancellationError() }
      return result
    }
    self.pendingPlaybackPreparations[key] = Preparation(id: id, url: url, thumbnail: thumbnail, task: task)
    return task
  }

  public func cancelPlaybackPreparations(route: UUID) {
    for key in Array(self.pendingPlaybackPreparations.keys) where key.route == route {
      self.pendingPlaybackPreparations.removeValue(forKey: key)?.task.cancel()
    }
  }

  /// One authoritative observable feed per screen route. Only this Feature
  /// mutates it; a ViewModel reads its individual properties for presentation.
  @Observable @MainActor
  public final class FeedState {
    public fileprivate(set) var items: [VideoFeedItem] = []
    public fileprivate(set) var fetchedItems: [VideoFeedItem] = []
    public fileprivate(set) var isLoading = false
    public fileprivate(set) var error: Error?
    public fileprivate(set) var isInitialLoadComplete = false
    public fileprivate(set) var saveFailedItemID: String?
  }

  public enum FeedError: Error { case empty }
  private var videoFeedStatesByRoute: [UUID: FeedState] = [:]
  private var feedRequests: [UUID: (userID: Int?, generation: Int, token: UUID, task: Task<Void, Never>)] = [:]
  private var feedSaveTasksByRoute: [UUID: [String: (token: UUID, task: Task<Void, Never>)]] = [:]

  fileprivate struct WatchIdentity: Hashable {
    let projectID: String
    let userID: Int?
    let generation: Int
  }

  private var watchWrites: [WatchIdentity: (watched: Bool, token: UUID, task: Task<WatchProjectResponseEnvelope, Error>)] = [:]

  public func feedState(route: UUID) -> FeedState {
    if let feed = self.videoFeedStatesByRoute[route] { return feed }
    let feed = FeedState()
    self.videoFeedStatesByRoute[route] = feed
    return feed
  }

  public var hasCurrentUser: Bool { self.sessionFeature.currentUser != nil }

  public func loadFeed(route: UUID) async {
    guard !Task.isCancelled else { return }
    await self.requestFeed(route: route).value
  }

  @discardableResult
  public func requestFeed(route: UUID) -> Task<Void, Never> {
    let userID = self.sessionFeature.currentUser?.id
    let generation = self.sessionFeature.generation
    if let request = self.feedRequests[route], request.userID == userID, request.generation == generation {
      return request.task
    }
    self.feedRequests[route]?.task.cancel()
    let feed = self.feedState(route: route)
    let provider = self.makeProvider()
    let sessionFeature = self.sessionFeature
    let token = UUID()
    feed.isLoading = true
    feed.error = nil
    let task = Task { [weak self] in
      defer {
        if self?.feedRequests[route]?.token == token {
          self?.feedRequests[route] = nil
          feed.isLoading = false
        }
      }
      do {
        try Task.checkCancellation()
        guard sessionFeature.isCurrent(userID: userID, generation: generation) else { throw CancellationError() }
        let items = try await provider.feed()
        try Task.checkCancellation()
        guard let self, self.feedRequests[route]?.token == token,
              sessionFeature.isCurrent(userID: userID, generation: generation) else { return }
        guard let first = items.first else { throw FeedError.empty }
        // Match the existing reload observer contract: initial flag precedes
        // fetchedItems; saves never write fetchedItems or trigger a collection reload.
        feed.isInitialLoadComplete = true
        feed.fetchedItems = items
        feed.items = items
        self.analytics()?.trackVideoFeedImpression(
          videoId: first.id, projectId: first.projectId, positionInSession: 0
        )
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled, let self, self.feedRequests[route]?.token == token,
              sessionFeature.isCurrent(userID: userID, generation: generation) else { return }
        feed.error = error
      }
    }
    self.feedRequests[route] = (userID, generation, token, task)
    return task
  }

  /// Equivalent pending desired states share; changed states queue after the
  /// preceding write for this account/project. Disposing a request cannot undo
  /// a server mutation, so save→unsave must not race on separate connections.
  @discardableResult
  public func requestWatch(projectID: String, watched: Bool) -> Task<WatchProjectResponseEnvelope, Error> {
    let key = self.watchIdentity(projectID)
    if let pending = self.watchWrites[key], pending.watched == watched { return pending.task }
    let predecessor = self.watchWrites[key]?.task
    let provider = self.makeProvider()
    let token = UUID()
    let task = Task<WatchProjectResponseEnvelope, Error> { [self] in
      defer { if self.watchWrites[key]?.token == token { self.watchWrites[key] = nil } }
      if let predecessor { _ = await predecessor.result }
      try Task.checkCancellation()
      guard self.isCurrent(key) else { throw CancellationError() }
      let result = try await provider.setWatched(id: projectID, watched: watched)
      try Task.checkCancellation()
      guard self.isCurrent(key) else { throw CancellationError() }
      return result
    }
    self.watchWrites[key] = (watched, token, task)
    return task
  }

  public struct WatchIntent {
    fileprivate let key: WatchIdentity
    fileprivate let token: UUID
    public let watched: Bool
    fileprivate let previous: Bool
  }
  private var watchIntents: [WatchIdentity: (token: UUID, admitted: Bool)] = [:]
  private var watchSettlements: [UUID: Task<WatchProjectResponseEnvelope, Error>] = [:]
  private let savedProjects = NSCache<NSNumber, NSNumber>()
  private var cacheIdentity: WatchIdentity?

  private func watchIdentity(_ projectID: String) -> WatchIdentity {
    WatchIdentity(projectID: projectID, userID: self.sessionFeature.currentUser?.id,
                  generation: self.sessionFeature.generation)
  }
  private func isCurrent(_ key: WatchIdentity) -> Bool {
    key.userID == self.sessionFeature.currentUser?.id && key.generation == self.sessionFeature.generation
  }
  private func prepareCache() {
    let identity = self.watchIdentity("")
    if let previous = self.cacheIdentity, previous != identity {
      self.savedProjects.removeAllObjects()
      self.watchIntents.removeAll()
    }
    self.cacheIdentity = identity
  }
  public func cached(_ project: Project) -> Project {
    self.prepareCache()
    var project = project
    if let saved = self.savedProjects.object(forKey: NSNumber(value: project.id)) {
      project.personalization.isStarred = saved.boolValue
    }
    return project
  }
  private func cache(_ saved: Bool, for key: WatchIdentity) {
    guard self.isCurrent(key), let id = decompose(id: key.projectID) else { return }
    self.prepareCache()
    self.savedProjects.setObject(NSNumber(value: saved), forKey: NSNumber(value: id))
  }
  public func claimSaveProjectTip(for project: Project) -> Bool {
    guard let savePrompts = self.savePrompts, let state = savePrompts.tipState(),
          !project.endsIn48Hours(today: state.today), !state.hasSeenTip else { return false }
    savePrompts.recordTip()
    return true
  }

  public func claimSaveNotificationPrompt() -> Bool {
    guard let savePrompts = self.savePrompts, savePrompts.canShowNotification(),
          self.sessionFeature.currentUser?.stats.starredProjectsCount == 0 else { return false }
    savePrompts.recordTip()
    return true
  }

  public func prepareWatch(projectID: String, watched: Bool, previous: Bool) -> WatchIntent {
    self.prepareCache()
    let intent = WatchIntent(key: self.watchIdentity(projectID), token: UUID(), watched: watched, previous: previous)
    self.watchIntents[intent.key] = (intent.token, false)
    self.cache(watched, for: intent.key)
    return intent
  }
  public func isCurrentIntent(_ intent: WatchIntent) -> Bool {
    self.isCurrent(intent.key) && self.watchIntents[intent.key]?.token == intent.token
  }
  public func cancelPreparedWatch(_ intent: WatchIntent) {
    guard self.isCurrentIntent(intent), self.watchIntents[intent.key]?.admitted == false else { return }
    self.cache(intent.previous, for: intent.key)
    self.watchIntents[intent.key] = nil
  }
  public func submitWatch(_ intent: WatchIntent) -> Task<WatchProjectResponseEnvelope, Error> {
    if let pending = self.watchSettlements[intent.token] { return pending }
    guard self.isCurrentIntent(intent) else { return Task { throw CancellationError() } }
    self.watchIntents[intent.key]?.admitted = true
    let command = self.requestWatch(projectID: intent.key.projectID, watched: intent.watched)
    let task = Task { [self] in
      defer { self.watchSettlements[intent.token] = nil }
      do {
        let value = try await command.value
        guard self.isCurrent(intent.key) else { throw CancellationError() }
        if self.isCurrentIntent(intent) { self.cache(intent.watched, for: intent.key) }
        return value
      } catch {
        guard self.isCurrent(intent.key) else { throw CancellationError() }
        if self.isCurrentIntent(intent) { self.cache(intent.previous, for: intent.key) }
        throw error
      }
    }
    self.watchSettlements[intent.token] = task
    return task
  }

  /// Returns the current save state, or nil if the observing task or intent became stale.
  public func watch(project: Project, intent: WatchIntent) async -> Project? {
    guard !Task.isCancelled, self.isCurrentIntent(intent) else { return nil }
    return await self.resolveWatch(project: project, intent: intent, command: self.submitWatch(intent))
  }

  private func resolveWatch(
    project: Project, intent: WatchIntent, command: Task<WatchProjectResponseEnvelope, Error>
  ) async -> Project? {
    var project = project
    do {
      let response = try await command.value
      guard !Task.isCancelled, self.isCurrentIntent(intent) else { return nil }
      project.watchesCount = response.watchProject.project.watchesCount
      project.personalization.isStarred = intent.watched
    } catch {
      guard !Task.isCancelled, !(error is CancellationError), self.isCurrentIntent(intent) else { return nil }
      project.personalization.isStarred = intent.previous
    }
    return project
  }

  public func waitForOperations() async {
    while !self.watchWrites.isEmpty || !self.watchSettlements.isEmpty {
      for pending in Array(self.watchWrites.values) { _ = await pending.task.result }
      for task in Array(self.watchSettlements.values) { _ = await task.result }
    }
  }

  @discardableResult
  public func toggleSaved(route: UUID, projectID: String) -> Task<Void, Never>? {
    guard let feed = self.videoFeedStatesByRoute[route],
          let index = feed.items.firstIndex(where: { $0.id == projectID }) else { return nil }
    let item = feed.items[index]
    let wasSaved = item.isSaved
    let userID = self.sessionFeature.currentUser?.id
    feed.items[index].isSaved = !wasSaved
    feed.items[index].watchesCount = max(0, item.watchesCount + (wasSaved ? -1 : 1))
    self.analytics()?.trackVideoFeedCTAClicked(
      ctaContext: .videoFeedSave, videoId: item.id, projectId: item.projectId
    )
    let intent = self.prepareWatch(projectID: item.projectId, watched: !wasSaved, previous: wasSaved)
    let mutation = self.submitWatch(intent)
    let token = UUID()
    let task = Task { [self] in
      defer {
        if self.feedSaveTasksByRoute[route]?[projectID]?.token == token {
          self.feedSaveTasksByRoute[route]?[projectID] = nil
        }
      }
      do {
        _ = try await mutation.value
      } catch {
        guard !(error is CancellationError), self.videoFeedStatesByRoute[route] === feed,
              self.feedSaveTasksByRoute[route]?[projectID]?.token == token,
              userID == self.sessionFeature.currentUser?.id, self.isCurrentIntent(intent),
              let index = feed.items.firstIndex(where: { $0.id == projectID }) else { return }
        // Preserve rollback and toast for the latest visible intent only.
        feed.items[index].isSaved = wasSaved
        feed.items[index].watchesCount = max(0, feed.items[index].watchesCount + (wasSaved ? 1 : -1))
        feed.saveFailedItemID = projectID
      }
    }
    self.feedSaveTasksByRoute[route, default: [:]][projectID] = (token, task)
    return task
  }

  public func clearSaveFailure(route: UUID) {
    self.videoFeedStatesByRoute[route]?.saveFailedItemID = nil
  }

  public func waitForSaves(route: UUID) async {
    let tasks = self.feedSaveTasksByRoute[route]?.values.map(\.task) ?? []
    for task in tasks { await task.value }
  }

  public func reconcileSavedProjects(route: UUID) {
    self.prepareCache()
    guard let feed = self.videoFeedStatesByRoute[route] else { return }
    for index in feed.items.indices {
      if let id = decompose(id: feed.items[index].projectId),
         let saved = self.savedProjects.object(forKey: NSNumber(value: id))?.boolValue {
        let previous = feed.items[index].isSaved
        feed.items[index].isSaved = saved
        if previous != saved { feed.items[index].watchesCount += saved ? 1 : -1 }
      }
    }
  }

  private struct Event: Hashable {
    let route: UUID
    let url: String
    let completed: Bool
    let userID: Int?
    let generation: Int
  }

  private var playbackReportTasksByEvent: [Event: (id: UUID, task: Task<VoidEnvelope?, Never>)] = [:]
  private let makeProvider: () -> any ProjectMediaProvider

  public let sessionFeature: SessionFeature

  public func trackWatchProjectButtonClicked(
    project: Project,
    page: KSRAnalytics.PageContext,
    params: DiscoveryParams?,
    selected: Bool
  ) {
    self.analytics()?.trackWatchProjectButtonClicked(
      project: project,
      page: page,
      params: params,
      typeContext: selected ? .unwatch : .watch
    )
  }

  public func responseDelayForWatch() -> TimeInterval {
    self.watchResponseDelaySeconds()
  }

  public init(
    sessionFeature: SessionFeature,
    settingsFeature: SettingsFeature,
    connectivity: ConnectivityService = ConnectivityService(),
    webBaseURL: @escaping @MainActor () -> URL = { ServerConfig.production.webBaseUrl },
    analytics: @escaping @MainActor () -> KSRAnalytics? = { nil },
    watchResponseDelaySeconds: @escaping @MainActor () -> TimeInterval = { 0 },
    savePrompts: SavePrompts? = nil,
    loadImage: (@MainActor (URL) async throws -> UIImage)? = nil,
    preparePlayback: (@MainActor (URL, URL?) async throws -> PreparedProjectMedia)? = nil,
    makeProvider: @escaping () -> any ProjectMediaProvider
  ) {
    self.connectivity = connectivity
    self.settingsFeature = settingsFeature
    self.loadImage = loadImage ?? { try await ProjectMediaPreparation.loadImage(url: $0) }
    self.preparePlayback = preparePlayback ?? { try await ProjectMediaPreparation.load(url: $0, thumbnailURL: $1) }
    self.sessionFeature = sessionFeature
    self.readWebBaseURL = webBaseURL
    self.analytics = analytics
    self.watchResponseDelaySeconds = watchResponseDelaySeconds
    self.savePrompts = savePrompts
    self.makeProvider = makeProvider
  }

  @discardableResult
  public func report(route: UUID, project: any HasProjectWebURL, completed: Bool) async -> VoidEnvelope? {
    guard !Task.isCancelled else { return nil }
    return await self.requestReport(route: route, project: project, completed: completed).value
  }

  @discardableResult
  public func requestReport(
    route: UUID, project: any HasProjectWebURL, completed: Bool
  ) -> Task<VoidEnvelope?, Never> {
    let event = Event(
      route: route,
      url: project.projectWebURL,
      completed: completed,
      userID: self.sessionFeature.currentUser?.id,
      generation: self.sessionFeature.generation
    )
    if let request = self.playbackReportTasksByEvent[event] { return request.task }
    let token = UUID()
    let provider = self.makeProvider()
    let sessionFeature = self.sessionFeature
    let task: Task<VoidEnvelope?, Never> = Task { [weak self] in
      defer { if self?.requests[event]?.id == token { self?.requests[event] = nil } }
      do {
        try Task.checkCancellation()
        guard sessionFeature.isCurrent(userID: event.userID, generation: event.generation) else { return nil }
        let value = try await provider.report(project: project, completed: completed)
        try Task.checkCancellation()
        guard let self, self.playbackReportTasksByEvent[event]?.id == token,
              sessionFeature.isCurrent(userID: event.userID, generation: event.generation) else { return nil }
        return value
      } catch {
        // Counter errors have always been non-user-facing; do not retry a write
        // whose server-side outcome may be unknown.
        return nil
      }
    }
    self.playbackReportTasksByEvent[event] = (token, task)
    return task
  }

  public func release(route: UUID) {
    self.cancelImages(route: route)
    self.cancelPlaybackPreparations(route: route)
    self.feedRequests.removeValue(forKey: route)?.task.cancel()
    self.videoFeedStatesByRoute[route] = nil
    self.feedSaveTasksByRoute[route] = nil
    // Watch writes deliberately continue after their presenting route closes.
    for event in self.playbackReportTasksByEvent.keys.filter({ $0.route == route }) {
      self.playbackReportTasksByEvent.removeValue(forKey: event)?.task.cancel()
    }
  }
}
