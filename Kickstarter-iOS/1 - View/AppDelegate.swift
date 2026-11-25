import BrazeKit
import BrazeUI
import Firebase
import Foundation
import KDS
#if DEBUG
  @testable import KsApi
#else
  import KsApi
#endif
import Experimentation

import Prelude
import SafariServices
import Segment
import SegmentBrazeUI
import SwiftUI
import UIKit
import UserNotifications

@UIApplicationMain
internal final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  private let deepLinkRouter: DeepLinkRouter = {
    let model = AppModel.shared
    return DeepLinkRouter(
      currentSession: { AppModel.shared.currentDeepLinkSession },
      resolveDestination: { try await AppModel.shared.resolveDeepLinkDestination(for: $0, discoveryResponseDelay: $1) },
      firstRedirect: { try await AppModel.shared.resolveEmailLinkDestination(for: $0, route: $1) },
      releaseRedirect: { AppModel.shared.releaseEmailLinkResolution(for: $0) },
      settingsLinks: SettingsLinkPresentation(
        settingsFeature: model.settingsFeature,
        responseDelay: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds }
      ),
      projectPageComposition: model.projectPageComposition,
      serverConfig: { AppEnvironment.current.apiService.serverConfig },
      discoveryResponseDelay: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds }
    )
  }()
  private let navigationRoute = UUID()
  private var continueUserActivityReturnValue = false

  deinit {
    let router = self.deepLinkRouter
    let route = self.navigationRoute
    Task { @MainActor in router.release(route: route) }
  }

  // Custom Braze cancellable type. As long as we keep a reference to this active, Braze will
  // use this to tell us about any Braze push notifications the app handles.
  fileprivate var brazeSubscription: BrazeKit.Braze.Cancellable?

  private var analytics: Segment.Analytics?
  private weak var braze: Braze?

  private var appNotificationObservers: [MainActorNotificationObservation] = []

  private var remoteConfigListener: ConfigUpdateListenerRegistration?
  private let permissionAlertPresenter = ContextualPermissionAlertPresenter()

  // Never enable demo integration policy in a production build, even with a public config.
  private var isPublicDemo: Bool {
    #if DEBUG
      return KsApi.Secrets.isOSS
    #else
      return false
    #endif
  }

  internal var rootTabBarController: RootTabBarViewController? {
    return self.window?.rootViewController as? RootTabBarViewController
  }

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    #if DEBUG
      // Hosted unit tests construct their own screens and environments. Starting the
      // production root here would observe their notifications and emit unrelated events.
      if ProcessInfo.processInfo.environment["CFA_UNIT_TEST_HOST"] == "1" {
        UIView.doBadSwizzleStuff()
        UIViewController.doBadSwizzleStuff()
        InterFont.registerFontIfUnregistered()
        self.window?.rootViewController = UIViewController()
        return true
      }
    #endif

    if !self.isPublicDemo {
      let facebookAppID = Bundle.main.infoDictionary?["FacebookAppID"] as? String
      AppEnvironment.configureFacebookSDK(
        appID: facebookAppID,
        application: application,
        launchOptions: launchOptions
      )

      // Braze expects to be configured immediately, but segment destination plugins are initialized
      // async. This method bridges that gap.
      // https://www.braze.com/docs/developer_guide/sdk_integration#swift_step-2-set-up-delayed-initialization-optional
      Braze.prepareForDelayedInitialization(pushAutomation: self.configuredBrazePushAutomation())
    }

    UIView.doBadSwizzleStuff()
    UIViewController.doBadSwizzleStuff()

    UIImageView.appearance(whenContainedInInstancesOf: [UITabBar.self])
      .accessibilityIgnoresInvertColors = true

    InterFont.registerFontIfUnregistered()

    AppEnvironment.replaceCurrentEnvironment(
      AppEnvironment.fromStorage(
        ubiquitousStore: NSUbiquitousKeyValueStore.default,
        userDefaults: UserDefaults.standard
      )
    )

    #if DEBUG
      if self.isPublicDemo {
        // Only our reserved fixture host is intercepted; no production URL or security policy is changed.
        UIImageView.ksr_configureDemoImageLoading(protocolClass: DemoImageURLProtocol.self)
        AppEnvironment.replaceCurrentEnvironment(
          apiService: MockService.publicDemo(),
          appTrackingTransparency: DemoTrackingConsent(),
          pushRegistrationType: DemoPushRegistration.self,
          remoteConfigClient: nil,
          statsigClient: nil
        )
      }
    #endif

    AppModel.shared.onboardingFeature.onBadgeReset = {
      DispatchQueue.main.async { UIApplication.shared.applicationIconBadgeNumber = 0 }
    }

    AppModel.shared.onboardingFeature.onRegistrationAttempted = {
      DispatchQueue.main.async { print("📲 [Push Registration] Push token registration started 🚀") }
    }

    AppModel.shared.onboardingFeature.onOfferOnboarding = { [weak self] in
      DispatchQueue.main.async { [weak self] in
        guard let rootTabBarController = self?.rootTabBarController else { return }

        let onboardingVC = UIHostingController(
          rootView: OnboardingView { [weak self] in
            self?.presentLogin(with: .onboarding)
          }
        )
        /// Onboarding flow should not respond to light/dark mode preference.
        onboardingVC.overrideUserInterfaceStyle = .light
        onboardingVC.modalPresentationStyle = .fullScreen

        rootTabBarController.navigationController?.isNavigationBarHidden = true
        rootTabBarController.present(onboardingVC, animated: true, completion: nil)
      }
    }

    AppModel.shared.onboardingFeature.onTrackingAuthorizationStatus = { [weak self] status in
      DispatchQueue.main.async { [weak self] in self?.appTrackingAuthorizationChanged(status: status) }
    }

    self.appNotificationObservers = [
      MainActorNotificationObservation(name: .ksr_sessionStarted) { [weak self] _ in
        AppModel.shared.resetFeaturesForSessionChange()
        guard let self else { return }
        self.deepLinkRouter.release(route: self.navigationRoute)
        AppModel.shared.refreshAccountAndCheckSetup(delivering: self.accountRefreshUpdateHandler)
      },
      MainActorNotificationObservation(name: .ksr_showNotificationsDialog) { [weak self] notification in
        guard let context = PushNotificationDialog.eligibleContext(for: notification) else { return }
        DispatchQueue.main.async { [weak self] in
          self?.presentContextualPermissionAlert(notification, context: context)
        }
      },
      MainActorNotificationObservation(name: .ksr_sessionEnded) { [weak self] _ in
        AppModel.shared.resetFeaturesForSessionChange()
        guard let self else { return }
        self.deepLinkRouter.release(route: self.navigationRoute)
        AppModel.shared.refreshAccount(delivering: self.accountRefreshUpdateHandler)
        DispatchQueue.main.async { UIApplication.shared.unregisterForRemoteNotifications() }
      }
    ]

    self.appNotificationObservers.append(Self.observeSegmentConfiguration { [weak self] enabled in
      self?.analytics?.enabled = enabled
    })

    self.window?.tintColor = LegacyColors.ksr_create_700.uiColor()

    AppModel.shared.applicationDidFinishLaunching()

    let shouldContinueLaunch = self.deepLinkRouter.routeLaunchShortcut(
      launchOptions?[.shortcutItem], route: self.navigationRoute, perform: self.navigationActionHandler
    )
    AppModel.shared.refreshAccountAndCheckSetup(delivering: self.accountRefreshUpdateHandler)

    AppModel.shared.prepareNotificationAndTrackingPermissions()
    self.synchronizeUbiquitousPreferences()
    self.configureAnalytics()

    UNUserNotificationCenter.current().delegate = self

    return shouldContinueLaunch
  }

  private var accountRefreshUpdateHandler: @MainActor (AppModel.AccountRefreshUpdate) -> Void {
    { [weak self] in self?.handleAccountRefreshUpdate($0) }
  }

  private func handleAccountRefreshUpdate(_ update: AppModel.AccountRefreshUpdate) {
    switch update {
    case .user:
      DispatchQueue.main.async { [weak self] in
        // The Feature committed already; never replay a delayed whole-user snapshot.
        guard let user = AppModel.shared.sessionFeature.currentUser else { return }
        self?.braze?.changeUser(userId: String(user.id))
        AppEnvironment.current.identify(user: user)
        self?.postUserUpdatedNotification()
      }
    case .invalidSession:
      let session = AppModel.shared.sessionFeature
      let userID = session.currentUser?.id
      let generation = session.generation
      DispatchQueue.main.async {
        guard session.isCurrent(userID: userID, generation: generation) else { return }
        AppEnvironment.logout()
        NotificationCenter.default.post(.init(name: .ksr_sessionEnded, object: nil))
      }
    case let .recommendationsAvailable(available):
      let shortcutItems = ShortcutItem.items(hasRecommendations: available)
      let session = AppModel.shared.sessionFeature
      let userID = session.currentUser?.id
      let generation = session.generation
      DispatchQueue.main.async {
        guard session.isCurrent(userID: userID, generation: generation) else { return }
        UIApplication.shared.shortcutItems = shortcutItems.map { $0.applicationShortcutItem }
      }
    }
  }

  private func postUserUpdatedNotification() {
    DispatchQueue.main.async { AppModel.shared.postUserUpdatedNotification() }
  }

  func applicationDidBecomeActive(_: UIApplication) {
    AppModel.shared.setApplicationActive(true)
  }

  func applicationWillResignActive(_: UIApplication) {
    AppModel.shared.setApplicationActive(false)
  }

  func applicationWillEnterForeground(_: UIApplication) {
    AppModel.shared.refreshNotificationAuthorization()
    AppModel.shared.refreshAccountAndCheckSetup(delivering: self.accountRefreshUpdateHandler)
    AppModel.shared.applicationWillEnterForeground()
  }

  func applicationDidEnterBackground(_: UIApplication) {
    self.permissionAlertPresenter.cancel()
    DispatchQueue.main.async { AppModel.shared.applicationDidEnterBackground() }
  }

  func application(
    _: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler _: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    if let result = self.deepLinkRouter.route(
      userActivity: userActivity, route: self.navigationRoute, perform: self.navigationActionHandler
    ) {
      self.continueUserActivityReturnValue = result
    }
    return self.continueUserActivityReturnValue
  }

  func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    // If this is not a Facebook login call, handle the potential deep-link
    guard self.isPublicDemo || !AppEnvironment.current.facebookSDK.handleOpenURL(
      app,
      open: url,
      options: options
    ) else {
      return true
    }

    self.deepLinkRouter.route(url: url, route: self.navigationRoute, perform: self.navigationActionHandler)
    return true
  }

  // MARK: - Remote notifications

  internal func application(
    _: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    Self.handleDeviceToken(
      deviceToken, model: AppModel.shared,
      registerWithMessagingSDK: { [weak self] token in
        DispatchQueue.main.async { [weak self] in self?.braze?.notifications.register(deviceToken: token) }
      },
      onRegistered: { token in
        DispatchQueue.main.async { print("📲 [Push Registration] Push token successfully registered (\(token)) ✨") }
      }
    )
  }

  /// Keep native token delivery independent of the account registration debounce.
  static func handleDeviceToken(
    _ deviceToken: Data, model: AppModel,
    registerWithMessagingSDK: @MainActor (Data) -> Void,
    onRegistered: @escaping @MainActor (String) -> Void
  ) {
    registerWithMessagingSDK(deviceToken)
    model.receiveDeviceToken(deviceToken, onRegistered: onRegistered)
  }

  internal func application(
    _: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    print("🔴 Failed to register for remote notifications: \(error.localizedDescription)")
  }

  internal func application(
    _: UIApplication,
    performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) {
    self.deepLinkRouter.route(
      shortcut: shortcutItem, route: self.navigationRoute, perform: self.navigationActionHandler
    )
    completionHandler(true)
  }

  // MARK: - Functions

  private var navigationActionHandler: DeepLinkRouter.ActionHandler {
    { [weak self] delivery in self?.performNavigationAction(delivery) }
  }

  private func performNavigationAction(_ delivery: DeepLinkRouter.Delivery) {
    guard delivery.isCurrent else { return }
    switch delivery.action {
    case .selectActivity:
      self.enqueueNavigation(delivery) { $0.switchToActivities() }
    case .selectSearch:
      self.enqueueNavigation(delivery) { $0.switchToSearch() }
    case .selectProfile:
      break
    case let .showLogin(intent):
      self.enqueueNavigation(delivery) { [weak self] root in
        self?.presentLogin(with: intent, from: root)
      }
    case let .showDiscovery(params):
      self.enqueueNavigation(delivery) { $0.switchToDiscovery(params: params) }
    case let .showMessageThread(thread):
      self.enqueueNavigation(delivery) { $0.switchToMessageThread(thread) }
    case let .showViewController(controller):
      self.enqueueNavigation(delivery) { root in
        root.dismiss(animated: true, completion: nil)
        root.present(controller, animated: true, completion: nil)
      }
    case let .openBrowser(url):
      UIApplication.shared.open(url)
    case .notificationSettingsUpdated:
      self.notificationSettingsUpdated()
    case let .emailVerificationCompleted(message, success):
      self.emailVerificationCompleted(message: message, success: success)
    }
  }

  private func enqueueNavigation(
    _ delivery: DeepLinkRouter.Delivery, perform: @escaping @MainActor (RootTabBarViewController) -> Void
  ) {
    self.rootTabBarController?.enqueueNavigation(delivery) { [weak self] root in
      guard self?.rootTabBarController === root else { return }
      perform(root)
    }
  }

  private func notificationSettingsUpdated() {
    let session = AppModel.shared.sessionFeature
    let userID = session.currentUser?.id
    let generation = session.generation
    DispatchQueue.main.async { [weak self] in
      // The Feature committed the edit. Read the latest session rather than
      // restoring an older command snapshot after presentation scheduling.
      guard session.isCurrent(userID: userID, generation: generation),
            let user = session.currentUser else { return }
      self?.braze?.changeUser(userId: String(user.id))
      AppEnvironment.current.identify(user: user)
      self?.postUserUpdatedNotification()
    }
  }

  private func emailVerificationCompleted(message: String, success: Bool) {
    let session = AppModel.shared.sessionFeature
    let userID = session.currentUser?.id
    let generation = session.generation
    DispatchQueue.main.async { [weak self] in
      guard session.isCurrent(userID: userID, generation: generation) else { return }
      self?.rootTabBarController?.dismiss(animated: false, completion: nil)
      self?.rootTabBarController?
        .messageBannerViewController?.showBanner(with: success ? .success : .error, message: message)
    }
  }

  private func presentContextualPermissionAlert(
    _ notification: Notification, context: PushNotificationDialog.Context
  ) {
    guard UIApplication.shared.applicationState != .background,
      let presenter = (notification.userInfo?[UserInfoKeys.viewController] as? UIViewController)
        ?? self.rootTabBarController else { return }
    self.permissionAlertPresenter.schedule(context: context, presenter: presenter) {
      AppModel.shared.onboardingFeature.startPushNotificationRegistration()
    }
  }

  private func presentLogin(with intent: LoginIntent) {
    DispatchQueue.main.async { [weak self] in
      guard let self, let root = self.rootTabBarController else { return }
      self.presentLogin(with: intent, from: root)
    }
  }

  private func presentLogin(with intent: LoginIntent, from root: RootTabBarViewController) {
    if let onboarding = root.presentedViewController as? UIHostingController<OnboardingView> {
      onboarding.dismiss(animated: true)
      AppModel.shared.onboardingFeature.markOnboardingCompleted()
    }

    let controller = LoginToutViewController.configuredWith(loginIntent: intent)
    let navigation = UINavigationController(rootViewController: controller)
    navigation.modalPresentationStyle = .formSheet
    root.present(navigation, animated: true, completion: nil)
  }

  private func appTrackingAuthorizationChanged(status: AppTrackingAuthorization) {
    guard !self.isPublicDemo else { return }
    self.updateFirebaseConsent(status: status)

    // We only pass the Segment identifier to Statsig if tracking consent is enabled.
    // Update Statsig if tracking authorization changes.
    let statsigUser = AppEnvironment.current.statsigUser()
    AppEnvironment.current.statsigClient?.reload(withUser: statsigUser)
  }

  private func updateFirebaseConsent(status: AppTrackingAuthorization) {
    // https://developers.google.com/tag-platform/security/guides/app-consent?platform=ios&consentmode=advanced
    let consentStatus: ConsentStatus = if case .authorized = status {
      .granted
    } else {
      .denied
    }
    Analytics.setConsent([
      .analyticsStorage: consentStatus,
      .adStorage: consentStatus,
      .adUserData: consentStatus,
      .adPersonalization: consentStatus
    ])
  }

  private func synchronizeUbiquitousPreferences() {
    guard !self.isPublicDemo else { return }
    DispatchQueue.main.async { AppModel.shared.synchronizeUbiquitousPreferences() }
  }

  private func configureAnalytics() {
    #if RELEASE || INTERNAL_BUILD
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        FirebaseApp.configure()
        AppEnvironment.current.ksrAnalytics.logEventCallback = { event, _ in
          Crashlytics.crashlytics().log(format: "%@", arguments: getVaList([event]))
        }
        self.configureRemoteConfig()
      }
    #endif

    guard !self.isPublicDemo else { return }
    let bundle = AppEnvironment.current.mainBundle
    let statsigKey = Self.statsigSDKKey(for: bundle)
    DispatchQueue.main.async { [weak self] in self?.configureStatsig(with: statsigKey) }
    self.configureSegment(with: Self.segmentWriteKey(for: bundle))
  }

  private func configureSegment(with writeKey: String) {
    let configuration = Analytics.configuredClient(withWriteKey: writeKey)
    configuration.add(plugin: self.configuredBrazeDestination(for: configuration))
    configuration.add(plugin: BrazeDebounceMiddlewarePlugin())
    self.analytics = configuration
    AppEnvironment.current.ksrAnalytics.configureSegmentClient(configuration)

    // Once Segment loads, update the Statsig Client with Segment's anonymous identifier.
    AppEnvironment.current.statsigClient?.reload(withUser: AppEnvironment.current.statsigUser())
  }

  static func segmentWriteKey(for bundle: any NSBundleType) -> String {
    bundle.isRelease ? Secrets.Segment.production : Secrets.Segment.staging
  }

  static func statsigSDKKey(for mainBundle: any NSBundleType) -> StatsigClientSDKKey {
    if mainBundle.isRelease {
      return .productionTier(Secrets.Statsig.production)
    } else if mainBundle.isBeta {
      return .stagingTier(Secrets.Statsig.staging)
    } else if mainBundle.isDebug {
      return .developmentTier(Secrets.Statsig.development)
    }

    return .stagingTier(Secrets.Statsig.sandbox)
  }

  static func observeSegmentConfiguration(
    center: NotificationCenter = .default, update: @escaping @MainActor (Bool) -> Void
  ) -> MainActorNotificationObservation {
    var lastEnabled: Bool?
    return MainActorNotificationObservation(center: center, name: .ksr_configUpdated) { _ in
      let enabled = featureSegmentIsEnabled()
      guard enabled != lastEnabled else { return }
      lastEnabled = enabled
      update(enabled)
    }
  }

  private func configureRemoteConfig() {
    let remoteConfigClient = RemoteConfigClient(with: RemoteConfig.remoteConfig())

    AppModel.shared.requestRemoteConfiguration(client: remoteConfigClient)

    self.remoteConfigListener?.remove()
    self.remoteConfigListener = remoteConfigClient.addOnConfigUpdateListener { configUpdate, error in
      guard let realtimeUpdateError = error else {
        print("🔮 Remote Config Keys Update: \(String(describing: configUpdate?.updatedKeys))")

        return
      }

      print(
        "🔴 Remote Config SDK Config Update Listener Failure: \(realtimeUpdateError.localizedDescription)"
      )
    }
  }

  private func configureStatsig(with key: StatsigClientSDKKey) {
    let client = StatsigWrapper(sdkKey: key, user: AppEnvironment.current.statsigUser())
    AppEnvironment.updateStatsigClient(client)
  }

  private func configuredBrazeDestination(for configuration: Segment.Analytics) -> BrazeDestination {
    return BrazeDestination(
      additionalConfiguration: { configuration in
        configuration.triggerMinimumTimeInterval = 5
        configuration.push.automation = self.configuredBrazePushAutomation()
        // TODO(MBL-2742): Change the logger level to `info` or `error` if it gets tedious.
        configuration.logger.level = .debug
      }
    ) { [weak self] braze in
      guard let self else { return }
      braze.delegate = self
      self.braze = braze

      braze.inAppMessagePresenter = BrazeUI.BrazeInAppMessageUI()

      if let userId = AppModel.shared.sessionFeature.currentUser?.id {
        braze.changeUser(userId: String(userId))
      }

      // This block of code gets called anytime a Braze notification is opened.
      // AWS notifications will not trigger this code.
      self.brazeSubscription = braze.notifications
        .subscribeToUpdates(payloadTypes: [.opened]) { [weak self] payload in
          guard let self else { return }
          // TODO(MBL-2742): Once the migration is stable, revisit if Braze should update the
          // rootTabBar. If not, this block can be deleted.
          if let rootTabBarController = self.rootTabBarController {
            rootTabBarController.didReceiveBadgeValue(payload.badge)
          }
        }
    }
  }

  // This configuration object defines how much automation Braze does. It gets set both when
  // we configure `BrazeDestination` and when we call `Braze.prepareForDelayedInitialization`.
  // https://braze-inc.github.io/braze-swift-sdk/documentation/brazekit/braze/configuration-swift.class/push-swift.class/automation-swift.class/
  private func configuredBrazePushAutomation() -> BrazeKit.Braze.Configuration.Push.Automation {
    let automation: BrazeKit.Braze.Configuration.Push.Automation = true
    automation.automaticSetup = false
    automation.requestAuthorizationAtLaunch = false
    automation.registerDeviceToken = false
    return automation
  }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
  nonisolated public func userNotificationCenter(
    _: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    // Extract only immutable values before crossing to the UI actor.
    let badge = notification.request.content.badge as? Int
    await MainActor.run {
      self.rootTabBarController?.didReceiveBadgeValue(badge)
    }
    return [.banner, .list]
  }

  nonisolated func userNotificationCenter(
    _: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    let content = response.notification.request.content
    let badge = content.badge as? Int
    let envelope: PushEnvelope? = PushEnvelope.decodeJSONDictionary(content.userInfo)
    await MainActor.run {
      guard let rootTabBarController = self.rootTabBarController else { return }
      if let envelope {
        self.deepLinkRouter.route(
          push: envelope, route: self.navigationRoute, perform: self.navigationActionHandler
        )
      }
      rootTabBarController.didReceiveBadgeValue(badge)
    }
  }
}

// MARK: - BrazeDelegate

#if DEBUG
  // These local substitutes report unavailable capabilities without requesting
  // system permissions or claiming that a demo token was registered remotely.
  private enum DemoPushRegistration: PushRegistrationType {
    static func register(
      for _: UNAuthorizationOptions,
      requestAuthorization _: @escaping @MainActor (UNAuthorizationOptions) async -> Bool,
      completion: @escaping @MainActor (Bool) -> Void
    ) -> Task<Void, Never>? {
      completion(false)
      return nil
    }
    static func hasAuthorizedNotifications(completion: @escaping @MainActor (Bool) -> Void) -> Task<Void, Never>? {
      completion(false)
      return nil
    }
  }

  private struct DemoTrackingConsent: AppTrackingTransparencyType {
    var advertisingIdentifier: String? { nil }
    func observeAuthorizationStatus(_ observer: @escaping @MainActor (AppTrackingAuthorization) -> Void) -> UUID {
      observer(.restricted)
      return UUID()
    }
    func removeAuthorizationObserver(_: UUID) {}

    func updateAdvertisingIdentifier() {}
    func shouldRequestAuthorizationStatus() -> Bool { false }
    func requestAndSetAuthorizationStatus(_ completion: ((AppTrackingAuthorization) -> Void)?) {
      completion?(.restricted)
    }
  }
#endif

extension AppDelegate: BrazeDelegate {
  // Intercept all URLs from Braze in-app messages or push notifications.
  // AWS notifications will not trigger this delegate method.
  func braze(_: BrazeKit.Braze, shouldOpenURL context: BrazeKit.Braze.URLContext) -> Bool {
    // Custom handle all urls instead of letting braze try to open them.
    self.deepLinkRouter.route(
      url: context.url, route: self.navigationRoute, source: .braze, perform: self.navigationActionHandler
    )
    return false
  }
}
