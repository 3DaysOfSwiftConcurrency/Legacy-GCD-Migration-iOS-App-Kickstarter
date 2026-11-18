import Foundation
import KsApi

public struct DeepLinkSession: Equatable, Sendable {
  let userID: Int?
  let generation: Int
}

/// Resolved application data. UIKit builds its navigation stack in the presentation layer.
public enum DeepLinkDestination: Sendable {
  case discovery(DiscoveryParams?)
  case project(ProjectDetailsFeature.LinkContext)
  case survey(String)
  case message(MessageThread)
}

extension AppModel {
  var currentDeepLinkSession: DeepLinkSession {
    DeepLinkSession(userID: self.sessionFeature.currentUser?.id, generation: self.sessionFeature.generation)
  }

  /// Coordinates existing product Features without retaining navigation or presentation tasks.
  func resolveDeepLinkDestination(
    for navigation: Navigation, discoveryResponseDelay: TimeInterval
  ) async throws -> DeepLinkDestination? {
    let startingSession = self.currentDeepLinkSession
    try self.ensureDeepLinkSessionIsCurrent(startingSession)
    let destination: DeepLinkDestination?
    do {
      switch navigation {
      case let .tab(.discovery(rawParams)):
        destination = .discovery(try await self.discoveryFeature.parametersForDeepLink(
          rawParams, responseDelay: discoveryResponseDelay
        ))
      case let .user(_, .survey(id)):
        destination = .survey(try await self.activityFeature.surveyURL(id: id))
      case let .messages(id):
        destination = try await self.messagingFeature.thread(id: id).map { .message($0.messageThread) }
      case let .project(_, .pledgeManagerWebview(url), _, _):
        destination = .survey(url)
      case let .project(param, subpage, refInfo, token):
        destination = try await self.projectDetailsFeature.resolveProjectLinkContext(
          param: param, subpage: subpage, refInfo: refInfo, secretRewardToken: token
        ).map { .project($0) }
      default:
        destination = nil
      }
    } catch {
      try self.ensureDeepLinkSessionIsCurrent(startingSession)
      throw error
    }
    try self.ensureDeepLinkSessionIsCurrent(startingSession)
    return destination
  }

  func resolveEmailLinkDestination(for url: URL, route: UUID) async throws -> URL? {
    let startingSession = self.currentDeepLinkSession
    try self.ensureDeepLinkSessionIsCurrent(startingSession)
    do {
      let destination = try await self.authenticationFeature.resolveFirstEmailRedirect(url, route: route)
      try self.ensureDeepLinkSessionIsCurrent(startingSession)
      return destination
    } catch {
      try self.ensureDeepLinkSessionIsCurrent(startingSession)
      throw error
    }
  }

  func releaseEmailLinkResolution(for route: UUID) {
    self.authenticationFeature.cancelEmailRedirect(route: route)
  }

  private func ensureDeepLinkSessionIsCurrent(_ session: DeepLinkSession) throws {
    try Task.checkCancellation()
    guard self.currentDeepLinkSession == session else { throw CancellationError() }
  }
}
