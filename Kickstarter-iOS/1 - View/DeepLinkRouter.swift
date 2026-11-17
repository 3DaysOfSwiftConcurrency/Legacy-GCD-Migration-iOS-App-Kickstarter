import Foundation
import KsApi
import Prelude

/// Resolves deep-link destinations before UIKit presents them.
/// Project links publish only after the complete project, update and reply chain loads.
@MainActor
public final class DeepLinkRouter {
  public let sessionFeature: SessionFeature
  public let messagingFeature: MessagingFeature
  public struct ProjectDestination: Sendable {
    public let project: Project
    public let subpage: Navigation.Project
    public let refInfo: RefInfo?
    public let secretRewardToken: String?
    public let update: Update?
    public let replies: CommentRepliesEnvelope?
  }
  public enum Destination: Sendable {
    case discovery(DiscoveryParams?)
    case project(ProjectDestination)
    case survey(String)
    case message(MessageThread)
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
  private let discussionFeature: DiscussionFeature
  private let discoveryFeature: DiscoveryFeature
  private let activityFeature: ActivityFeature
  private let sleep: (TimeInterval) async throws -> Void
  private var destinations: [UUID: (navigation: Navigation, request: Pending<Destination?>)] = [:]
  private var destinationTasks: [UUID: Task<Destination?, Error>] = [:]

  public init(
    sessionFeature: SessionFeature, messagingFeature: MessagingFeature,
    discussionFeature: DiscussionFeature,
    discoveryFeature: DiscoveryFeature, activityFeature: ActivityFeature,
    sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
      if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
    }
  ) {
    self.sessionFeature = sessionFeature
    self.messagingFeature = messagingFeature
    self.discussionFeature = discussionFeature
    self.discoveryFeature = discoveryFeature
    self.activityFeature = activityFeature
    self.sleep = sleep
  }
  private var session: Session {
    Session(userID: self.sessionFeature.currentUser?.id, generation: self.sessionFeature.generation)
  }
  private func requireCurrent(_ session: Session) throws {
    try Task.checkCancellation()
    guard self.session == session else { throw CancellationError() }
  }

  public func resolve(_ navigation: Navigation, route: UUID) async throws -> Destination? {
    try Task.checkCancellation()
    let result = try await self.requestDestination(navigation, route: route).value
    try Task.checkCancellation()
    return result
  }
  @discardableResult public func requestDestination(_ navigation: Navigation, route: UUID) -> Task<
    Destination?, Error
  > {
    let session = self.session
    if let pending = self.destinations[route], pending.navigation == navigation,
      pending.request.session == session
    {
      return pending.request.task
    }
    self.release(route: route)
    let id = UUID()
    let delay = AppEnvironment.current.apiDelayInterval.searchDelaySeconds
    let task = Task { [self] in
      defer {
        self.destinationTasks[id] = nil
        if self.destinations[route]?.request.id == id { self.destinations[route] = nil }
      }
      try self.requireCurrent(session)
      let destination: Destination?
      do {
        destination = try await self.load(
          navigation, session: session, delay: delay)
      } catch {
        try self.requireCurrent(session)
        throw error
      }
      try self.requireCurrent(session)
      guard self.destinations[route]?.request.id == id else { throw CancellationError() }
      return destination
    }
    self.destinations[route] = (navigation, Pending(id: id, session: session, task: task))
    self.destinationTasks[id] = task
    return task
  }

  private func load(
    _ navigation: Navigation, session: Session,
    delay: TimeInterval
  ) async throws -> Destination? {
    switch navigation {
    case .tab(.discovery(let rawParams)):
      guard let rawParams, let params = DiscoveryParams.decodeJSONDictionary(rawParams) else {
        return .discovery(nil)
      }
      let (category, subcategory) = deepLinkCategories(rawParams: rawParams)
      guard let category else { return .discovery(params) }
      let envelope = try await self.discoveryFeature.rootCategories()
      try self.requireCurrent(session)
      let matched = findCategoryFromRootCategories(
        envelope: envelope, categoryParam: category, subcategoryParam: subcategory)
      try await self.sleep(delay)
      return .discovery(params |> DiscoveryParams.lens.category .~ matched)
    case .user(_, .survey(let id)):
      let url = try await self.activityFeature.surveyURL(id: id)
      return .survey(url)
    case .messages(let id):
      return try await self.messagingFeature.thread(id: id).map { .message($0.messageThread) }
    case .project(_, .pledgeManagerWebview(let url), _, _):
      return .survey(url)
    case .project(let param, let subpage, let refInfo, let token):
      let project = try await self.discussionFeature.projectContext(param: param)
      try self.requireCurrent(session)
      // Prelaunch projects only expose their root, as before.
      guard project.displayPrelaunch != true || subpage == .root else { return nil }
      var update: Update?
      var replies: CommentRepliesEnvelope?
      switch subpage {
      case .commentThread(let id?, _):
        replies = try await self.discussionFeature.initialReplies(id: id)
      case .update(let id, let child):
        update = try await self.discussionFeature.updateContext(id: id, project: .id(project.id))
        try self.requireCurrent(session)
        if case .commentThread(let commentID?, _) = child {
          replies = try await self.discussionFeature.initialReplies(id: commentID)
        }
      default: break
      }
      return .project(
        ProjectDestination(
          project: project, subpage: subpage, refInfo: refInfo, secretRewardToken: token,
          update: update, replies: replies))
    default: return nil  // Synchronous destinations still invalidate an earlier async link.
    }
  }

  public func release(route: UUID) {
    self.destinations.removeValue(forKey: route)?.request.task.cancel()
  }
  public func reset() {
    for route in Array(self.destinations.keys) { self.release(route: route) }
  }
  public func waitForOperations() async {
    while !self.destinationTasks.isEmpty
    {
      for task in Array(self.destinationTasks.values) { _ = await task.result }
    }
  }

}
