import Foundation
import KsApi
import Prelude
import Observation

@MainActor
public protocol ActivityProvider {
  func page(cursor: String?) async throws -> ActivityEnvelope
  func surveys() async throws -> [SurveyResponse]
}

@MainActor
public struct AsyncActivityProvider: ActivityProvider {
  private let service: any ServiceType
  public init(service: any ServiceType) { self.service = service }
  public func page(cursor: String?) async throws -> ActivityEnvelope { try await self.service
    .activityPage(cursor: cursor)
  }

  public func surveys() async throws -> [SurveyResponse] { try await self.service.unansweredSurveys() }
}

/// Owns the Activity tab's ordered, deduplicated history and survey requests.
/// Refresh retains accumulated history unless the first returned page is empty.
@MainActor @Observable
public final class ActivityFeature {
  public struct Platform {
    public let loadSurvey: @MainActor (Int) async throws -> SurveyResponse
    public let applicationBadgeNumber: @MainActor () -> Int
    public let responseDelaySeconds: @MainActor () -> TimeInterval
    public let projectCardClicked: @MainActor (Project) -> Void

    public init(
      loadSurvey: @escaping @MainActor (Int) async throws -> SurveyResponse,
      applicationBadgeNumber: @escaping @MainActor () -> Int,
      responseDelaySeconds: @escaping @MainActor () -> TimeInterval,
      projectCardClicked: @escaping @MainActor (Project) -> Void
    ) {
      self.loadSurvey = loadSurvey
      self.applicationBadgeNumber = applicationBadgeNumber
      self.responseDelaySeconds = responseDelaySeconds
      self.projectCardClicked = projectCardClicked
    }
  }

  public let sessionFeature: SessionFeature
  public private(set) var activities: [Activity] = []
  public private(set) var surveys: [SurveyResponse] = []
  public private(set) var error: Error?
  public private(set) var surveyError: Error?
  public private(set) var isLoading = false
  private let makeProvider: () -> any ActivityProvider
  private let platform: Platform
  private let sleep: (TimeInterval) async throws -> Void
  private var accountID: Int?
  private var activitySessionGeneration: Int?
  private var nextPageCursor: String?
  private var accumulatedActivityPageItems: [Activity] = []
  private var activityPageRequest: (token: UUID, cursor: String?, task: Task<Void, Never>)?
  private var unansweredSurveyRequest: (token: UUID, task: Task<Void, Never>)?
  public enum Event {
    case activities([Activity])
    case loading(Bool)
    case surveys([SurveyResponse])
  }
  private var listeners: [UUID: @MainActor (Event) -> Void] = [:]
  public func observe(onEvent: @escaping @MainActor (Event) -> Void) -> UUID {
    let id = UUID()
    self.listeners[id] = onEvent
    return id
  }
  public func stopObserving(_ id: UUID) { self.listeners[id] = nil }
  private func publish(_ event: Event) {
    for listener in Array(self.listeners.values) { listener(event) }
  }

  public init(
    platform: Platform,
    sessionFeature: SessionFeature, makeProvider: @escaping () -> any ActivityProvider,
    sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
      if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
    }
  ) {
    self.platform = platform
    self.sessionFeature = sessionFeature
    self.makeProvider = makeProvider
    self.sleep = sleep
  }

  /// The Activity tab owns the presentation value for its unread badge.
  public var currentApplicationBadgeNumber: Int { self.platform.applicationBadgeNumber() }
  var unseenActivityCount: Int? { self.sessionFeature.currentUser?.unseenActivityCount }

  public func isCurrentUser(_ user: User?) -> Bool {
    self.sessionFeature.currentUser == user
  }

  public func projectCardClicked(_ project: Project) {
    self.platform.projectCardClicked(project)
  }

  func surveyURL(id: Int) async throws -> String {
    try await self.platform.loadSurvey(id).urls.web.survey
  }

  private func resetActivityIfSessionChanged() {
    let id = self.sessionFeature.currentUser?.id
    let revision = self.sessionFeature.generation
    guard self.accountID != id || self.activitySessionGeneration != revision else { return }
    self.reset()
    self.accountID = id
    self.activitySessionGeneration = revision
  }

  public func reset() {
    self.activityPageRequest?.task.cancel()
    self.unansweredSurveyRequest?.task.cancel()
    self.activityPageRequest = nil
    self.unansweredSurveyRequest = nil
    self.activities = []
    self.accumulatedActivityPageItems = []
    self.surveys = []
    self.nextPageCursor = nil
    self.error = nil
    self.surveyError = nil
    if self.isLoading { self.isLoading = false; self.publish(.loading(false)) }
  }

  public func refreshActivityFeed() async { await self.requestActivityPage()?.value }
  public func loadNextActivityFeedPage() async {
    await self.requestActivityPage(next: true)?.value
  }

  @discardableResult
  public func requestActivityPage(next: Bool = false) -> Task<Void, Never>? {
    self.resetActivityIfSessionChanged()
    guard self.accountID != nil else { return nil }
    if let activityPageRequest = self.activityPageRequest,
       next || activityPageRequest.cursor == nil {
      return activityPageRequest.task
    }
    guard !next || self.nextPageCursor != nil else { return nil }
    self.activityPageRequest?.task.cancel()
    let cursor = next ? self.nextPageCursor : nil
    if !next {
      self.accumulatedActivityPageItems = []
      self.nextPageCursor = nil
    }
    let token = UUID()
    let userID = self.accountID
    let generation = self.sessionFeature.generation
    let provider = self.makeProvider()
    let delay = self.platform.responseDelaySeconds()
    self.isLoading = true
    self.error = nil
    let task = Task { [weak self, sleep] in
      guard let self else { return }
      defer {
        if self.activityPageRequest?.token == token {
          self.activityPageRequest = nil
          self.isLoading = false
          self.publish(.loading(false))
        }
      }
      do {
        try Task.checkCancellation()
        guard self.sessionFeature.isCurrent(userID: userID, generation: generation) else { return }
        let envelope = try await provider.page(cursor: cursor)
        try await sleep(delay)
        try Task.checkCancellation()
        guard self.activityPageRequest?.token == token,
              self.sessionFeature.isCurrent(userID: userID, generation: generation) else { return }
        self.nextPageCursor = envelope.activities.isEmpty ? nil : envelope.urls.api.moreActivities
        self.accumulatedActivityPageItems += envelope.activities
        self.activities = self.accumulatedActivityPageItems.isEmpty ? []
          : (self.activities + self.accumulatedActivityPageItems).distincts()
          .sorted { $0.id > $1.id }
        self.publish(.activities(self.activities))
      } catch {
        guard !Task.isCancelled, !(error is CancellationError), self.activityPageRequest?.token == token,
              self.sessionFeature.isCurrent(userID: userID, generation: generation) else { return }
        self.error = error
      }
    }
    self.activityPageRequest = (token, cursor, task)
    self.publish(.loading(true))
    return task
  }

  @discardableResult
  public func requestUnansweredSurveys() -> Task<Void, Never>? {
    self.resetActivityIfSessionChanged()
    guard let userID = self.accountID else { return nil }
    if let unansweredSurveyRequest = self.unansweredSurveyRequest {
      return unansweredSurveyRequest.task
    }
    let generation = self.sessionFeature.generation
    let token = UUID()
    let provider = self.makeProvider()
    self.surveyError = nil
    let task = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.unansweredSurveyRequest?.token == token {
          self.unansweredSurveyRequest = nil
        }
      }
      do {
        try Task.checkCancellation()
        guard self.sessionFeature.isCurrent(userID: userID, generation: generation) else { return }
        let surveys = try await provider.surveys()
        try Task.checkCancellation()
        guard self.unansweredSurveyRequest?.token == token,
              self.sessionFeature.isCurrent(userID: userID, generation: generation) else { return }
        self.surveys = surveys
        self.publish(.surveys(surveys))
      } catch {
        guard !Task.isCancelled, !(error is CancellationError),
              self.unansweredSurveyRequest?.token == token,
              self.sessionFeature.isCurrent(userID: userID, generation: generation) else { return }
        self.surveyError = error
      }
    }
    self.unansweredSurveyRequest = (token, task)
    return task
  }
}
