import Foundation
import KsApi

extension ProjectDetailsFeature {
  public struct LinkContext: Sendable {
    public let project: Project
    public let subpage: Navigation.Project
    public let refInfo: RefInfo?
    public let secretRewardToken: String?
    public let update: KsApi.Update?
    public let replies: CommentRepliesEnvelope?
  }

  /// A project link is usable only after all of its requested resources are available.
  /// Prelaunch projects expose their root and must not request private subresources.
  func linkContext(
    param: Param, subpage: Navigation.Project, refInfo: RefInfo?, secretRewardToken: String?
  ) async throws -> LinkContext? {
    let userID = self.sessionFeature.currentUser?.id
    let generation = self.sessionFeature.generation
    func requireCurrent() throws {
      try Task.checkCancellation()
      guard self.sessionFeature.isCurrent(userID: userID, generation: generation) else {
        throw CancellationError()
      }
    }
    try requireCurrent()
    let project = try await self.discussionFeature.projectContext(param: param)
    try requireCurrent()
    guard project.displayPrelaunch != true || subpage == .root else { return nil }
    var update: KsApi.Update?
    var replies: CommentRepliesEnvelope?
    switch subpage {
    case let .commentThread(id?, _):
      replies = try await self.discussionFeature.initialReplies(id: id)
    case let .update(id, child):
      update = try await self.discussionFeature.updateContext(id: id, project: .id(project.id))
      try requireCurrent()
      if case let .commentThread(commentID?, _) = child {
        replies = try await self.discussionFeature.initialReplies(id: commentID)
      }
    default: break
    }
    try requireCurrent()
    return LinkContext(
      project: project, subpage: subpage, refInfo: refInfo, secretRewardToken: secretRewardToken,
      update: update, replies: replies
    )
  }
}
