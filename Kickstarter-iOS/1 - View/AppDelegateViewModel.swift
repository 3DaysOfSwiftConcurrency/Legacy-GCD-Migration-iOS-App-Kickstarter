import KsApi

import UIKit
import UserNotifications

public enum NotificationAuthorizationStatus {
  case authorized
  case denied
  case notDetermined
  case provisional
}

@MainActor
public protocol AppDelegateViewModelInputs {
  /// Call when the application is handed off to.
  func applicationContinueUserActivity(_ userActivity: NSUserActivity) -> Bool

  /// Call when the application finishes launching.
  func applicationDidFinishLaunching(
    application: UIApplication?, launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  )

  /// Call when the application will enter foreground.
  func applicationWillEnterForeground()

  /// Call to open a url that was sent to the app
  func applicationOpenUrl(
    application: UIApplication?,
    url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any]
  ) -> Bool

  /// Call when the application receives a request to perform a shortcut action.
  func applicationPerformActionForShortcutItem(_ item: UIApplicationShortcutItem)

  /// Call after having invoked AppEnvironment.updateCurrentUser with a fresh user.
  func currentUserUpdatedInEnvironment()

  /// Call when the app delegate receives a remote notification.
  func didReceive(remoteNotification notification: [AnyHashable: Any])
  func didReceive(pushEnvelope: PushEnvelope)

  /// Call when the app delegate gets notice of a successful notification registration.
  func didRegisterForRemoteNotifications(withDeviceTokenData data: Data)

  /// Call when the contextual PushNotification dialog should be presented.
  func showNotificationDialog(notification: Notification)

  /// Call when Braze in-app notifications send a valid URL.
  func urlFromBrazeNotification(_ url: URL?)

  /// Call when the controller has received a user session ended notification.
  func userSessionEnded()

  /// Call when the controller has received a user session started notification.
  func userSessionStarted()
}

@MainActor
public protocol AppDelegateViewModelOutputs: AnyObject {
  /// The value to return from the delegate's `application:didFinishLaunchingWithOptions:` method.
  var applicationDidFinishLaunchingReturnValue: Bool { get }

  /// Return this value in the delegate method.
  var continueUserActivityReturnValue: Bool { get }

  /// Emits the response from email verification with a message and success/failure.
  var onEmailVerificationCompleted: ((String, Bool) -> Void)? { get set }

  /// Emits when opening the app with an invalid access token.
  var onForceLogout: (() -> Void)? { get set }

  /// Emits when the root view controller should navigate to activity.
  var onGoToActivity: (() -> Void)? { get set }

  /// Emits when the root view controller should navigate to the discovery screen.
  var onGoToDiscovery: ((DiscoveryParams?) -> Void)? { get set }

  /// Emits when the root view controller should present the login modal.
  var onGoToLoginWithIntent: ((LoginIntent) -> Void)? { get set }

  /// Emits a message thread when we should navigate to it.
  var onGoToMessageThread: ((MessageThread) -> Void)? { get set }

  /// Emits when the root view controller should navigate to the user's profile.
  var onGoToProfile: (() -> Void)? { get set }

  /// Emits a URL when we should open it in the safari browser.
  var onGoToMobileSafari: ((URL) -> Void)? { get set }

  /// Emits when the root view controller should navigate to search.
  var onGoToSearch: (() -> Void)? { get set }

  /// Emits an Notification that should be immediately posted.
  var onPostNotification: ((Notification) -> Void)? { get set }

  /// Emits when a view controller should be presented.
  var onPresentViewController: ((UIViewController) -> Void)? { get set }

  /// Emits the push token that has been successfully registered on the server.
  var onPushTokenSuccessfullyRegistered: ((String) -> Void)? { get set }

  /// Emits when we should register the device push token in Braze.
  var onRegisterPushTokenInBraze: ((Data) -> Void)? { get set }

  /// Emits an array of short cut items to put into the shared application.
  var onSetApplicationShortcutItems: (([ShortcutItem]) -> Void)? { get set }

  /// Emits when an alert should be shown.
  var onShowAlert: ((Notification) -> Void)? { get set }

  /// Emits when we should unregister the user from notifications.
  var onUnregisterForRemoteNotifications: (() -> Void)? { get set }

  /// Emits a fresh user to be updated in the app environment.
  var onUpdateCurrentUser: ((User) -> Void)? { get set }

  /// A preference command has already persisted; observers must not re-save its snapshot.
  var onNotificationSettingsUpdated: (() -> Void)? { get set }
}

@MainActor
public protocol AppDelegateViewModelType {
  var inputs: AppDelegateViewModelInputs { get }
  var outputs: AppDelegateViewModelOutputs { get }
}

@MainActor
public final class AppDelegateViewModel: AppDelegateViewModelType, AppDelegateViewModelInputs,
  AppDelegateViewModelOutputs {
  private let deepLinkRouter: DeepLinkRouter
  private let applicationShortcuts: ApplicationShortcutService
  private let devicePushRegistration: DevicePushRegistrationService
  private let sessionFeature: SessionFeature
  private let settingsFeature: SettingsFeature
  private let navigationRoute = UUID()

  init(
    deepLinkRouter: DeepLinkRouter,
    applicationShortcuts: ApplicationShortcutService,
    devicePushRegistration: DevicePushRegistrationService,
    sessionFeature: SessionFeature,
    settingsFeature: SettingsFeature
  ) {
    self.deepLinkRouter = deepLinkRouter
    self.applicationShortcuts = applicationShortcuts
    self.devicePushRegistration = devicePushRegistration
    self.sessionFeature = sessionFeature
    self.settingsFeature = settingsFeature
  }


  deinit {
    let devicePushRegistration = self.devicePushRegistration
    let settingsFeature = self.settingsFeature
    let feature = self.deepLinkRouter
    let route = self.navigationRoute
    Task { @MainActor in
      devicePushRegistration.cancelScheduledDelivery()
      settingsFeature.cancelScheduledAccountRefresh()
      settingsFeature.cancelAccountSetupRefresh()
      feature.release(route: route)
    }
  }

  public var inputs: AppDelegateViewModelInputs { return self }
  public var outputs: AppDelegateViewModelOutputs { return self }
  private func resolveDestination(_ navigation: Navigation) {
    self.deepLinkRouter.presentDestination(navigation, route: self.navigationRoute) { [weak self] destination in
      self?.present(destination)
    }
  }

  private func present(_ destination: DeepLinkRouter.Destination) {
    switch destination {
    case let .discovery(params): self.onGoToDiscovery?(params)
    case let .message(thread): self.onGoToMessageThread?(thread)
    case .survey, .project:
      if let controller = destination.makeViewController(
        isLoggedIn: self.sessionFeature.currentUser != nil
      ) { self.onPresentViewController?(controller) }
    }
  }

  func waitForDestination() async {
    await self.deepLinkRouter.waitForPresentation(route: self.navigationRoute)
  }

  private func scheduleUserRefresh() {
    self.settingsFeature.scheduleAccountRefresh { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let user):
        if let user { self.onUpdateCurrentUser?(user) }
        self.refreshShortcutItems(for: user)
      case .failure(let error):
        if (error as? ErrorEnvelope)?.ksrCode == .AccessTokenInvalid { self.onForceLogout?() }
      }
    }
  }

  func waitForUserRefresh() async {
    await self.settingsFeature.waitForScheduledAccountRefresh()
  }

  private func refreshShortcutItems(for user: User?) {
    self.applicationShortcuts.refresh(for: user) { [weak self] available in
      self?.onSetApplicationShortcutItems?(
        available ? [.recommendedForYou, .projectsWeLove, .search] : [.projectsWeLove, .search]
      )
    }
  }

  func waitForShortcutUpdate() async { await self.applicationShortcuts.waitForRefresh() }

  private func refreshUserSetup() {
    self.settingsFeature.refreshAccountSetup {
      NotificationCenter.default.post(.init(name: .ksr_userUpdated))
    }
  }

  public func applicationContinueUserActivity(_ userActivity: NSUserActivity) -> Bool {
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb {
      if let url = userActivity.webpageURL {
        self.continueUserActivityReturnValue = self.deepLinkRouter.route(
          url: url, route: self.navigationRoute, perform: self.navigationActionHandler
        )
      } else {
        self.continueUserActivityReturnValue = false
      }
    }
    return self.continueUserActivityReturnValue
  }

  public func applicationDidFinishLaunching(
    application: UIApplication?,
    launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) {
    self.applicationDidFinishLaunchingReturnValue = launchOptions?[UIApplication.LaunchOptionsKey.shortcutItem] == nil
    if let item = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
      self.applicationPerformActionForShortcutItem(item)
    }
    self.scheduleUserRefresh()
    self.refreshUserSetup()
  }

  public func applicationWillEnterForeground() {
    self.scheduleUserRefresh()
    self.refreshUserSetup()
  }

  public func applicationPerformActionForShortcutItem(_ item: UIApplicationShortcutItem) {
    guard let shortcut = ShortcutItem(typeString: item.type) else { return }
    self.deepLinkRouter.route(shortcut: shortcut, perform: self.navigationActionHandler)
  }

  public func currentUserUpdatedInEnvironment() {
    self.onPostNotification?(Notification(name: .ksr_userUpdated, object: nil))
  }

  public func didReceive(remoteNotification notification: [AnyHashable: Any]) {
    if let envelope = PushEnvelope.decodeJSONDictionary(notification) { self.didReceive(pushEnvelope: envelope) }
  }

  public func didReceive(pushEnvelope: PushEnvelope) {
    self.deepLinkRouter.route(push: pushEnvelope, perform: self.navigationActionHandler)
  }

  public func didRegisterForRemoteNotifications(withDeviceTokenData data: Data) {
    self.onRegisterPushTokenInBraze?(data)
    self.devicePushRegistration.schedule(token: deviceToken(fromData: data)) { [weak self] token in
      self?.onPushTokenSuccessfullyRegistered?(token)
    }
  }

  func waitForPushRegistration() async {
    await self.devicePushRegistration.waitForScheduledDelivery()
  }

  public func applicationOpenUrl(
    application: UIApplication?,
    url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any]
  ) -> Bool {
    self.deepLinkRouter.route(url: url, route: self.navigationRoute, perform: self.navigationActionHandler)
    return true
  }

  public func showNotificationDialog(notification: Notification) {
    guard let context = notification.userInfo?[UserInfoKeys.context] as? PushNotificationDialog.Context,
          PushNotificationDialog.canShowDialog(for: context) else { return }
    self.onShowAlert?(notification)
  }

  public func userSessionEnded() {
    self.deepLinkRouter.release(route: self.navigationRoute)
    self.scheduleUserRefresh()
    self.onUnregisterForRemoteNotifications?()
  }

  public func userSessionStarted() {
    self.deepLinkRouter.release(route: self.navigationRoute)
    self.scheduleUserRefresh()
    self.refreshUserSetup()
  }

  public func urlFromBrazeNotification(_ url: URL?) {
    guard let url else { return }
    self.deepLinkRouter.route(url: url, route: self.navigationRoute, source: .braze, perform: self.navigationActionHandler)
  }

  private var navigationActionHandler: @MainActor (DeepLinkRouter.Action) -> Void {
    { [weak self] action in self?.performNavigationAction(action) }
  }

  private func performNavigationAction(_ action: DeepLinkRouter.Action) {
    switch action {
    case .selectActivity: self.onGoToActivity?()
    case .selectSearch: self.onGoToSearch?()
    case .selectProfile: self.onGoToProfile?()
    case let .showLogin(intent): self.onGoToLoginWithIntent?(intent)
    case .notificationSettingsUpdated: self.onNotificationSettingsUpdated?()
    case let .emailVerificationCompleted(message, success): self.onEmailVerificationCompleted?(message, success)
    case let .openBrowser(url): self.onGoToMobileSafari?(url)
    case let .resolveDestination(navigation): self.resolveDestination(navigation)
    }
  }

  public private(set) var applicationDidFinishLaunchingReturnValue = true

  public private(set) var continueUserActivityReturnValue = false
  public var onEmailVerificationCompleted: ((String, Bool) -> Void)?
  public var onForceLogout: (() -> Void)?
  public var onGoToActivity: (() -> Void)?
  public var onGoToDiscovery: ((DiscoveryParams?) -> Void)?
  public var onGoToLoginWithIntent: ((LoginIntent) -> Void)?
  public var onGoToMessageThread: ((MessageThread) -> Void)?
  public var onGoToProfile: (() -> Void)?
  public var onGoToMobileSafari: ((URL) -> Void)?
  public var onGoToSearch: (() -> Void)?
  public var onPostNotification: ((Notification) -> Void)?
  public var onPresentViewController: ((UIViewController) -> Void)?
  public var onPushTokenSuccessfullyRegistered: ((String) -> Void)?
  public var onRegisterPushTokenInBraze: ((Data) -> Void)?
  public var onSetApplicationShortcutItems: (([ShortcutItem]) -> Void)?
  public var onShowAlert: ((Notification) -> Void)?
  public var onUnregisterForRemoteNotifications: (() -> Void)?
  public var onUpdateCurrentUser: ((User) -> Void)?
  public var onNotificationSettingsUpdated: (() -> Void)?
}

/// Handles the deeplink route with both an id and text based name for a deeplink to categories.
private func deviceToken(fromData data: Data) -> String {
  return data
    .map { String(format: "%02.2hhx", $0 as CVarArg) }
    .joined()
}

extension ShortcutItem {
  public var applicationShortcutItem: UIApplicationShortcutItem {
    switch self {
    case .projectsWeLove:
      return .init(
        type: self.typeString,
        localizedTitle: Strings.Projects_We_Love(),
        localizedSubtitle: nil,
        icon: UIApplicationShortcutIcon(templateImageName: "shortcut-icon-k"),
        userInfo: nil
      )
    case .recommendedForYou:
      return .init(
        type: self.typeString,
        localizedTitle: Strings.Recommended(),
        localizedSubtitle: nil,
        icon: UIApplicationShortcutIcon(templateImageName: "shortcut-icon-star"),
        userInfo: nil
      )
    case .search:
      return .init(
        type: self.typeString,
        localizedTitle: Strings.tabbar_search(),
        localizedSubtitle: nil,
        icon: UIApplicationShortcutIcon(templateImageName: "shortcut-icon-search"),
        userInfo: nil
      )
    }
  }
}
