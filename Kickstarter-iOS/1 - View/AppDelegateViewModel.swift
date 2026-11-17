import Experimentation
import KsApi

import Prelude
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

  /// Call when the application becomes active `UIApplicationStateActive` and `UIApplicationStateInactive`
  func applicationActive(state: Bool)

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

  /// Call when the `ksr_configUpdated` notification is observed (config updated elsewhere, eg. debug tools).
  func configUpdatedNotificationObserved()

  /// Call when the user taps "OK" from the contextual alert.
  func didAcceptReceivingRemoteNotifications()

  /// Call when the app delegate receives a remote notification.
  func didReceive(remoteNotification notification: [AnyHashable: Any])
  func didReceive(pushEnvelope: PushEnvelope)

  /// Call when the app delegate gets notice of a successful notification registration.
  func didRegisterForRemoteNotifications(withDeviceTokenData data: Data)

  /// Call when the config has been updated the AppEnvironment
  func didUpdateConfig(_ config: Config)

  /// Call when the Remote Config client has been updated in the AppEnvironment
  func didUpdateRemoteConfigClient()

  /// Call when the redirect URL has been found, see `findRedirectUrl` for more information.
  func resolveEmailRedirect(_ url: URL)
  func foundRedirectUrl(_ url: URL)

  /// Call when Remote Config configuration has failed
  func remoteConfigClientConfigurationFailed()

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

  /// Emits the application icon badge number
  var onApplicationIconBadgeNumber: ((Int) -> Void)? { get set }

  /// Emits when the application should configure Firebase
  var onConfigureFirebase: (() -> Void)? { get set }

  /// Emits when the application should configure Segment with an instance of Braze.
  var onConfigureSegmentWithBraze: ((String) -> Void)? { get set }

  /// Emits when the application should configure Statsig
  var onConfigureStatsig: ((StatsigClientSDKKey) -> Void)? { get set }

  /// Return this value in the delegate method.
  var continueUserActivityReturnValue: Bool { get }

  /// Emits the response from email verification with a message and success/failure.
  var onEmailVerificationCompleted: ((String, Bool) -> Void)? { get set }

  /// Emits when the view needs to figure out the redirect URL for the emitted URL.
  /// Required in order to handle email links.
  var onFindRedirectUrl: ((URL) -> Void)? { get set }

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

  /// Emits when the push token registration begins.
  var onPushTokenRegistrationStarted: (() -> Void)? { get set }

  /// Emits the push token that has been successfully registered on the server.
  var onPushTokenSuccessfullyRegistered: ((String) -> Void)? { get set }

  /// Emits when we should register the device push token in Braze.
  var onRegisterPushTokenInBraze: ((Data) -> Void)? { get set }

  /// Emits when application didFinishLaunchingWithOptions.
  var onRequestTrackingAuthorization: (() -> Void)? { get set }

  /// Emits when our config updates with the enabled state for Semgent Analytics.
  var onSegmentEnabled: ((Bool) -> Void)? { get set }

  /// Emits an array of short cut items to put into the shared application.
  var onSetApplicationShortcutItems: (([ShortcutItem]) -> Void)? { get set }

  /// Emits when an alert should be shown.
  var onShowAlert: ((Notification) -> Void)? { get set }

  /// Emits to synchronize iCloud on app launch.
  var onSynchronizeUbiquitousStore: (() -> Void)? { get set }

  /// Emits immediately and when the user's authorization status changes
  var onTrackingAuthorizationStatus: ((AppTrackingAuthorization) -> Void)? { get set }

  /// Emits when application didFinishLaunchingWithOptions and the Onboarding Flow feature flag is enabled.
  var onTriggerOnboardingFlow: (() -> Void)? { get set }

  /// Emits when we should unregister the user from notifications.
  var onUnregisterForRemoteNotifications: (() -> Void)? { get set }

  /// Emits a fresh user to be updated in the app environment.
  var onUpdateCurrentUser: ((User) -> Void)? { get set }

  /// A preference command has already persisted; observers must not re-save its snapshot.
  var onNotificationSettingsUpdated: (() -> Void)? { get set }

  /// Emits a config value that should be updated in the environment.
  var onUpdateConfig: ((Config) -> Void)? { get set }
}

@MainActor
public protocol AppDelegateViewModelType {
  var inputs: AppDelegateViewModelInputs { get }
  var outputs: AppDelegateViewModelOutputs { get }
}

@MainActor
public final class AppDelegateViewModel: AppDelegateViewModelType, AppDelegateViewModelInputs,
  AppDelegateViewModelOutputs {
  var settingsPresentationDelay: @MainActor (TimeInterval) async throws -> Void = { seconds in
    if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
    try Task.checkCancellation()
  }
  private var notificationTasks: [UUID: Task<Void, Never>] = [:]
  private var verificationTask: Task<Void, Never>?
  private let authenticationFeature: AuthenticationFeature
  private let deepLinkRouter: DeepLinkRouter
  private let serverConfig: () -> ServerConfigType
  private let discoveryFeature: DiscoveryFeature
  private let requestApplicationConfiguration: @MainActor () -> Task<Config, Error>
  private let devicePushRegistration: DevicePushRegistrationService
  private let sessionFeature: SessionFeature
  private let settingsFeature: SettingsFeature
  private let onboardingFeature: OnboardingFeature
  private let navigationRoute = UUID()
  @MainActor private final class RedirectObservation {
    var task: Task<Void, Never>?
    var input: URL?
    var id: UUID?
    func cancel() { self.task?.cancel(); self.task = nil; self.input = nil; self.id = nil }
  }
  private let redirectObservation = RedirectObservation()
  private let trackingDelay: @MainActor () async throws -> Void
  private var trackingDelayTasks: [UUID: Task<Void, Never>] = [:]
  private var hasLaunchEvent = false
  private var latestActiveState: Bool?
  private var lastScheduledActiveState: Bool?
  private var configurationTask: Task<Void, Never>?
  private var shortcutTask: Task<Void, Never>?
  private var lastSegmentEnabled: Bool?
  private var pushTasks: [UUID: Task<Void, Never>] = [:]
  private var hasDeniedPushAuthorization = false
  private var trackingObserver: ((any AppTrackingTransparencyType), UUID)?

  public init(
    deepLinkRouter: DeepLinkRouter,
    serverConfig: @escaping () -> ServerConfigType,
    authenticationFeature: AuthenticationFeature,
    discoveryFeature: DiscoveryFeature,
    requestApplicationConfiguration: @escaping @MainActor () -> Task<Config, Error>,
    devicePushRegistration: DevicePushRegistrationService,
    sessionFeature: SessionFeature,
    settingsFeature: SettingsFeature,
    onboardingFeature: OnboardingFeature,
    trackingDelay: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }
  ) {
    self.trackingDelay = trackingDelay
    self.authenticationFeature = authenticationFeature
    self.deepLinkRouter = deepLinkRouter
    self.serverConfig = serverConfig
    self.discoveryFeature = discoveryFeature
    self.requestApplicationConfiguration = requestApplicationConfiguration
    self.devicePushRegistration = devicePushRegistration
    self.sessionFeature = sessionFeature
    self.settingsFeature = settingsFeature
    self.onboardingFeature = onboardingFeature
  }


  deinit {
    self.notificationTasks.values.forEach { $0.cancel() }
    self.verificationTask?.cancel()
    let devicePushRegistration = self.devicePushRegistration
    let settingsFeature = self.settingsFeature
    self.pushTasks.values.forEach { $0.cancel() }
    self.trackingDelayTasks.values.forEach { $0.cancel() }
    self.configurationTask?.cancel()
    self.shortcutTask?.cancel()
    let redirectObservation = self.redirectObservation
    let authenticationFeature = self.authenticationFeature
    let trackingObserver = self.trackingObserver
    let feature = self.deepLinkRouter
    let route = self.navigationRoute
    Task { @MainActor in
      devicePushRegistration.cancelScheduledDelivery()
      settingsFeature.cancelScheduledAccountRefresh()
      settingsFeature.cancelAccountSetupRefresh()
      redirectObservation.cancel()
      if let (tracking, id) = trackingObserver { tracking.removeAuthorizationObserver(id) }
      authenticationFeature.releaseEmailRedirect(route: route)
      feature.release(route: route)
    }
  }

  public var inputs: AppDelegateViewModelInputs { return self }
  public var outputs: AppDelegateViewModelOutputs { return self }
  private func resolveDestination(_ navigation: Navigation) {
    if navigation == .emailClick {
      self.deepLinkRouter.cancelPresentation(route: self.navigationRoute)
      return
    }
    self.redirectObservation.cancel()
    self.authenticationFeature.releaseEmailRedirect(route: self.navigationRoute)
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

  private final class PushOperationState {
    var finished = false
  }

  private func performPushOperation(
    _ start: (@escaping @MainActor (Bool) -> Void) -> Task<Void, Never>?,
    completion: @escaping @MainActor (Bool) -> Void
  ) {
    let id = UUID()
    let state = PushOperationState()
    let task = start { [weak self] value in
      state.finished = true
      self?.pushTasks[id] = nil
      completion(value)
    }
    if let task, !state.finished { self.pushTasks[id] = task }
  }

  private func checkPushAuthorizationForLaunch() {
    if self.hasDeniedPushAuthorization { self.triggerOnboardingIfEligible() }
    self.performPushOperation({ completion in
      AppEnvironment.current.pushRegistrationType.hasAuthorizedNotifications(completion: completion)
    }) { [weak self] authorized in
      guard let self else { return }
      if authorized {
        self.beginPushRegistration()
      } else {
        self.hasDeniedPushAuthorization = true
        self.triggerOnboardingIfEligible()
      }
    }
  }

  private func checkPushAuthorizationForBadge() {
    self.performPushOperation({ completion in
      AppEnvironment.current.pushRegistrationType.hasAuthorizedNotifications(completion: completion)
    }) { [weak self] authorized in
      if authorized { self?.onApplicationIconBadgeNumber?(0) }
    }
  }

  private func beginPushRegistration() {
    self.performPushOperation({ completion in
      AppEnvironment.current.pushRegistrationType.register(
        for: [.alert, .sound, .badge],
        requestAuthorization: { [onboardingFeature = self.onboardingFeature] options in
          await onboardingFeature.requestNotifications(options: options)
        },
        completion: completion
      )
    }) { [weak self] _ in self?.onPushTokenRegistrationStarted?() }
  }

  private func triggerOnboardingIfEligible() {
    guard self.onboardingFeature.shouldOfferOnboarding else { return }
    self.onTriggerOnboardingFlow?()
  }

  private func scheduleTrackingRequestIfNeeded() {
    guard self.hasLaunchEvent, let active = self.latestActiveState,
          self.lastScheduledActiveState != active else { return }
    self.lastScheduledActiveState = active
    let id = UUID()
    let delay = self.trackingDelay
    self.trackingDelayTasks[id] = Task { [weak self] in
      defer { self?.trackingDelayTasks[id] = nil }
      do {
        try await delay()
        try Task.checkCancellation()
        guard active, let self, self.onboardingFeature.hasSeenOnboarding else { return }
        let tracking = AppEnvironment.current.appTrackingTransparency
        if tracking.advertisingIdentifier == nil, tracking.shouldRequestAuthorizationStatus() {
          tracking.requestAndSetAuthorizationStatus(nil)
        }
        self.onRequestTrackingAuthorization?()
      } catch { /* Cancellation ends pending presentation. */ }
    }
  }

  func waitForTrackingRequests() async {
    for task in self.trackingDelayTasks.values { await task.value }
  }

  private func observeTrackingAuthorization() {
    let tracking = AppEnvironment.current.appTrackingTransparency
    if let (previous, id) = self.trackingObserver {
      if (previous as AnyObject) === (tracking as AnyObject) { return }
      previous.removeAuthorizationObserver(id)
    }
    let id = tracking.observeAuthorizationStatus { [weak self] status in
      self?.onTrackingAuthorizationStatus?(status)
    }
    self.trackingObserver = (tracking, id)
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
    self.shortcutTask?.cancel()
    let feature = self.discoveryFeature
    self.shortcutTask = Task { [weak self] in
      do {
        let recommendations = try await feature.hasRecommendations(for: user)
        try Task.checkCancellation()
        let items = shortcutItems(isProjectMember: (user?.stats.memberProjectsCount ?? 0) > 0,
                                  hasRecommendations: recommendations)
        self?.onSetApplicationShortcutItems?(items)
      } catch { /* Failed recommendation reads leave existing shortcuts in place. */ }
    }
  }

  func waitForShortcutUpdate() async { await self.shortcutTask?.value }

  private func refreshUserSetup() {
    self.settingsFeature.refreshAccountSetup {
      NotificationCenter.default.post(.init(name: .ksr_userUpdated))
    }
  }

  private func refreshConfiguration() {
    self.configurationTask?.cancel()
    let request = self.requestApplicationConfiguration()
    self.configurationTask = Task { [weak self] in
      do {
        let config = try await request.value
        try Task.checkCancellation()
        self?.onUpdateConfig?(config)
      } catch { /* Configuration failures leave the current configuration in place. */ }
    }
  }

  func waitForConfiguration() async { await self.configurationTask?.value }

  public func resolveEmailRedirect(_ url: URL) {
    if self.redirectObservation.input == url, self.redirectObservation.task != nil { return }
    self.redirectObservation.task?.cancel()
    self.redirectObservation.input = url
    let id = UUID()
    self.redirectObservation.id = id
    self.deepLinkRouter.release(route: self.navigationRoute)
    let feature = self.authenticationFeature, route = self.navigationRoute
    self.redirectObservation.task = Task { [weak self] in
      defer {
        if self?.redirectObservation.id == id { self?.redirectObservation.task = nil; self?.redirectObservation.input = nil }
      }
      do {
        let destination = try await feature.firstRedirect(url, route: route)
        try Task.checkCancellation()
        guard let self, self.redirectObservation.id == id, let destination else { return }
        self.foundRedirectUrl(destination)
      } catch { /* Preserve the existing silent failure/no-redirect behavior. */ }
    }
  }

  public func applicationContinueUserActivity(_ userActivity: NSUserActivity) -> Bool {
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb {
      if let url = userActivity.webpageURL {
        let match = DeepLinkRouter.match(url, source: .application, config: self.serverConfig())
        self.continueUserActivityReturnValue = match.navigation != nil
        self.handleURL(url, match: match)
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
    self.checkPushAuthorizationForLaunch()
    self.checkPushAuthorizationForBadge()
    self.hasLaunchEvent = true
    self.scheduleTrackingRequestIfNeeded()
    self.observeTrackingAuthorization()
    self.scheduleUserRefresh()
    self.refreshUserSetup()
    self.refreshConfiguration()
    self.onSynchronizeUbiquitousStore?()
    self.onConfigureFirebase?()
    self.onConfigureStatsig?(statsigSDKKey())
    self.onConfigureSegmentWithBraze?(
      AppEnvironment.current.mainBundle.isRelease ? Secrets.Segment.production : Secrets.Segment.staging
    )
  }

  public func applicationWillEnterForeground() {
    self.checkPushAuthorizationForBadge()
    self.scheduleUserRefresh()
    self.refreshUserSetup()
    self.refreshConfiguration()
  }

  public func applicationActive(state: Bool) {
    self.latestActiveState = state
    self.scheduleTrackingRequestIfNeeded()
    self.observeTrackingAuthorization()
  }

  public func applicationPerformActionForShortcutItem(_ item: UIApplicationShortcutItem) {
    guard let shortcut = ShortcutItem(typeString: item.type) else { return }
    self.handleNavigation(navigation(fromShortcutItem: shortcut))
  }

  public func currentUserUpdatedInEnvironment() {
    self.onPostNotification?(Notification(name: .ksr_userUpdated, object: nil))
  }

  public func configUpdatedNotificationObserved() {
    self.publishSegmentEnabledIfChanged()
  }

  private func publishSegmentEnabledIfChanged() {
    let enabled = featureSegmentIsEnabled()
    guard self.lastSegmentEnabled != enabled else { return }
    self.lastSegmentEnabled = enabled
    self.onSegmentEnabled?(enabled)
  }

  public func didReceive(remoteNotification notification: [AnyHashable: Any]) {
    if let envelope = PushEnvelope.decodeJSONDictionary(notification) { self.didReceive(pushEnvelope: envelope) }
  }

  public func didReceive(pushEnvelope: PushEnvelope) {
    if let navigation = navigation(fromPushEnvelope: pushEnvelope, webBaseURL: self.serverConfig().webBaseUrl) {
      self.handleNavigation(navigation)
    }
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

  public func didAcceptReceivingRemoteNotifications() {
    self.beginPushRegistration()
  }

  public func didUpdateConfig(_ config: Config) {
    self.publishSegmentEnabledIfChanged()
    self.onPostNotification?(Notification(name: .ksr_configUpdated, object: nil))
  }

  public func didUpdateRemoteConfigClient() {
    self.onPostNotification?(Notification(name: .ksr_remoteConfigClientConfigured, object: nil))
  }

  public func foundRedirectUrl(_ url: URL) {
    self.handleURL(url)
  }

  public func applicationOpenUrl(
    application: UIApplication?,
    url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any]
  ) -> Bool {
    self.handleURL(url)
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
    self.refreshConfiguration()
    self.onUnregisterForRemoteNotifications?()
  }

  public func userSessionStarted() {
    self.deepLinkRouter.release(route: self.navigationRoute)
    self.scheduleUserRefresh()
    self.refreshUserSetup()
    self.refreshConfiguration()
  }

  public func urlFromBrazeNotification(_ url: URL?) {
    guard let url else { return }
    let match = DeepLinkRouter.match(url, source: .braze, config: self.serverConfig())
    if let navigation = match.navigation { self.handleNavigation(navigation) }
    if match.shouldOpenInBrowser(url) { self.onGoToMobileSafari?(url) }
  }

  private func handleNavigation(_ navigation: Navigation) {
    if case let .settings(.notifications(name, enabled)) = navigation {
      self.updateNotification(name: name, enabled: enabled)
    }
    if navigation == .tab(.activity) { self.onGoToActivity?() }
    if navigation == .tab(.search) { self.onGoToSearch?() }
    if navigation == .tab(.me) { self.onGoToProfile?() }
    if navigation == .tab(.login) { self.onGoToLoginWithIntent?(.generic) }
    if case let .project(_, subpage, _, _) = navigation,
       case .pledge(.manage) = subpage,
       self.sessionFeature.currentUser == nil {
      self.onGoToLoginWithIntent?(.erroredPledge)
    }
    self.resolveDestination(navigation)
  }

  private func handleURL(_ url: URL) {
    self.handleURL(url, match: DeepLinkRouter.match(url, source: .application, config: self.serverConfig()))
  }

  private func handleURL(_ url: URL, match: DeepLinkRouter.URLMatch) {
    let navigation = match.navigation
    if let navigation { self.handleNavigation(navigation) }
    if navigation == .profile(.verifyEmail), let token = accessTokenFromUrl(url) {
      self.verifyEmail(token: token)
    }
    if navigation == .emailClick { self.onFindRedirectUrl?(url) }
    if match.shouldOpenInBrowser(url) { self.onGoToMobileSafari?(url) }
  }

  private func updateNotification(name: String, enabled: Bool) {
    guard let request = self.settingsFeature.requestNotification(named: name, enabled: enabled) else { return }
    let session = self.sessionFeature
    let userID = session.currentUser?.id
    let generation = session.generation
    let operation = session.sessionBound { try await request.value }
    let delay = self.settingsPresentationDelay
    let seconds = AppEnvironment.current.apiDelayInterval.searchDelaySeconds
    let id = UUID()
    self.notificationTasks[id] = Task { [weak self] in
      defer { self?.notificationTasks[id] = nil }
      do {
        _ = try await operation()
        try await delay(seconds)
        try Task.checkCancellation()
        guard session.isCurrent(userID: userID, generation: generation) else { return }
        self?.onNotificationSettingsUpdated?()
      } catch { /* Failed, cancelled or obsolete writes do not report success. */ }
    }
  }

  private func verifyEmail(token: String) {
    self.verificationTask?.cancel()
    let request = self.settingsFeature.requestVerification(token: token)
    let session = self.sessionFeature
    let userID = session.currentUser?.id
    let generation = session.generation
    let operation = session.sessionBound { try await request.value }
    let delay = self.settingsPresentationDelay
    let seconds = AppEnvironment.current.apiDelayInterval.searchDelaySeconds
    self.verificationTask = Task { [weak self] in
      let result: Result<EmailVerificationResponseEnvelope, Error>
      do { result = .success(try await operation()) }
      catch { result = .failure(error) }
      do {
        try await delay(seconds)
        try Task.checkCancellation()
        guard session.isCurrent(userID: userID, generation: generation) else { return }
        switch result {
        case let .success(response): self?.onEmailVerificationCompleted?(response.message, true)
        case let .failure(error):
          if error is CancellationError { return }
          let message = (error as? ErrorEnvelope)?.errorMessages.first ?? Strings.Something_went_wrong_please_try_again()
          self?.onEmailVerificationCompleted?(message, false)
        }
      } catch { /* A newer request or owner cancellation suppresses presentation. */ }
    }
  }

  func waitForSettingsPresentation() async {
    for task in Array(self.notificationTasks.values) { await task.value }
    await self.verificationTask?.value
  }

  public private(set) var applicationDidFinishLaunchingReturnValue = true

  public func remoteConfigClientConfigurationFailed() {
    self.onPostNotification?(Notification(name: .ksr_remoteConfigClientConfigurationFailed, object: nil))
  }

  public var onApplicationIconBadgeNumber: ((Int) -> Void)?
  public var onConfigureFirebase: (() -> Void)?
  public var onConfigureSegmentWithBraze: ((String) -> Void)?
  public var onConfigureStatsig: ((StatsigClientSDKKey) -> Void)?
  public private(set) var continueUserActivityReturnValue = false
  public var onEmailVerificationCompleted: ((String, Bool) -> Void)?
  public var onFindRedirectUrl: ((URL) -> Void)?
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
  public var onPushTokenRegistrationStarted: (() -> Void)?
  public var onPushTokenSuccessfullyRegistered: ((String) -> Void)?
  public var onRegisterPushTokenInBraze: ((Data) -> Void)?
  public var onRequestTrackingAuthorization: (() -> Void)?
  public var onSegmentEnabled: ((Bool) -> Void)?
  public var onSetApplicationShortcutItems: (([ShortcutItem]) -> Void)?
  public var onShowAlert: ((Notification) -> Void)?
  public var onSynchronizeUbiquitousStore: (() -> Void)?
  public var onTrackingAuthorizationStatus: ((AppTrackingAuthorization) -> Void)?
  public var onTriggerOnboardingFlow: (() -> Void)?
  public var onUnregisterForRemoteNotifications: (() -> Void)?
  public var onUpdateCurrentUser: ((User) -> Void)?
  public var onNotificationSettingsUpdated: (() -> Void)?
  public var onUpdateConfig: ((Config) -> Void)?
}

/// Handles the deeplink route with both an id and text based name for a deeplink to categories.
private func deviceToken(fromData data: Data) -> String {
  return data
    .map { String(format: "%02.2hhx", $0 as CVarArg) }
    .joined()
}

@MainActor
private func navigation(fromPushEnvelope envelope: PushEnvelope, webBaseURL: URL) -> Navigation? {
  if let activity = envelope.activity {
    switch activity.category {
    case .backing:
      guard let projectId = activity.projectId else { return nil }
      return .project(.id(projectId), .root, refInfo: RefInfo(.push))
    case .failure, .launch, .success, .cancellation, .suspension:
      guard let projectId = activity.projectId else { return nil }
      return .project(.id(projectId), .root, refInfo: RefInfo(.push))

    case .update:
      guard let projectId = activity.projectId, let updateId = activity.updateId else { return nil }
      return .project(.id(projectId), .update(updateId, .root), refInfo: RefInfo(.push))

    case .commentPost:
      guard let projectId = activity.projectId, let updateId = activity.updateId else { return nil }

      if let commentId = activity.commentId {
        return .project(
          .id(projectId),
          .update(updateId, .commentThread(commentId, activity.replyId)),
          refInfo: RefInfo(.push)
        )
      }
      return .project(.id(projectId), .update(updateId, .comments), refInfo: RefInfo(.push))

    case .commentProject:
      guard let projectId = activity.projectId else { return nil }

      if let commentId = activity.commentId {
        return .project(.id(projectId), .commentThread(commentId, activity.replyId), refInfo: RefInfo(.push))
      }
      return .project(.id(projectId), .comments, refInfo: RefInfo(.push))

    case .follow:
      return .tab(.activity)

    case .funding, .shipped, .unknown, .watch:
      return nil
    }
  }

  if let order = envelope.order {
    let path = order.pledgeManagerPath
    let url = webBaseURL.absoluteString + path
    return .project(.id(order.projectId), .pledgeManagerWebview(url), refInfo: RefInfo(.push))
  }

  if let project = envelope.project {
    return .project(.id(project.id), .root, refInfo: RefInfo(.push))
  }

  if let message = envelope.message {
    return .messages(messageThreadId: message.messageThreadId)
  }

  if let survey = envelope.survey {
    let path = survey.urls.web.survey
    let url = webBaseURL.absoluteString + path
    return .project(.id(survey.projectId), .pledgeManagerWebview(url), refInfo: RefInfo(.push))
  }

  if let update = envelope.update {
    return .project(.id(update.projectId), .update(update.id, .root), refInfo: RefInfo(.push))
  }

  if let erroredPledge = envelope.erroredPledge {
    return .project(.id(erroredPledge.projectId), .pledge(.manage), refInfo: RefInfo(.push))
  }

  return nil
}

// Figures out a `Navigation` to route the user to from a shortcut item.
private func navigation(fromShortcutItem shortcutItem: ShortcutItem) -> Navigation {
  switch shortcutItem {
  case .recommendedForYou:
    let params = .defaults
      |> DiscoveryParams.lens.recommended .~ true
      |> DiscoveryParams.lens.sort .~ .magic
    return .tab(.discovery(params.queryParams))

  case .projectsWeLove:
    let params = .defaults
      |> DiscoveryParams.lens.staffPicks .~ true
      |> DiscoveryParams.lens.sort .~ .magic
    return .tab(.discovery(params.queryParams))

  case .search:
    return .tab(.search)
  }
}

// Figures out which shortcut items to show to a user based on whether they are a project member and/or
// has recommendations.
private func shortcutItems(isProjectMember _: Bool, hasRecommendations: Bool)
  -> [ShortcutItem] {
  var items: [ShortcutItem] = []

  if hasRecommendations {
    items.append(.recommendedForYou)
  }

  items.append(.projectsWeLove)

  if items.count < 4 {
    items.append(.search)
  }

  return items
}

private func dictionary(fromUrlComponents urlComponents: URLComponents) -> [String: String] {
  let queryItems = urlComponents.queryItems ?? []
  return [String: String?].keyValuePairs(queryItems.map { ($0.name, $0.value) }).compact()
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

private func accessTokenFromUrl(_ url: URL?) -> String? {
  return url.flatMap { url in
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
  }?
    .first { item in item.name == "at" }?
    .value
}

@MainActor
private func statsigSDKKey() -> StatsigClientSDKKey {
  let mainBundle = AppEnvironment.current.mainBundle

  if mainBundle.isRelease {
    return .productionTier(Secrets.Statsig.production)
  } else if mainBundle.isBeta {
    return .stagingTier(Secrets.Statsig.staging)
  } else if mainBundle.isDebug {
    return .developmentTier(Secrets.Statsig.development)
  }

  return .stagingTier(Secrets.Statsig.sandbox)
}
