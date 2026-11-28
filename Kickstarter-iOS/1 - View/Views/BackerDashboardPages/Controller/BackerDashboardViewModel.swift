import KsApi
import Prelude
import UIKit

public enum BackerDashboardTab: Sendable {
  case backed
  case saved

  public static let allTabs: [BackerDashboardTab] = [.backed, .saved]
}

@MainActor
public final class BackerDashboardViewModel {
  var onAvatarURL: ((URL?) -> Void)?
  var onBackedTitle: ((String) -> Void)?
  var onName: ((String) -> Void)?
  var onConfigurePages: ((BackerDashboardTab) -> Void)?
  var onMessages: (() -> Void)?
  var onSettings: (() -> Void)?
  var onNavigate: ((BackerDashboardTab) -> Void)?
  var onPinIndicator: ((BackerDashboardTab, Bool) -> Void)?
  var onNotification: ((Notification) -> Void)?
  var onSavedTitle: ((String) -> Void)?
  var onSelectedButton: ((BackerDashboardTab) -> Void)?
  var onCurrentUserUpdated: ((User) -> Void)?

  private let profileFeature: ProfileFeature
  private var headerObserver: PlatformObservation?
  private var pendingPage: Int?
  private var backedTitleCount = 0
  private var lastAnimatedTab: BackerDashboardTab?
  private(set) var currentSelectedTab: BackerDashboardTab = .backed
  private(set) var initialTopConstant: CGFloat = 0
  internal private(set) var headerTask: Task<Void, Never>?

  public init(profileFeature: ProfileFeature) {
    let feature = profileFeature
    self.profileFeature = feature
    self.headerObserver = feature.observeHeader { [weak self] event in self?.receive(event) }
  }

  private func receive(_ event: ProfileFeature.HeaderEvent) {
    switch event {
    case let .user(user):
      self.onAvatarURL?(URL(string: user.avatar.large ?? user.avatar.medium))
      self.onName?(user.name)
      self.onBackedTitle?(Strings.projects_count_newline_backed(projects_count: user.stats.backedProjectsCount ?? 0))
      self.backedTitleCount += 1
      if self.backedTitleCount == 2 {
        self.onSelectedButton?(.backed)
        self.onPinIndicator?(.backed, false)
      }
    case let .graphUser(user):
      self.onSavedTitle?(Strings.projects_count_newline_saved(projects_count: user.stats.starredProjectsCount ?? 0))
    case let .combinedUser(user):
      self.onCurrentUserUpdated?(user)
    }
  }

  func backedProjectsButtonTapped() { self.navigate(to: .backed) }
  func savedProjectsButtonTapped() { self.navigate(to: .saved) }
  func beganPanGestureWith(headerTopConstant: CGFloat, scrollViewYOffset: CGFloat) {
    self.initialTopConstant = min(headerTopConstant, -scrollViewYOffset)
  }
  func currentUserUpdatedInEnvironment() {
    self.onNotification?(Notification(name: .ksr_userUpdated, object: nil))
  }
  func messagesButtonTapped() { self.onMessages?() }
  func settingsButtonTapped() { self.onSettings?() }
  func viewDidLoad() { self.onConfigurePages?(.backed) }
  func viewWillAppear(_ animated: Bool) { self.headerTask = self.profileFeature.startProfileHeaderLoad() }
  func willTransition(toPage nextPage: Int) { self.pendingPage = nextPage }
  func pageTransition(completed: Bool) {
    guard completed, let page = self.pendingPage else { return }
    self.navigate(to: BackerDashboardTab.allTabs[page])
  }
  func projectSaved() {
    self.headerTask = self.profileFeature.startProfileHeaderLoad(replacing: true)
  }
  private func navigate(to tab: BackerDashboardTab) {
    self.currentSelectedTab = tab
    if tab == .saved {
      let params = DiscoveryParams.defaults |> DiscoveryParams.lens.starred .~ true
      AppEnvironment.current.ksrAnalytics.trackProfilePageFilterSelected(params: params)
    }
    self.onNavigate?(tab)
    self.onSelectedButton?(tab)
    if self.lastAnimatedTab != tab {
      self.lastAnimatedTab = tab
      self.onPinIndicator?(tab, true)
    }
  }
}
