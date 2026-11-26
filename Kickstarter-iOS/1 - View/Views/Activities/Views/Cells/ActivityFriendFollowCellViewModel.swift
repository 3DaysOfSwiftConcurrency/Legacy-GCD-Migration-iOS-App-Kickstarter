import KDS
import KsApi
import Observation
import UIKit

@MainActor @Observable
public final class ActivityFriendFollowCellViewModel {
  public private(set) var friendImageURL: URL?
  public private(set) var hideFollowButton: Bool?
  public private(set) var title: NSAttributedString?
  @ObservationIgnored var onChange: (@MainActor () -> Void)?
  @ObservationIgnored private let friendsFeature: FriendsFeature
  @ObservationIgnored private let sessionFeature: SessionFeature
  @ObservationIgnored private var observation: Task<Void, Never>?
  private var friend: User?

  public init(friendsFeature: FriendsFeature, sessionFeature: SessionFeature) {
    self.friendsFeature = friendsFeature
    self.sessionFeature = sessionFeature
  }

  public func configureWith(activity: Activity) {
    self.friend = activity.user.map { self.friendsFeature.userWithCachedFollowingStatus($0) }
    guard let friend = self.friend else { return }
    self.friendImageURL = URL(string: friend.avatar.small)
    let string = Strings.activity_user_name_is_now_following_you(user_name: "<b>\(friend.name)</b>")
    self.title = string.simpleHtmlAttributedString(
      base: [.font: UIFont.ksr_subhead(size: 14), .foregroundColor: LegacyColors.ksr_support_700.uiColor()],
      bold: [.font: UIFont.ksr_headline(size: 14), .foregroundColor: LegacyColors.ksr_support_700.uiColor()]
    ) ?? NSAttributedString(string: "")
    self.hideFollowButton = friend.isFriend ?? false
  }

  public func followButtonTapped() {
    guard let friend = self.friend else { return }
    let friendsFeature = self.friendsFeature
    let generation = self.sessionFeature.generation
    let userID = self.sessionFeature.currentUser?.id
    let task = friendsFeature.startFollowingStatusUpdate(user: friend, following: true)
    self.observation?.cancel()
    self.observation = Task { [weak self] in
      do {
        let result = try await task.value
        guard let self else { return }
        guard !Task.isCancelled, self.friend?.id == result.id,
              self.sessionFeature.isCurrent(userID: userID, generation: generation) else { return }
        self.hideFollowButton = result.isFriend ?? false
        self.onChange?()
      } catch { }
    }
  }

  func waitForObservation() async { await self.observation?.value }
  deinit { self.observation?.cancel() }
}
