import Foundation
import KsApi

@MainActor
final class CommentCellViewModel {
  enum Event {
    case authorBadge(Comment.AuthorBadge), authorImageURL(URL?), authorName(String), body(String)
    case bottomRowStackViewIsHidden(Bool), cellAuthor(Comment.Author), commentStatus(Comment.Status)
    case flagButtonIsHidden(Bool), notifyDelegateLinkTappedWithURL(URL), postTime(String)
    case postedButtonIsHidden(Bool), replyButtonIsHidden(Bool), replyCommentTapped(Comment)
    case shouldIndentContent(Bool), viewCommentReplies(Comment), viewRepliesViewHidden(Bool)
  }

  var onEvent: ((Event) -> Void)?
  private let discussionFeature: DiscussionFeature
  private var comment: Comment?
  private var lastProjectAccess: Bool?

  init(discussionFeature: DiscussionFeature) {
    self.discussionFeature = discussionFeature
  }

  func configureWith(comment: Comment, project: Project?) {
    self.comment = comment
    self.onEvent?(.authorImageURL(comment.author.isBlocked ? nil : URL(string: comment.author.imageUrl)))
    self.onEvent?(.body(getCommentBody(comment, communityGuidelinesURL: self.discussionFeature.helpURL(.community))))
    self.onEvent?(.authorName(comment.author.isBlocked ? Strings.Blocked_user() : comment.author.name))
    self.publishStatus(comment.status)
    if let createdAt = comment.createdAt {
      self.onEvent?(.postTime(Format.date(secondsInUTC: createdAt, dateStyle: .medium, timeStyle: .short)))
    }
    self.onEvent?(.authorBadge(self.badge(for: comment)))
    self.onEvent?(.flagButtonIsHidden(true))
    if let project { self.lastProjectAccess = userIsBackingCreatorOrCollaborator(project) }
    if let allowed = self.lastProjectAccess {
      let hidden = self.discussionFeature.sessionFeature.currentUser == nil || !allowed
      self.onEvent?(.replyButtonIsHidden(hidden))
      self.onEvent?(.bottomRowStackViewIsHidden(hidden || comment.isReply))
    }
    self.onEvent?(.viewRepliesViewHidden(viewRepliesStackViewHidden(comment.replyCount)))
  }

  func bindStyles() {
    guard let comment = self.comment else { return }
    self.publishStatus(comment.status)
    self.onEvent?(.authorBadge(self.badge(for: comment)))
    self.onEvent?(.shouldIndentContent(comment.isReply))
  }

  private func badge(for comment: Comment) -> Comment.AuthorBadge {
    if comment.author.isBlocked { return .backer }
    return comment.author.id == self.discussionFeature.sessionFeature.currentUser?.id.description ? .you : comment.authorBadge
  }

  private func publishStatus(_ status: Comment.Status) {
    self.onEvent?(.commentStatus(status))
    self.onEvent?(.postedButtonIsHidden(status != .retrySuccess))
  }

  func linkTapped(url: URL) { self.onEvent?(.notifyDelegateLinkTappedWithURL(url)) }
  func cellHeaderTapped() {
    if let comment = self.comment { self.onEvent?(.cellAuthor(comment.author)) }
  }
  func replyButtonTapped() {
    if let comment = self.comment { self.onEvent?(.replyCommentTapped(comment)) }
  }
  func viewRepliesButtonTapped() {
    if let comment = self.comment { self.onEvent?(.viewCommentReplies(comment)) }
  }
}

private func userIsBackingCreatorOrCollaborator(_ project: Project) -> Bool {
  return (project.personalization.backing != nil || project.personalization.isBacking == .some(true)) ||
    !project.memberData.permissions.isEmpty
}

private func viewRepliesStackViewHidden(_ replyCount: Int?) -> Bool {
  return replyCount == 0
}

@MainActor
private func getCommentBody(_ comment: Comment, communityGuidelinesURL: String?) -> String {
  switch true {
  case comment.author.isBlocked:
    return Strings.This_user_has_been_blocked()
  case comment.removedPerGuidelines:
    return commentRemovedPerGuidelines(communityGuidelinesURL: communityGuidelinesURL)
  case comment.isDeleted:
    return commentDeletedText(communityGuidelinesURL: communityGuidelinesURL)
  case comment.isFlagged:
    return commentFlaggedText(communityGuidelinesURL: communityGuidelinesURL)
  default:
    return comment.body
  }
}

@MainActor
private func commentRemovedPerGuidelines(communityGuidelinesURL: String?) -> String {
  guard let communityGuidelinesLink = communityGuidelinesURL else {
    return ""
  }

  return Strings
    .This_comment_has_been_removed_for_violating_kickstarters_community_guidelines(
      community_guidelines: communityGuidelinesLink
    )
}

@MainActor
private func commentDeletedText(communityGuidelinesURL: String?) -> String {
  guard let communityGuidelinesLink = communityGuidelinesURL else {
    return ""
  }

  return Strings.This_comment_has_been_removed_by_Kickstarter() + " " + Strings
    .Learn_more_about_comment_guidelines(community_link: communityGuidelinesLink)
}

@MainActor
private func commentFlaggedText(communityGuidelinesURL: String?) -> String {
  guard let communityGuidelinesLink = communityGuidelinesURL else {
    return ""
  }

  return Strings
    .This_comment_is_under_review_for_potentially_violating_kickstarters_community_guidelines(
      community_guidelines: communityGuidelinesLink
    )
}
