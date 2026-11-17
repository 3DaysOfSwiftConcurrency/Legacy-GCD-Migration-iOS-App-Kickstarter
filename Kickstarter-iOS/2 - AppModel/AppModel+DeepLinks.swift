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
  var deepLinkSession: DeepLinkSession {
    DeepLinkSession(userID: self.sessionFeature.currentUser?.id, generation: self.sessionFeature.generation)
  }

  /// Coordinates existing product Features without retaining navigation or presentation tasks.
  func resolveDeepLink(
    _ navigation: Navigation, discoveryResponseDelay: TimeInterval
  ) async throws -> DeepLinkDestination? {
    let session = self.deepLinkSession
    try self.requireDeepLinkSession(session)
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
        destination = try await self.projectDetailsFeature.linkContext(
          param: param, subpage: subpage, refInfo: refInfo, secretRewardToken: token
        ).map { .project($0) }
      default:
        destination = nil
      }
    } catch {
      try self.requireDeepLinkSession(session)
      throw error
    }
    try self.requireDeepLinkSession(session)
    return destination
  }

  func resolveEmailLink(_ url: URL, route: UUID) async throws -> URL? {
    let session = self.deepLinkSession
    try self.requireDeepLinkSession(session)
    do {
      let destination = try await self.authenticationFeature.firstRedirect(url, route: route)
      try self.requireDeepLinkSession(session)
      return destination
    } catch {
      try self.requireDeepLinkSession(session)
      throw error
    }
  }

  func releaseEmailLink(route: UUID) {
    self.authenticationFeature.releaseEmailRedirect(route: route)
  }

  private func requireDeepLinkSession(_ session: DeepLinkSession) throws {
    try Task.checkCancellation()
    guard self.deepLinkSession == session else { throw CancellationError() }
  }
}
