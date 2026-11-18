import AlamofireImage
import KDS
import KsApi

import Prelude
import UIKit

@MainActor
internal protocol TabBarControllerScrollable {
  func scrollToTop()
}

extension TabBarControllerScrollable where Self: UIViewController {
  func scrollToTop() {
    if let scrollView = self.view as? UIScrollView {
      scrollView.scrollToTop()
    }
  }
}

public final class RootTabBarViewController: UITabBarController, MessageBannerViewControllerPresenting {
  private typealias PresentationUpdate = @MainActor (RootTabBarViewController) -> Void

  private var applicationWillEnterForegroundObserver: MainActorNotificationObservation?
  public var messageBannerViewController: MessageBannerViewController?
  private var sessionEndedObserver: MainActorNotificationObservation?
  private var sessionStartedObserver: MainActorNotificationObservation?
  private var userUpdatedObserver: MainActorNotificationObservation?
  private var userLocalePreferencesChangedObserver: MainActorNotificationObservation?
  private var voiceOverStatusDidChangeObserver: MainActorNotificationSignalObservation?

  private let composition = AppModel.shared.rootTabComposition
  private var sessionFeature: SessionFeature { self.composition.sessionFeature }
  fileprivate lazy var viewModel: RootViewModelType = RootViewModel(
    sessionFeature: self.composition.sessionFeature,
    profileFeature: self.composition.profileFeature,
    activityFeature: self.composition.activities.activityFeature,
    settingsFeature: self.composition.settingsFeature,
    analytics: self.composition.analytics,
    badgePresentationDelay: self.composition.badgePresentationDelay,
    isVoiceOverRunning: self.composition.isVoiceOverRunning
  )

  /// Keep the applied tab bar mode in sync with the ViewModel (single source of truth)
  /// Accounts for remote config feature flag load issues.
  private var isFloatingTabBarEnabled: Bool = false
  private var lastTabBarItemsData: TabBarItemsData?
  private var standardTabBar: UITabBar?
  private var presentationTask: Task<Void, Never>?
  private var pendingPresentation: [PresentationUpdate] = []
  private var navigationDelivery: DeepLinkRouter.Delivery?

  deinit {
    self.presentationTask?.cancel()
  }

  public override func viewDidLoad() {
    super.viewDidLoad()
    self.delegate = self

    /// Capture the standard (non-floating) tab bar so we can revert safely if we toggle the floating tab bar off later.
    self.standardTabBar = self.tabBar

    self.applicationWillEnterForegroundObserver = MainActorNotificationObservation(name: UIApplication.willEnterForegroundNotification) { [weak self] _ in
      self?.viewModel.inputs.applicationWillEnterForeground()
    }

    self.sessionStartedObserver = MainActorNotificationObservation(name: .ksr_sessionStarted) { [weak self] _ in
        self?.viewModel.inputs.userSessionStarted()
      }

    self.sessionEndedObserver = MainActorNotificationObservation(name: .ksr_sessionEnded) { [weak self] _ in
        self?.viewModel.inputs.userSessionEnded()
      }

    self.userUpdatedObserver = MainActorNotificationObservation(name: .ksr_userUpdated) { [weak self] _ in
        self?.viewModel.inputs.currentUserUpdated()
      }

    self.voiceOverStatusDidChangeObserver = MainActorNotificationSignalObservation(name: UIAccessibility.voiceOverStatusDidChangeNotification) { [weak self] in
      self?.viewModel.inputs.voiceOverStatusDidChange()
    }

    self.viewModel.outputs.onUserUpdated = { _ in
      // SessionFeature already committed; never replay a delayed whole-user payload.
      NotificationCenter.default.post(.init(name: .ksr_userUpdated))
    }

    self.userLocalePreferencesChangedObserver = MainActorNotificationObservation(name: .ksr_userLocalePreferencesChanged) { [weak self] _ in
      self?.viewModel.inputs.userLocalePreferencesChanged()
    }

    self.messageBannerViewController = self.configureMessageBannerViewController(on: self)

    self.viewModel.inputs.viewDidLoad()
  }

  public override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard let data = lastTabBarItemsData else { return }
    self.setTabBarItemStyles(withData: data)
    view.setNeedsLayout()
    view.layoutIfNeeded()
  }

  public override func bindStyles() {
    super.bindStyles()

    _ = self.tabBar
      |> UITabBar.lens.tintColor .~ tabBarSelectedColor
      |> UITabBar.lens.barTintColor .~ tabBarTintColor
  }

  public override func bindViewModel() {
    super.bindViewModel()

    self.viewModel.outputs.onFloatingTabBarEnabled = { [weak self] enabled in
      self?.enqueuePresentation { $0.applyFloatingTabBar(enabled: enabled) }
    }

    self.viewModel.outputs.onSetViewControllers = { [weak self] data in
      self?.enqueuePresentation { controller in
        let tabs = data.compactMap { controller.viewController(from: $0) }
        controller.setViewControllers(tabs.map(UINavigationController.init(rootViewController:)), animated: false)
      }
    }

    self.viewModel.outputs.onSelectedIndex = { [weak self] index in
      self?.enqueuePresentation { controller in
        guard controller.viewControllers?.indices.contains(index) == true else { return }
        controller.selectedIndex = index
      }
    }

    self.viewModel.outputs.onScrollToTop = { [weak self] index in
      self?.enqueuePresentation { controller in
        guard let tabs = controller.viewControllers, tabs.indices.contains(index) else { return }
        scrollToTop(extractViewController(tabs[index]))
      }
    }

    self.viewModel.outputs.onAvatarImage = { [weak self] data, url, index in
        guard let self, let current = self.lastTabBarItemsData, current.isLoggedIn,
          current.items.contains(where: { item in
            if case let .profile(currentURL, currentIndex) = item { return currentURL == url && currentIndex == index }
            return false
          }) else { return }
        let (image, selected) = tabbarAvatarImageFromData(data, isFloatingTabBarEnabled: self.isFloatingTabBarEnabled)
        _ = self.tabBarItem(atIndex: index)
          ?|> profileTabBarItemStyle(isLoggedIn: true)
          ?|> UITabBarItem.lens.image .~ image
          ?|> UITabBarItem.lens.selectedImage .~ selected
      }

    self.viewModel.outputs.onTabBarItemsData = { [weak self] data in
      self?.enqueuePresentation { $0.setTabBarItemStyles(withData: data) }
    }

    self.viewModel.outputs.onFilterDiscovery = { [weak self] data in
      let (index, params) = data
      self?.enqueuePresentation { controller in
        guard let discovery = controller.discoveryNavigationController(at: index)?
          .viewControllers.first as? DiscoveryViewController else { return }
        discovery.filter(with: params)
      }
    }

    self.viewModel.outputs.onShowActivities = { [weak self] index in
      self?.enqueuePresentation { controller in
        guard let discovery = controller.discoveryNavigationController(at: index),
              !(discovery.topViewController is ActivitiesViewController) else { return }
        discovery.pushViewController(
          ActivitiesViewController.instantiate(composition: controller.composition.activities),
          animated: discovery.viewIfLoaded?.window != nil
        )
      }
    }

    self.viewModel.outputs.onSetBadgeValue = { [weak self] data in
      let (value, index) = data
      self?.enqueuePresentation { $0.tabBarItem(atIndex: index)?.badgeValue = value }
    }
  }

  private func enqueuePresentation(_ update: @escaping PresentationUpdate) {
    if let delivery = self.navigationDelivery {
      if delivery.isCurrent { update(self) }
    } else {
      self.schedulePresentation(update)
    }
  }

  // Apply updates after UIKit finishes its current callback, in the order the ViewModel emitted them.
  private func schedulePresentation(_ update: @escaping PresentationUpdate) {
    self.pendingPresentation.append(update)
    guard self.presentationTask == nil else { return }
    self.presentationTask = Task { [weak self] in
      guard let self, !Task.isCancelled else { return }
      while !self.pendingPresentation.isEmpty {
        let updates = self.pendingPresentation
        self.pendingPresentation.removeAll(keepingCapacity: true)
        for update in updates { update(self) }
      }
      self.presentationTask = nil
    }
  }

  func enqueueNavigation(
    _ delivery: DeepLinkRouter.Delivery,
    perform: @escaping @MainActor (RootTabBarViewController) -> Void
  ) {
    self.loadViewIfNeeded()
    self.schedulePresentation { controller in
      guard delivery.isCurrent else { return }
      controller.navigationDelivery = delivery
      defer { controller.navigationDelivery = nil }
      perform(controller)
    }
  }

  func waitForPresentation() async {
    await self.presentationTask?.value
  }

  private func discoveryNavigationController(at index: RootViewControllerIndex) -> UINavigationController? {
    guard let tabs = self.viewControllers, tabs.indices.contains(index),
          let navigation = tabs[index] as? UINavigationController,
          navigation.viewControllers.first is DiscoveryViewController else { return nil }
    return navigation
  }

  public func switchToActivities() {
    self.loadViewIfNeeded()
    self.viewModel.inputs.switchToActivities()
  }

  public func switchToDiscovery(params: DiscoveryParams?) {
    self.loadViewIfNeeded()
    self.viewModel.inputs.switchToDiscovery(params: params)
  }

  public func switchToLogin() {
    self.viewModel.inputs.switchToLogin()
  }

  public func switchToProfile() {
    self.viewModel.inputs.switchToProfile()
  }

  public func switchToSearch() {
    self.loadViewIfNeeded()
    self.viewModel.inputs.switchToSearch()
  }

  public func switchToMessageThread(_ messageThread: MessageThread) {
    guard let userID = self.sessionFeature.currentUser?.id else { return }
    let generation = self.sessionFeature.generation
    self.loadViewIfNeeded()
    self.switchToProfile()

    self.enqueuePresentation { controller in
      guard controller.sessionFeature.isCurrent(userID: userID, generation: generation) else { return }
      controller.showMessageThread(messageThread)
    }
  }

  private func showMessageThread(_ messageThread: MessageThread) {
    guard
      let profileNav = self.viewControllers?.last as? UINavigationController,
      let profileVC = profileNav.viewControllers.first as? BackerDashboardViewController
    else { return }

    let threadsVC = MessageThreadsViewController.configuredWith(
      project: nil,
      refTag: nil,
      composition: self.composition.messaging
    )
    let messageThreadVC = MessagesViewController.configuredWith(
      messageThread: messageThread,
      composition: self.composition.messaging
    )

    self.presentedViewController?.dismiss(animated: false, completion: nil)

    profileNav.setViewControllers(
      [profileVC, threadsVC, messageThreadVC],
      animated: profileNav.viewIfLoaded?.window != nil
    )
  }

  private func configureFloatingTabBarItems(with data: TabBarItemsData) {
    guard let items = self.tabBar.items, items.isEmpty == false else { return }

    data.items.forEach { item in
      switch item {
      case let .home(index):
        self.setFloatingTabBarIcon(imageName: "floating-tabbar-icon-home", at: index)

      case let .search(index):
        self.setFloatingTabBarIcon(imageName: "floating-tabbar-icon-search", at: index)

      case let .profile(_, index):
        /// Only override profile icon if logged out
        guard data.isLoggedIn == false else { break }

        self.setFloatingTabBarIcon(imageName: "floating-tabbar-icon-profile", at: index)

      case .activity:
        break
      }
    }

    /// Remove labels + center icons
    items.forEach {
      $0.title = nil
      $0.imageInsets = UIEdgeInsets(top: 6, left: 0, bottom: -6, right: 0)
    }
  }

  private func setFloatingTabBarIcon(imageName name: String, at index: Int) {
    guard let item = self.tabBarItem(atIndex: index),
          let image = UIImage(named: name)?.withRenderingMode(.alwaysTemplate) else { return }

    item.image = image
    item.selectedImage = image
  }

  fileprivate func setTabBarItemStyles(withData data: TabBarItemsData) {
    self.lastTabBarItemsData = data
    data.items.forEach { item in
      switch item {
      case let .home(index):
        _ = self.tabBarItem(atIndex: index) ?|> homeTabBarItemStyle
      case let .activity(index):
        _ = self.tabBarItem(atIndex: index) ?|> activityTabBarItemStyle
      case let .search(index):
        _ = self.tabBarItem(atIndex: index) ?|> searchTabBarItemStyle
      case let .profile(avatarUrl, index):
        _ = self.tabBarItem(atIndex: index)
          ?|> profileTabBarItemStyle(isLoggedIn: data.isLoggedIn)

        self.viewModel.inputs.requestAvatar(url: avatarUrl, index: index, isLoggedIn: data.isLoggedIn)
      }
    }

    if self.isFloatingTabBarEnabled {
      /// Run last so it overwrites the default tab-bar icons/titles
      self.configureFloatingTabBarItems(with: data)
    }
  }

  fileprivate func isTabBarItemLastItem(for index: Int) -> Bool {
    guard let tabBarItemEndIndex = self.tabBar.items?.endIndex else {
      return false
    }

    return tabBarItemEndIndex - 1 == index
  }

  fileprivate func tabBarItem(atIndex index: Int) -> UITabBarItem? {
    guard let items = self.tabBar.items, items.indices.contains(index) else { return nil }
    return items[index]
  }

  func viewController(from data: RootViewControllerData) -> UIViewController? {
    switch data {
    case .discovery:
      return DiscoveryViewController.instantiate(composition: self.composition.discovery)
    case .activities:
      return ActivitiesViewController.instantiate(composition: self.composition.activities)
    case .pledgedProjectsAndActivities:
      return PPOContainerViewController(composition: self.composition.pledgedProjects)
    case .search:
      return SearchViewController.instantiate(composition: self.composition.search)
    case let .profile(isLoggedIn):
      return isLoggedIn
        ? BackerDashboardViewController.instantiate(
          messagingComposition: self.composition.messaging
        )
        : LoginToutViewController.configuredWith(loginIntent: .loginTab)
    }
  }

  // MARK: - Accessors

  public func didReceiveBadgeValue(_ value: Int?) {
    self.viewModel.inputs.didReceiveBadgeValue(value)
  }

  private func applyFloatingTabBar(enabled: Bool) {
    guard self.isFloatingTabBarEnabled != enabled else { return }

    self.isFloatingTabBarEnabled = enabled

    if enabled {
      guard (self.tabBar is FloatingTabBar) == false else { return }

      /// Replace the UITabBarController’s tab bar with our custom subclass.
      /// UITabBarController has a read-only tabBar property and Apple doesn't provide a public setter or override for it so we need to do it via key-value coding.
      let customTabBar = FloatingTabBar()
      self.setValue(customTabBar, forKey: "tabBar")
      self.bindStyles()
    } else {
      guard let standardTabBar = self.standardTabBar, self.tabBar is FloatingTabBar else { return }

      self.setValue(standardTabBar, forKey: "tabBar")
      self.bindStyles()
    }
  }
}

extension RootTabBarViewController: UITabBarControllerDelegate {
  public func tabBarController(
    _ tabBarController: UITabBarController,
    shouldSelect viewController: UIViewController
  ) -> Bool {
    let index = tabBarController.viewControllers?.firstIndex(of: viewController)
    self.viewModel.inputs.shouldSelect(index: index)
    return true
  }

  public func tabBarController(
    _ tabBarController: UITabBarController,
    didSelect _: UIViewController
  ) {
    self.viewModel.inputs.didSelect(index: tabBarController.selectedIndex)
  }

  public func tabBarController(
    _: UITabBarController,
    animationControllerForTransitionFrom _: UIViewController,
    to _: UIViewController
  ) -> UIViewControllerAnimatedTransitioning? {
    return CrossDissolveTransitionAnimator()
  }
}

@MainActor
private func scrollToTop(_ viewController: UIViewController) {
  if let scrollable = viewController as? TabBarControllerScrollable {
    scrollable.scrollToTop()
  }
}

@MainActor
private func tabbarAvatarImageFromData(
  _ data: Data,
  isFloatingTabBarEnabled: Bool
) -> (defaultImage: UIImage?, selectedImage: UIImage?) {
  let avatar = UIImage(data: data, scale: UIScreen.main.scale)?
    .af.imageRoundedIntoCircle()
    .af.imageAspectScaled(toFit: tabBarAvatarSize)
  avatar?.af.inflate()

  let deselectedImage = strokedRoundImage(
    fromImage: avatar,
    size: tabBarAvatarSize,
    color: isFloatingTabBarEnabled ? .clear : tabBarDeselectedColor
  )
  let selectedImage = strokedRoundImage(
    fromImage: avatar,
    size: tabBarAvatarSize,
    color: isFloatingTabBarEnabled ? Colors.FloatingTabBar.profileIconBorderColor
      .uiColor() : tabBarSelectedColor,
    lineWidth: 2.0
  )

  return (defaultImage: deselectedImage, selectedImage: selectedImage)
}

@MainActor
private func strokedRoundImage(
  fromImage image: UIImage?,
  size: CGSize,
  color: UIColor,
  lineWidth: CGFloat = 2.0
) -> UIImage? {
  UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
  defer { UIGraphicsEndImageContext() }

  let innerRect = CGRect(x: 1.0, y: 1.0, width: size.width - 2.0, height: size.height - 2.0)
  image?.draw(in: innerRect)
  let circle = UIBezierPath(ovalIn: innerRect)
  color.setStroke()
  circle.lineWidth = lineWidth
  circle.stroke()

  return UIGraphicsGetImageFromCurrentImageContext()?.withRenderingMode(.alwaysOriginal)
}

@MainActor
private func extractViewController(_ viewController: UIViewController) -> UIViewController {
  guard
    let navigationController = viewController as? UINavigationController,
    navigationController.viewControllers.count == 1,
    let nestedViewController = navigationController.viewControllers.first else {
    return viewController
  }

  return nestedViewController
}
