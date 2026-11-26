import Foundation
import KsApi
import Prelude

public typealias RootViewControllerIndex = Int
public typealias RootTabBarItemBadgeValueData = (String?, RootViewControllerIndex)

public enum RootViewControllerData: Equatable {
  case discovery
  case activities
  case pledgedProjectsAndActivities
  case search
  case profile(isLoggedIn: Bool)

  fileprivate var tab: RootTab {
    switch self {
    case .discovery: return .discovery
    case .activities, .pledgedProjectsAndActivities: return .activity
    case .search: return .search
    case .profile: return .profile
    }
  }
}

private enum RootTab {
  case discovery, activity, search, profile

  var analyticsLabel: KSRAnalytics.TabBarItemLabel {
    switch self {
    case .discovery: return .discovery
    case .activity: return .activity
    case .search: return .search
    case .profile: return .profile
    }
  }

  func item(index: RootViewControllerIndex, avatarURL: URL?) -> TabBarItem {
    switch self {
    case .discovery: return .home(index: index)
    case .activity: return .activity(index: index)
    case .search: return .search(index: index)
    case .profile: return .profile(avatarUrl: avatarURL, index: index)
    }
  }
}

public struct TabBarItemsData {
  public let items: [TabBarItem]
  public let isLoggedIn: Bool
}

public enum TabBarItem {
  case activity(index: RootViewControllerIndex)
  case home(index: RootViewControllerIndex)
  case profile(avatarUrl: URL?, index: RootViewControllerIndex)
  case search(index: RootViewControllerIndex)
}

@MainActor
public protocol RootViewModelInputs {
  /// Call when the application will enter foreground.
  func applicationWillEnterForeground()

  /// Call when the controller has received a user updated notification.
  @discardableResult func requestAvatar(url: URL?, index: Int, isLoggedIn: Bool) -> Task<Void, Never>?
  func currentUserUpdated()

  /// Call when a badge value was received via push notification.
  func didReceiveBadgeValue(_ value: Int?)

  /// Call when selected tab bar index changes.
  func didSelect(index: RootViewControllerIndex)

  /// Call before selected tab bar index changes.
  func shouldSelect(index: RootViewControllerIndex?)

  /// Call when we should open Activity in the current layout.
  func switchToActivities()

  /// Call when we should switch to the discovery tab.
  func switchToDiscovery(params: DiscoveryParams?)

  /// Call when we should switch to the login tab.
  func switchToLogin()

  /// Call when we should switch to the profile tab.
  func switchToProfile()

  /// Call when we should switch to the search tab.
  func switchToSearch()

  /// Call when the a user locale preference has changed.
  /// Used to blow away and re-generate all the tabs, so the entire app reflects changes in user language or currency.
  /// See PR #576.
  func userLocalePreferencesChanged()

  /// Call when the controller has received a user session ended notification.
  func userSessionEnded()

  /// Call when the controller has received a user session started notification.
  func userSessionStarted()

  /// Call from the controller's `viewDidLoad` method.
  func viewDidLoad()

  /// Call when VoiceOver is enabled or disabled
  func voiceOverStatusDidChange()
}

@MainActor
public protocol RootViewModelOutputs: AnyObject {
  /// Emits when the discovery VC should filter with specific params.
  var onFilterDiscovery: (((RootViewControllerIndex, DiscoveryParams)) -> Void)? { get set }

  /// Opens Activity on the Discovery stack when the layout has no Activity tab.
  var onShowActivities: ((RootViewControllerIndex) -> Void)? { get set }

  /// Emits a controller index that should be scrolled to the top. This requires figuring out what kind of
  /// controller it is, and setting its `contentOffset`.
  var onScrollToTop: ((RootViewControllerIndex) -> Void)? { get set }

  /// Emits an index that the tab bar should be switched to.
  var onSelectedIndex: ((RootViewControllerIndex) -> Void)? { get set }

  /// Emits the badge value to be set at a particular tab index
  var onSetBadgeValue: ((RootTabBarItemBadgeValueData) -> Void)? { get set }

  /// Emits the array of view controllers that should be set on the tab bar.
  var onSetViewControllers: (([RootViewControllerData]) -> Void)? { get set }

  /// Emits data for setting tab bar item styles.
  var onAvatarImage: ((Data, URL, Int) -> Void)? { get set }
  var onTabBarItemsData: ((TabBarItemsData) -> Void)? { get set }

  /// Emits an already committed User for the existing user-updated notification.
  var onUserUpdated: ((User) -> Void)? { get set }

  /// Emits when the floating tab bar feature is enabled or disabled.
  var onFloatingTabBarEnabled: ((Bool) -> Void)? { get set }
}

@MainActor
public protocol RootViewModelType {
  var inputs: RootViewModelInputs { get }
  var outputs: RootViewModelOutputs { get }
}

@MainActor
public final class RootViewModel: RootViewModelType, RootViewModelInputs, RootViewModelOutputs {
  private let sessionFeature: SessionFeature
  private let profileFeature: ProfileFeature
  private let activityFeature: ActivityFeature
  private let settingsFeature: SettingsFeature
  private var controllers: [RootViewControllerData] = []
  private var selectedTab: RootTab = .discovery
  private var lastUserSelectedTab: RootTab = .discovery
  private var lastSearchOrigin: KSRAnalytics.TabBarItemLabel?
  private var profileTab: (isLoggedIn: Bool, avatarURL: URL?) = (false, nil)
  private var appliedFloatingFlag: Bool?
  private var hasLoadedRootView = false
  private var activityBadge: (count: Int?, label: String?)?
  private var avatarTask: Task<Void, Never>?
  private var avatarID: UUID?
  private var avatarInput: (URL, Int, Int)?
  public var onAvatarImage: ((Data, URL, Int) -> Void)?
  private var badgeTask: Task<Void, Never>?
  private var badgePresentationTasks: [UUID: Task<Void, Never>] = [:]
  private var badgeIdentity: (userID: Int, generation: Int, token: UUID)?

  private let analytics: () -> KSRAnalytics
  private let badgePresentationDelay: () -> TimeInterval
  private let isVoiceOverRunning: () -> Bool

  public init(
    sessionFeature: SessionFeature,
    profileFeature: ProfileFeature,
    activityFeature: ActivityFeature,
    settingsFeature: SettingsFeature,
    analytics: @escaping () -> KSRAnalytics,
    badgePresentationDelay: @escaping () -> TimeInterval,
    isVoiceOverRunning: @escaping () -> Bool
  ) {
    self.sessionFeature = sessionFeature
    self.profileFeature = profileFeature
    self.activityFeature = activityFeature
    self.settingsFeature = settingsFeature
    self.analytics = analytics
    self.badgePresentationDelay = badgePresentationDelay
    self.isVoiceOverRunning = isVoiceOverRunning
  }

  private func refreshCurrentUser() {
    let user = self.sessionFeature.currentUser
    let isLoggedIn = user != nil
    let loginChanged = self.profileTab.isLoggedIn != isLoggedIn
    self.profileTab = (isLoggedIn, user.flatMap { URL(string: $0.avatar.small) })
    if loginChanged { self.rebuildViewControllers() }
    self.publishTabItemsIfReady()
  }

  private func applyFloatingLayoutIfChanged() {
    let enabled = self.settingsFeature.isRemoteConfigurationEnabled(.floatingTabBar)
    guard self.appliedFloatingFlag != enabled else { return }
    self.appliedFloatingFlag = enabled
    self.onFloatingTabBarEnabled?(enabled)
    self.rebuildViewControllers()
    self.publishTabItemsIfReady()
  }

  private func index(of tab: RootTab) -> RootViewControllerIndex? {
    self.controllers.firstIndex { $0.tab == tab }
  }

  private func rebuildViewControllers() {
    guard let floating = self.appliedFloatingFlag else { return }
    self.controllers = generateViewControllers(
      isLoggedIn: self.profileTab.isLoggedIn,
      isFloatingTabBarEnabled: floating
    )
    if self.index(of: self.selectedTab) == nil { self.selectedTab = .discovery }
    if self.index(of: self.lastUserSelectedTab) == nil { self.lastUserSelectedTab = .discovery }
    self.onSetViewControllers?(self.controllers)
    self.publishSelectedIndexIfReady()
  }

  private func publishTabItemsIfReady() {
    guard !self.controllers.isEmpty else { return }
    let items = self.controllers.enumerated().map { index, controller in
      controller.tab.item(index: index, avatarURL: self.profileTab.avatarURL)
    }
    self.onTabBarItemsData?(TabBarItemsData(items: items, isLoggedIn: self.profileTab.isLoggedIn))
  }

  private func trackTabSelection(_ tab: RootTab) {
    let origin = self.lastUserSelectedTab.analyticsLabel
    self.lastUserSelectedTab = tab
    if tab == .search, self.lastSearchOrigin != origin {
      self.lastSearchOrigin = origin
      self.analytics().trackSearchTabBarClicked(prevTabBarItemLabel: origin)
    }
    self.analytics().trackTabBarClicked(
      tabBarItemLabel: tab.analyticsLabel,
      previousTabBarItemLabel: origin
    )
  }

  private func select(_ tab: RootTab) {
    self.selectedTab = tab
    self.publishSelectedIndexIfReady()
  }

  private func publishSelectedIndexIfReady() {
    guard self.hasLoadedRootView, let index = self.index(of: self.selectedTab) else { return }
    self.onSelectedIndex?(index)
    self.clearBadgeIfActivitySelected()
  }

  private func updateActivityBadge(_ value: Int?) {
    let hasPPOAction = self.sessionFeature.currentUserPPOSettings?.hasAction ?? false
    let label = activitiesBadgeValue(
      with: value, hasPPOAction: hasPPOAction, isVoiceOverRunning: self.isVoiceOverRunning()
    )
    self.activityBadge = (value, label)
    if let index = self.index(of: .activity) { self.onSetBadgeValue?((label, index)) }
  }

  private func clearBadgeIfActivitySelected() {
    guard self.selectedTab == .activity, self.activityBadge?.label != nil else { return }
    self.updateActivityBadge(self.sessionFeature.currentUser?.erroredBackingsCount)
    self.clearActivityBadge()
  }

  private func clearActivityBadge() {
    guard let userID = self.sessionFeature.currentUser?.id else { return }
    let generation = self.sessionFeature.generation
    if self.badgeIdentity?.userID == userID, self.badgeIdentity?.generation == generation { return }
    self.badgeTask?.cancel() // Presentation only; the admitted shared write continues.
    let token = UUID()
    let sessionFeature = self.sessionFeature
    let request = sessionFeature.startActivityIndicatorClearAndUserRefresh()
    self.badgeIdentity = (userID, generation, token)
    self.badgeTask = Task { [weak self] in
      defer {
        if self?.badgeIdentity?.token == token {
          self?.badgeTask = nil
          self?.badgeIdentity = nil
        }
      }
      do {
        let user = try await request.value
        try Task.checkCancellation()
        guard sessionFeature.isCurrent(userID: userID, generation: generation) else { return }
        self?.scheduleBadgePresentation(user, generation: generation)
      } catch {
        // Preserve silent badge-save failure; the shared throwing command is tested separately.
      }
    }
  }

  private func scheduleBadgePresentation(_ user: User, generation: Int) {
    let delay = self.badgePresentationDelay()
    guard !delay.isInfinite else { return }
    let id = UUID()
    self.badgePresentationTasks[id] = Task { [weak self] in
      defer { self?.badgePresentationTasks[id] = nil }
      do {
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        try Task.checkCancellation()
        guard let self, self.sessionFeature.isCurrent(userID: user.id, generation: generation) else { return }
        self.onUserUpdated?(user)
      } catch { /* Cancellation ends pending presentation. */ }
    }
  }

  func waitForBadgeUpdate() async { await self.badgeTask?.value }
  func waitForBadgePresentation() async {
    for task in self.badgePresentationTasks.values { await task.value }
  }

  @discardableResult public func requestAvatar(url: URL?, index: Int, isLoggedIn: Bool) -> Task<Void, Never>? {
    let generation = self.sessionFeature.generation
    if isLoggedIn, let url, let input = self.avatarInput,
      input.0 == url, input.1 == index, input.2 == generation, self.avatarTask != nil { return self.avatarTask }
    self.avatarTask?.cancel()
    self.avatarID = nil
    self.avatarInput = nil
    guard isLoggedIn, let url else { self.profileFeature.cancelAvatarLoad(); self.avatarTask = nil; return nil }
    let id = UUID()
    self.avatarID = id
    self.avatarInput = (url, index, generation)
    let feature = self.profileFeature
    self.avatarTask = Task { [weak self] in
      defer { if self?.avatarID == id { self?.avatarTask = nil } }
      do {
        let data = try await feature.loadAvatarData(url: url)
        try Task.checkCancellation()
        guard let self, self.avatarID == id else { return }
        self.onAvatarImage?(data, url, index)
      } catch { /* Keep the existing profile icon on a failed image read. */ }
    }
    return self.avatarTask
  }

  deinit {
    self.badgeTask?.cancel()
    self.badgePresentationTasks.values.forEach { $0.cancel() }
    self.avatarTask?.cancel()
  }

  public func applicationWillEnterForeground() {
    guard self.hasLoadedRootView else { return }
    self.applyFloatingLayoutIfChanged()
    self.updateActivityBadge(self.activityFeature.currentApplicationBadgeNumber)
  }

  public func currentUserUpdated() {
    self.refreshCurrentUser()
    if self.hasLoadedRootView {
      self.updateActivityBadge(self.sessionFeature.currentUser?.unseenActivityCount ?? 0)
    }
  }

  public func didReceiveBadgeValue(_ value: Int?) {
    guard self.hasLoadedRootView else { return }
    self.updateActivityBadge(value)
  }

  public func didSelect(index: Int) {
    guard !self.controllers.isEmpty else { return }
    if self.controllers.indices.contains(index) { self.trackTabSelection(self.controllers[index].tab) }
    let selectedIndex = clamp(0, self.controllers.count - 1)(index)
    self.select(self.controllers[selectedIndex].tab)
  }

  public func shouldSelect(index: Int?) {
    guard self.hasLoadedRootView, let index, index == self.index(of: self.selectedTab) else { return }
    self.onScrollToTop?(index)
  }

  public func switchToActivities() {
    if self.index(of: .activity) != nil {
      self.select(.activity)
    } else if let discovery = self.index(of: .discovery) {
      self.select(.discovery)
      self.onShowActivities?(discovery)
    }
  }

  public func switchToDiscovery(params: DiscoveryParams?) {
    self.select(.discovery)
    if let params, let index = self.index(of: .discovery) { self.onFilterDiscovery?((index, params)) }
  }

  public func switchToLogin() {
    guard !self.profileTab.isLoggedIn else { return }
    self.select(.profile)
  }

  public func switchToProfile() {
    guard self.profileTab.isLoggedIn else { return }
    self.select(.profile)
  }

  public func switchToSearch() {
    self.select(.search)
  }

  public func userLocalePreferencesChanged() {
    self.rebuildViewControllers()
    self.publishTabItemsIfReady()
    if let badge = self.activityBadge { self.updateActivityBadge(badge.count) }
  }

  public func userSessionStarted() {
    self.refreshCurrentUser()
  }

  public func userSessionEnded() {
    self.refreshCurrentUser()
    self.updateActivityBadge(nil)
  }

  public func viewDidLoad() {
    self.refreshCurrentUser()
    self.applyFloatingLayoutIfChanged()
    self.hasLoadedRootView = true
    self.select(.discovery)
  }

  public func voiceOverStatusDidChange() {
    if let badge = self.activityBadge { self.updateActivityBadge(badge.count) }
  }

  public var onFilterDiscovery: (((RootViewControllerIndex, DiscoveryParams)) -> Void)?
  public var onShowActivities: ((RootViewControllerIndex) -> Void)?
  public var onScrollToTop: ((RootViewControllerIndex) -> Void)?
  public var onSelectedIndex: ((RootViewControllerIndex) -> Void)?
  public var onSetBadgeValue: ((RootTabBarItemBadgeValueData) -> Void)?
  public var onSetViewControllers: (([RootViewControllerData]) -> Void)?
  public var onTabBarItemsData: ((TabBarItemsData) -> Void)?
  public var onUserUpdated: ((User) -> Void)?
  public var onFloatingTabBarEnabled: ((Bool) -> Void)?

  public var inputs: RootViewModelInputs { return self }
  public var outputs: RootViewModelOutputs { return self }
}

private func generateViewControllers(
  isLoggedIn: Bool,
  isFloatingTabBarEnabled: Bool
) -> [RootViewControllerData] {
  var controllers: [RootViewControllerData] = []
  controllers.append(.discovery)

  guard isFloatingTabBarEnabled == false else {
    controllers.append(.search)
    controllers.append(.profile(isLoggedIn: isLoggedIn))

    return controllers
  }

  if isLoggedIn {
    controllers.append(.pledgedProjectsAndActivities)
  } else {
    controllers.append(.activities)
  }

  controllers.append(.search)
  controllers.append(.profile(isLoggedIn: isLoggedIn))

  return controllers
}

extension TabBarItemsData: Equatable {}
extension TabBarItem: Equatable {}

@MainActor
private func activitiesBadgeValue(
  with value: Int?, hasPPOAction: Bool, isVoiceOverRunning: Bool
) -> String? {
  guard !hasPPOAction else {
    // an empty string will show a dot as badge
    return ""
  }

  let badgeValue = value ?? 0
  let maxBadgeValue = !isVoiceOverRunning ? 99 : badgeValue
  let clampedBadgeValue = min(badgeValue, maxBadgeValue)

  guard clampedBadgeValue > 0 else { return nil }

  return (badgeValue > maxBadgeValue) && !isVoiceOverRunning
    ? Strings.activities_badge_value_plus(activities_badge_value: "\(clampedBadgeValue)")
    : "\(clampedBadgeValue)"
}
