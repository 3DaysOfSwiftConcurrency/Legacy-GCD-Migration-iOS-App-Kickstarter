import AppTrackingTransparency
import Experimentation
import UIKit
@testable import Kickstarter_iOS
import GraphAPI

@testable import KsApi


import Prelude
import UserNotifications
import XCTest

@MainActor
final class AppDelegateAnalyticsTests: XCTestCase {
  func testSegmentUsesProductionOnlyForRelease() {
    let release = MockBundle(bundleIdentifier: KickstarterBundleIdentifier.release.rawValue)
    let beta = MockBundle(bundleIdentifier: KickstarterBundleIdentifier.beta.rawValue)

    XCTAssertTrue(AppDelegate.segmentWriteKey(for: release) == Secrets.Segment.production)
    XCTAssertTrue(AppDelegate.segmentWriteKey(for: beta) == Secrets.Segment.staging)
  }

  func testStatsigSelectsTheKeyAndTierForEachBuild() {
    for identifier in [KickstarterBundleIdentifier.release, .beta, .debug, .alpha] {
      let bundle = MockBundle(bundleIdentifier: identifier.rawValue)
      switch (identifier, AppDelegate.statsigSDKKey(for: bundle)) {
      case let (.release, .productionTier(key)): XCTAssertTrue(key == Secrets.Statsig.production)
      case let (.beta, .stagingTier(key)): XCTAssertTrue(key == Secrets.Statsig.staging)
      case let (.debug, .developmentTier(key)): XCTAssertTrue(key == Secrets.Statsig.development)
      case let (.alpha, .stagingTier(key)): XCTAssertTrue(key == Secrets.Statsig.sandbox)
      default: XCTFail("Unexpected Statsig tier for \(identifier)")
      }
    }
  }

  func testSegmentConfigurationPublishesChangesWithoutRepeatingTheSameFlag() async {
    let center = NotificationCenter()
    let values = ValueRecorder<Bool>()
    let observer = AppDelegate.observeSegmentConfiguration(center: center, update: values.record)
    defer { observer.cancel() }

    let enabled = Config.template |> Config.lens.features .~ [Feature.segment.rawValue: true]
    await withEnvironment(config: enabled) {
      values.assertDidNotEmitValue()
      center.post(name: .ksr_configUpdated, object: nil)
      center.post(name: .ksr_configUpdated, object: nil)
      values.assertValues([true])
    }

    let disabled = Config.template |> Config.lens.features .~ [Feature.segment.rawValue: false]
    await withEnvironment(config: disabled) {
      center.post(name: .ksr_configUpdated, object: nil)
      values.assertValues([true, false])
    }
  }
}

@MainActor
final class AppDelegateViewModelTests: TestCase {
  override var requiresSnapshotReferenceSimulator: Bool { false }
  private let settingsFeature = SettingsFeature(
    sessionFeature: SessionFeature(makeProvider: {
      AsyncSessionProvider(service: AppEnvironment.current.apiService)
    }),
    hasStoredCredentials: { AppEnvironment.current.apiService.isAuthenticated },
    refreshDebounce: { try Task.checkCancellation() },
    makeProvider: { AsyncAccountPreferencesProvider(service: AppEnvironment.current.apiService) }
  )
  private lazy var messagingFeature = MessagingFeature(
    sessionFeature: self.settingsFeature.sessionFeature,
    makeProvider: { AsyncMessagingProvider(service: AppEnvironment.current.apiService) }
  )
  private let devicePushRegistration = DevicePushRegistrationService(
    register: { try await AppEnvironment.current.apiService.registerApplicationPushToken($0) },
    debounce: { try Task.checkCancellation() }
  )
  private let pushAuthorization = PushAuthorization(
    pushRegistration: { AppEnvironment.current.pushRegistrationType },
    onboardingFeature: .live()
  )
  private let trackingConsent = AppTrackingConsent(
    tracking: { AppEnvironment.current.appTrackingTransparency },
    hasSeenOnboarding: { AppEnvironment.current.userDefaults.hasSeenOnboarding },
    delay: { try Task.checkCancellation() }
  )
  private var settingsLinkDelay: @MainActor (TimeInterval) async throws -> Void = { _ in
    try Task.checkCancellation()
  }
  private lazy var settingsLinks = SettingsLinkPresentation(
    settingsFeature: self.settingsFeature,
    responseDelay: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds },
    sleep: { [weak self] seconds in try await self?.settingsLinkDelay(seconds) }
  )
  private lazy var deepLinkRouter = DeepLinkRouter(
    sessionFeature: self.settingsFeature.sessionFeature,
    messagingFeature: self.messagingFeature,
    discussionFeature: DiscussionFeature(
      platform: .live(),
      sessionFeature: self.settingsFeature.sessionFeature,
      makeProvider: { AsyncDiscussionProvider(service: AppEnvironment.current.apiService) }
    ),
    discoveryFeature: self.discoveryFeature,
    activityFeature: ActivityFeature(
      sessionFeature: self.settingsFeature.sessionFeature,
      makeProvider: { AsyncActivityProvider(service: AppEnvironment.current.apiService) }
    ),
    authenticationFeature: AuthenticationFeature(
      sessionFeature: self.settingsFeature.sessionFeature,
      makeProvider: { AsyncAuthenticationProvider(service: AppEnvironment.current.apiService) },
      resolveRedirect: { [weak self] url in
        await self?.recordEmailRedirect(url)
      }
    ),
    settingsLinks: self.settingsLinks,
    serverConfig: { AppEnvironment.current.apiService.serverConfig },
    discoveryResponseDelay: { AppEnvironment.current.apiDelayInterval.searchDelaySeconds },
    sleep: { _ in try Task.checkCancellation() }
  )
  private lazy var discoveryFeature = DiscoveryFeature(
    provider: AsyncDiscoveryProvider(), currentUser: { [session = self.settingsFeature.sessionFeature] in
      session.currentUser
    }
  )
  var vm: AppDelegateViewModelType!

  private let applicationIconBadgeNumber = ValueRecorder<Int>()
  private let emailVerificationCompletedMessage = ValueRecorder<String>()
  private let emailVerificationCompletedSuccess = ValueRecorder<Bool>()
  private let findRedirectUrl = ValueRecorder<URL>()
  private var emailRedirectDestination: URL?
  private let forceLogout = ValueRecorder<()>()
  private let goToActivity = ValueRecorder<()>()
  private let goToDiscovery = ValueRecorder<DiscoveryParams?>()
  private let goToLoginWithIntent = ValueRecorder<LoginIntent>()
  private let goToProfile = ValueRecorder<()>()
  private let goToMobileSafari = ValueRecorder<URL>()
  private let goToSearch = ValueRecorder<()>()
  private let postNotificationName = ValueRecorder<Notification.Name>()
  private let presentViewController = ValueRecorder<Int>()
  private let pushRegistrationStarted = ValueRecorder<()>()
  private let pushTokenSuccessfullyRegistered = ValueRecorder<String>()
  private let registerPushTokenInBraze = ValueRecorder<Data>()
  private let setApplicationShortcutItems = ValueRecorder<[ShortcutItem]>()
  private let trackingAuthorizationStatus = ValueRecorder<AppTrackingAuthorization>()
  private let triggerOnboardingFlow = ValueRecorder<()>()
  private let updateCurrentUserInEnvironment = ValueRecorder<User>()
  private let notificationSettingsUpdated = ValueRecorder<Void>()

  private var defaultRootCategoriesTemplate: RootCategoriesEnvelope {
    RootCategoriesEnvelope.template
      |> RootCategoriesEnvelope.lens.categories .~ [
        .art,
        .filmAndVideo,
        .illustration,
        .documentary
      ]
  }

  override func setUp() async throws {
    try await super.setUp()
    MainActor.assumeIsolated { self.bindOutputs() }
  }

  override func tearDown() async throws {
    self.deepLinkRouter.reset()
    await self.deepLinkRouter.waitForOperations()
    await self.settingsFeature.waitForOperations()
    self.messagingFeature.reset()
    await self.messagingFeature.waitForOperations()
    try await super.tearDown()
  }

  func testMessageDeepLinkLoadsThroughSharedFeature() async throws {
    var threads: [MessageThread] = []
    self.vm.outputs.onGoToMessageThread = { threads.append($0) }
    defer { self.vm.outputs.onGoToMessageThread = nil }
    self.vm.inputs.applicationDidFinishLaunching(application: UIApplication.shared, launchOptions: [:])
    let accepted = self.vm.inputs.applicationOpenUrl(
      application: UIApplication.shared,
      url: try XCTUnwrap(URL(string: "https://www.kickstarter.com/messages/42")), options: [:]
    )
    XCTAssertTrue(accepted)
    await self.deepLinkRouter.waitForOperations()
    await self.messagingFeature.waitForOperations()
    XCTAssertEqual(threads.count, 1)
    XCTAssertEqual(threads.first?.id, MessageThread.template.id)
    await self.settingsFeature.waitForOperations()
  }

  private func makeDelegateHandler() -> AppDelegateViewModel {
    let session = self.settingsFeature.sessionFeature
    return AppDelegateViewModel(
      deepLinkRouter: self.deepLinkRouter,
      applicationShortcuts: ApplicationShortcutService(
        session: session,
        hasRecommendations: { [discoveryFeature = self.discoveryFeature] in
          try await discoveryFeature.hasRecommendations(for: $0)
        }
      ),
      sessionFeature: session,
      settingsFeature: self.settingsFeature
    )
  }

  private func bindOutputs() {
    self.vm = self.makeDelegateHandler()
    self.vm.outputs.onNotificationSettingsUpdated = { [weak self] in self?.notificationSettingsUpdated.record(()) }

    self.pushAuthorization.onBadgeReset = { [weak self] in self?.applicationIconBadgeNumber.record(0) }
    self.vm.outputs.onEmailVerificationCompleted = { [weak self] message, success in
      self?.emailVerificationCompletedMessage.record(message)
      self?.emailVerificationCompletedSuccess.record(success)
    }
    self.vm.outputs.onForceLogout = { [weak self] in self?.forceLogout.record(()) }
    self.vm.outputs.onGoToActivity = { [weak self] in self?.goToActivity.record(()) }
    self.vm.outputs.onGoToDiscovery = { [weak self] in self?.goToDiscovery.record($0) }
    self.vm.outputs.onGoToLoginWithIntent = { [weak self] in self?.goToLoginWithIntent.record($0) }
    self.vm.outputs.onGoToProfile = { [weak self] in self?.goToProfile.record(()) }
    self.vm.outputs.onGoToMobileSafari = { [weak self] in self?.goToMobileSafari.record($0) }
    self.vm.outputs.onGoToSearch = { [weak self] in self?.goToSearch.record(()) }
    self.vm.outputs.onPostNotification = { [weak self] in self?.postNotificationName.record($0.name) }
    self.vm.outputs.onPresentViewController = { [weak self] controller in
      guard let navigation = controller as? UINavigationController else { return }
      self?.presentViewController.record(navigation.viewControllers.count)
    }
    self.pushAuthorization.onRegistrationAttempted = { [weak self] in self?.pushRegistrationStarted.record(()) }
    self.vm.outputs.onSetApplicationShortcutItems = { [weak self] in self?.setApplicationShortcutItems.record($0) }
    self.trackingConsent.onAuthorizationStatus = { [weak self] in
      self?.trackingAuthorizationStatus.record($0)
    }
    self.pushAuthorization.onOfferOnboarding = { [weak self] in self?.triggerOnboardingFlow.record(()) }
    self.vm.outputs.onUpdateCurrentUser = { [weak self] in self?.updateCurrentUserInEnvironment.record($0) }
  }

  private func launchApplication(
    application: UIApplication?, launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) {
    self.vm.inputs.applicationDidFinishLaunching(application: application, launchOptions: launchOptions)
    self.pushAuthorization.applicationDidFinishLaunching()
  }

  private func enterForeground() {
    self.pushAuthorization.applicationWillEnterForeground()
    self.vm.inputs.applicationWillEnterForeground()
  }

  func testResetApplicationIconBadgeNumber_registeredForPushNotifications_WillEnterForeground() async {
    MockPushRegistration.authorizedValue = true

    await withEnvironment(pushRegistrationType: MockPushRegistration.self) {
      self.applicationIconBadgeNumber.assertValues([])

      self.enterForeground()

      self.applicationIconBadgeNumber.assertValues([0])
    }
  }

  func testResetApplicationIconBadgeNumber_notRegisteredForPushNotifications_WillEnterForeground() async {
    MockPushRegistration.authorizedValue = false

    await withEnvironment(pushRegistrationType: MockPushRegistration.self) {
      self.applicationIconBadgeNumber.assertValues([])

      self.enterForeground()

      self.applicationIconBadgeNumber.assertValues([])
    }
  }

  func testResetApplicationIconBadgeNumber_registeredForPushNotifications_AppLaunch() async {
    MockPushRegistration.authorizedValue = true

    await withEnvironment(pushRegistrationType: MockPushRegistration.self) {
      self.applicationIconBadgeNumber.assertValues([])

      self.launchApplication(application: UIApplication.shared, launchOptions: nil)

      self.applicationIconBadgeNumber.assertValues([0])
    }
  }

  func testResetApplicationIconBadgeNumber_notRegisteredForPushNotifications_AppLaunch() async {
    MockPushRegistration.authorizedValue = false

    await withEnvironment(pushRegistrationType: MockPushRegistration.self) {
      self.applicationIconBadgeNumber.assertValues([])

      self.launchApplication(application: UIApplication.shared, launchOptions: nil)

      self.applicationIconBadgeNumber.assertValues([])
    }
  }

  func testCurrentUserUpdating_NothingHappensWhenLoggedOut() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )
    self.vm.inputs.applicationWillEnterForeground()
    self.updateCurrentUserInEnvironment.assertDidNotEmitValue()
  }

  func testCurrentUserUpdating_WhenLoggedIn() async {
    let env = AccessTokenEnvelope(accessToken: "deadbeef", user: User.template)
    AppEnvironment.login(env)

    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )
    await (self.vm as? AppDelegateViewModel)?.waitForUserRefresh()
    await self.settingsFeature.waitForOperations()

    self.updateCurrentUserInEnvironment.assertValues([env.user])
    self.postNotificationName.assertDidNotEmitValue()

    self.vm.inputs.currentUserUpdatedInEnvironment()

    self.updateCurrentUserInEnvironment.assertValues([env.user])
    self.postNotificationName.assertValues([.ksr_userUpdated])

    self.vm.inputs.applicationWillEnterForeground()
    await (self.vm as? AppDelegateViewModel)?.waitForUserRefresh()
    await self.settingsFeature.waitForOperations()

    self.updateCurrentUserInEnvironment.assertValues([env.user, env.user])
    self.postNotificationName.assertValues([.ksr_userUpdated])

    self.vm.inputs.currentUserUpdatedInEnvironment()

    self.updateCurrentUserInEnvironment.assertValues([env.user, env.user])
    self.postNotificationName.assertValues(
      [.ksr_userUpdated, .ksr_userUpdated]
    )
  }

  func testCurrentUserUpdating_WithLegacyUserDefaultsUser() async {
    // No current user in the environment, but the api has an oauth token. This can happen when an oauth
    // token is resurrected from the legacy user defaults.
    await withEnvironment(apiService: MockService(oauthToken: OauthToken(token: "deadbeef"))) {
      self.vm.inputs.applicationDidFinishLaunching(
        application: UIApplication.shared,
        launchOptions: [:]
      )
      await (self.vm as? AppDelegateViewModel)?.waitForUserRefresh()
      await self.settingsFeature.waitForOperations()

      self.updateCurrentUserInEnvironment.assertValues([.template])
      self.postNotificationName.assertDidNotEmitValue()

      self.vm.inputs.currentUserUpdatedInEnvironment()

      self.updateCurrentUserInEnvironment.assertValues([.template])
      self.postNotificationName.assertValues([.ksr_userUpdated])
    }
  }

  func testInvalidAccessToken() async {
    let error = ErrorEnvelope(
      errorMessages: ["invalid deadbeef"],
      ksrCode: .AccessTokenInvalid,
      httpCode: 401,
      exception: nil
    )

    await withEnvironment(apiService: MockService(fetchUserSelfError: error), currentUser: .template) {
      self.forceLogout.assertValueCount(0)

      self.vm.inputs.applicationDidFinishLaunching(
        application: UIApplication.shared,
        launchOptions: [:]
      )
      await (self.vm as? AppDelegateViewModel)?.waitForUserRefresh()
      await self.settingsFeature.waitForOperations()

      self.updateCurrentUserInEnvironment.assertDidNotEmitValue()
      self.forceLogout.assertValueCount(1)
    }
  }

  func testPresentViewController() async {
    let apiService = MockService(
      fetchProjectResult: .success(.template),
      fetchUpdateResponse: .template
    )
    await withEnvironment(apiService: apiService) {
      let rootUrl = "https://www.kickstarter.com/"

      self.vm.inputs.applicationDidFinishLaunching(
        application: UIApplication.shared,
        launchOptions: [:]
      )

      self.presentViewController.assertValues([])

      let projectUrl = rootUrl + "projects/tequila/help-me-transform-this-pile-of-wood"
      var result = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: URL(string: projectUrl)!,
        options: [:]
      )
      XCTAssertTrue(result)

      await self.deepLinkRouter.waitForOperations()
      self.presentViewController.assertValues([1])

      let commentsUrl = projectUrl + "/comments"
      result = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: URL(string: commentsUrl)!,
        options: [:]
      )
      XCTAssertTrue(result)

      await self.deepLinkRouter.waitForOperations()
      self.presentViewController.assertValues([1, 2])

      let updatesUrl = projectUrl + "/posts"
      result = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: URL(string: updatesUrl)!,
        options: [:]
      )
      XCTAssertTrue(result)

      await self.deepLinkRouter.waitForOperations()
      self.presentViewController.assertValues([1, 2, 2])

      let updateUrl = projectUrl + "/posts/1399396"
      result = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: URL(string: updateUrl)!,
        options: [:]
      )
      XCTAssertTrue(result)

      await self.deepLinkRouter.waitForOperations()
      self.presentViewController.assertValues([1, 2, 2, 2])

      let updateCommentsUrl = updateUrl + "/comments"
      result = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: URL(string: updateCommentsUrl)!,
        options: [:]
      )
      XCTAssertTrue(result)

      await self.deepLinkRouter.waitForOperations()
      self.presentViewController.assertValues([1, 2, 2, 2, 3])

      let faqUrl = projectUrl + "/faqs"
      result = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: URL(string: faqUrl)!,
        options: [:]
      )
      XCTAssertTrue(result)

      await self.deepLinkRouter.waitForOperations()
      self.presentViewController.assertValues([1, 2, 2, 2, 3, 1])
    }
  }

  func testPresentViewController_ProjectPreviewLink_DisplayPrelaunch_True() async {
    let project = Project.template
      |> Project.lens.displayPrelaunch .~ true

    let apiService = MockService(fetchProjectResult: .success(project))
    await withEnvironment(apiService: apiService) {
      let rootUrl = "https://www.kickstarter.com/"

      self.vm.inputs.applicationDidFinishLaunching(
        application: UIApplication.shared,
        launchOptions: [:]
      )

      self.presentViewController.assertValues([])

      let projectUrl = rootUrl + "projects/tequila/help-me-transform-this-pile-of-wood"
      let result = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: URL(string: projectUrl)!,
        options: [:]
      )
      XCTAssertTrue(result)

      await self.deepLinkRouter.waitForOperations()
      self.presentViewController.assertValues([1])
      self.goToMobileSafari.assertValues([])
    }
  }

  func testPresentViewController_ProjectPreviewLink_DisplayPrelaunch_False() async {
    let project = Project.template
      |> Project.lens.displayPrelaunch .~ false

    let apiService = MockService(fetchProjectResult: .success(project))
    await withEnvironment(apiService: apiService) {
      let rootUrl = "https://www.kickstarter.com/"

      self.vm.inputs.applicationDidFinishLaunching(
        application: UIApplication.shared,
        launchOptions: [:]
      )

      self.presentViewController.assertValues([])

      let projectUrl = rootUrl + "projects/tequila/help-me-transform-this-pile-of-wood"
      let result = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: URL(string: projectUrl)!,
        options: [:]
      )
      XCTAssertTrue(result)

      await self.deepLinkRouter.waitForOperations()
      self.presentViewController.assertValues([1])
      self.goToMobileSafari.assertValues([])
    }
  }

  func testPresentViewController_ProjectPreviewLink_DisplayPrelaunch_Nil() async {
    let project = Project.template
      |> Project.lens.displayPrelaunch .~ nil

    let apiService = MockService(fetchProjectResult: .success(project))
    await withEnvironment(apiService: apiService) {
      let rootUrl = "https://www.kickstarter.com/"

      self.vm.inputs.applicationDidFinishLaunching(
        application: UIApplication.shared,
        launchOptions: [:]
      )

      self.presentViewController.assertValues([])

      let projectUrl = rootUrl + "projects/tequila/help-me-transform-this-pile-of-wood"
      let result = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: URL(string: projectUrl)!,
        options: [:]
      )
      XCTAssertTrue(result)

      await self.deepLinkRouter.waitForOperations()
      self.presentViewController.assertValues([1])
      self.goToMobileSafari.assertValues([])
    }
  }

  func testPresentViewController_ProjectCommentThread_Success() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )

    await withEnvironment(apiService: MockService(fetchCommentRepliesEnvelopeResult: .success(
      CommentRepliesEnvelope
        .successfulRepliesTemplate
    ), fetchProjectResult: .success(.template))) {
      let url =
        "https://\(AppEnvironment.current.apiService.serverConfig.webBaseUrl.host ?? "")/projects/fjorden/fjorden-iphone-photography-reinvented/comments?comment=Q29tbWVudC0zMzY0OTg0MQ%3D%3D"

      let result = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: URL(string: url)!,
        options: [:]
      )
      XCTAssertTrue(result)

      await self.deepLinkRouter.waitForOperations()
      self.presentViewController.assertValues([3])
    }
  }

  func testPresentViewController_ProjectCommentThread_Reply_Success() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )

    await withEnvironment(apiService: MockService(fetchCommentRepliesEnvelopeResult: .success(
      CommentRepliesEnvelope
        .successfulRepliesTemplate
    ), fetchProjectResult: .success(.template))) {
      let url =
        "https://\(AppEnvironment.current.apiService.serverConfig.webBaseUrl.host ?? "")/projects/fjorden/fjorden-iphone-photography-reinvented/comments?comment=Q29tbWVudC0zMzY0OTg0MQ%3D%3D&reply=deadbeef"

      let result = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: URL(string: url)!,
        options: [:]
      )
      XCTAssertTrue(result)

      await self.deepLinkRouter.waitForOperations()
      self.presentViewController.assertValues([3])
    }
  }

  func testPresentViewController_UpdateCommentThread_Success() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )

    await withEnvironment(apiService: MockService(fetchCommentRepliesEnvelopeResult: .success(
      CommentRepliesEnvelope
        .successfulRepliesTemplate
    ), fetchProjectResult: .success(.template))) {
      let url =
        "https://\(AppEnvironment.current.apiService.serverConfig.webBaseUrl.host ?? "")/projects/fjorden/fjorden-iphone-photography-reinvented/posts/3254626/comments?comment=Q29tbWVudC0zMzY0OTg0MQ%3D%3D"

      let result = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: URL(string: url)!,
        options: [:]
      )
      XCTAssertTrue(result)

      await self.deepLinkRouter.waitForOperations()
      self.presentViewController.assertValues([4])
    }
  }

  func testPresentViewController_UpdateCommentThread_Reply_Success() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )

    await withEnvironment(apiService: MockService(fetchCommentRepliesEnvelopeResult: .success(
      CommentRepliesEnvelope
        .successfulRepliesTemplate
    ), fetchProjectResult: .success(.template))) {
      let url =
        "https://\(AppEnvironment.current.apiService.serverConfig.webBaseUrl.host ?? "")/projects/fjorden/fjorden-iphone-photography-reinvented/posts/3254626/comments?comment=Q29tbWVudC0zMzY0OTg0MQ%3D%3D&reply=deadbeef"

      let result = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: URL(string: url)!,
        options: [:]
      )
      XCTAssertTrue(result)

      await self.deepLinkRouter.waitForOperations()
      self.presentViewController.assertValues([4])
    }
  }

  func testGoToActivity() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )

    self.goToActivity.assertValueCount(0)

    let result = self.vm.inputs.applicationOpenUrl(
      application: UIApplication.shared,
      url: URL(string: "https://www.kickstarter.com/activity")!,
      options: [:]
    )
    XCTAssertTrue(result)

    self.goToActivity.assertValueCount(1)
  }

  func testGoToDiscovery() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )

    self.goToDiscovery.assertValues([])

    let result = self.vm.inputs.applicationOpenUrl(
      application: UIApplication.shared,
      url: URL(string: "https://www.kickstarter.com/discover?sort=newest")!,
      options: [:]
    )
    XCTAssertTrue(result)

    let params = .defaults
      |> DiscoveryParams.lens.sort .~ .newest
    await self.deepLinkRouter.waitForOperations()
    self.goToDiscovery.assertValues([params])
  }

  func testGoToDiscovery_NoParams() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )

    self.goToDiscovery.assertValues([])

    let result = self.vm.inputs.applicationOpenUrl(
      application: UIApplication.shared,
      url: URL(string: "https://www.kickstarter.com/discover")!,
      options: [:]
    )
    XCTAssertTrue(result)

    await self.deepLinkRouter.waitForOperations()
    self.goToDiscovery.assertValues([nil])
  }

  func testGoToDiscoveryWithCategoryName_ValidCategoryName_RoutesToCategory() async {
    let mockService = MockService(fetchGraphCategoriesResult: .success(defaultRootCategoriesTemplate))

    await withEnvironment(apiService: mockService) {
      self.vm.inputs.applicationDidFinishLaunching(
        application: UIApplication.shared,
        launchOptions: [:]
      )

      self.goToDiscovery.assertValues([])

      let url = URL(string: "https://www.kickstarter.com/discover/categories/art")!
      let result = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: url,
        options: [:]
      )
      XCTAssertTrue(result)
      await self.settingsFeature.waitForOperations()

      let params = .defaults |> DiscoveryParams.lens.category .~ .art
      await self.deepLinkRouter.waitForOperations()
      self.goToDiscovery.assertValues([params])
    }
  }

  func testGoToDiscoveryWithCategoryName_InvalidCategoryName_DoesNotRouteToAnyCategory() async {
    let mockService = MockService(fetchGraphCategoriesResult: .success(defaultRootCategoriesTemplate))

    await withEnvironment(apiService: mockService) {
      self.vm.inputs.applicationDidFinishLaunching(
        application: UIApplication.shared,
        launchOptions: [:]
      )

      self.goToDiscovery.assertValues([])

      let url = URL(string: "https://www.kickstarter.com/discover/categories/random")!
      let result = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: url,
        options: [:]
      )
      XCTAssertTrue(result)
      await self.settingsFeature.waitForOperations()

      let params = .defaults |> DiscoveryParams.lens.category .~ .none
      await self.deepLinkRouter.waitForOperations()
      self.goToDiscovery.assertValues([params])
    }
  }

  func testGoToDiscoveryWithSubcategoryName_ValidSubcategoryName_RoutesToSubcategory() async {
    let gamesTemplate = RootCategoriesEnvelope.template
      |> RootCategoriesEnvelope.lens.categories .~ [
        .art,
        .filmAndVideo,
        .illustration,
        .documentary,
        .games
      ]

    let mockService = MockService(fetchGraphCategoriesResult: .success(gamesTemplate))

    await withEnvironment(apiService: mockService) {
      self.vm.inputs.applicationDidFinishLaunching(
        application: UIApplication.shared,
        launchOptions: [:]
      )

      self.goToDiscovery.assertValues([])

      let url = URL(string: "https://www.kickstarter.com/discover/categories/games/tabletop%20games")!
      let result = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: url,
        options: [:]
      )
      XCTAssertTrue(result)
      await self.settingsFeature.waitForOperations()

      let params = .defaults |> DiscoveryParams.lens.category .~ .tabletopGames
      await self.deepLinkRouter.waitForOperations()
      self.goToDiscovery.assertValues([params])
    }
  }

  func testGoToDiscoveryWithSubcategoryName_InvalidSubcategoryName_RoutesToCategory() async {
    let gamesTemplate = RootCategoriesEnvelope.template
      |> RootCategoriesEnvelope.lens.categories .~ [
        .art,
        .filmAndVideo,
        .illustration,
        .documentary,
        .games
      ]

    let mockService = MockService(fetchGraphCategoriesResult: .success(gamesTemplate))

    await withEnvironment(apiService: mockService) {
      self.vm.inputs.applicationDidFinishLaunching(
        application: UIApplication.shared,
        launchOptions: [:]
      )

      self.goToDiscovery.assertValues([])

      let url = URL(string: "https://www.kickstarter.com/discover/categories/games/tabletopgames")!
      let result = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: url,
        options: [:]
      )
      XCTAssertTrue(result)
      await self.settingsFeature.waitForOperations()

      let params = .defaults |> DiscoveryParams.lens.category .~ .games
      await self.deepLinkRouter.waitForOperations()
      self.goToDiscovery.assertValues([params])
    }
  }

  func testGoToDiscoveryWithCategoryId_ValidCategoryId_RoutesToCategory() async {
    let routed = expectation(description: "Category discovery route delivered")
    let previousHandler = self.vm.outputs.onGoToDiscovery
    self.vm.outputs.onGoToDiscovery = { params in
      previousHandler?(params)
      routed.fulfill()
    }
    defer { self.vm.outputs.onGoToDiscovery = previousHandler }
    let mockService = MockService(fetchGraphCategoriesResult: .success(defaultRootCategoriesTemplate))

    await withEnvironment(apiService: mockService) {
      self.vm.inputs.applicationDidFinishLaunching(
        application: UIApplication.shared,
        launchOptions: [:]
      )

      self.goToDiscovery.assertValues([])

      let url =
        URL(
          string: "https://www.kickstarter.com/discover/advanced?category_id=1&sort=magic&seed=2714369&page=1"
        )!
      let result = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: url,
        options: [:]
      )
      XCTAssertTrue(result)
      await self.settingsFeature.waitForOperations()

      let params = .defaults |> DiscoveryParams.lens.category .~ .art
        |> DiscoveryParams.lens.sort .~ .magic
        |> DiscoveryParams.lens.seed .~ 2_714_369
        |> DiscoveryParams.lens.page .~ 1
      await self.deepLinkRouter.waitForOperations()
      await fulfillment(of: [routed], timeout: 2)
      self.goToDiscovery.assertValues([params])
    }
  }

  func testGoToDiscoveryWithCategoryId_InvalidCategoryOrSubcategoryId_DoesNotRouteToAnyCategory() async {
    let mockService = MockService(fetchGraphCategoriesResult: .success(defaultRootCategoriesTemplate))

    await withEnvironment(apiService: mockService) {
      self.vm.inputs.applicationDidFinishLaunching(
        application: UIApplication.shared,
        launchOptions: [:]
      )

      self.goToDiscovery.assertValues([])

      let url =
        URL(
          string: "https://www.kickstarter.com/discover/advanced?category_id=9999&sort=magic&seed=2714369&page=1"
        )!
      let result = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: url,
        options: [:]
      )
      XCTAssertTrue(result)
      await self.settingsFeature.waitForOperations()

      let params = .defaults |> DiscoveryParams.lens.category .~ .none
        |> DiscoveryParams.lens.sort .~ .magic
        |> DiscoveryParams.lens.seed .~ 2_714_369
        |> DiscoveryParams.lens.page .~ 1
      await self.deepLinkRouter.waitForOperations()
      self.goToDiscovery.assertValues([params])
    }
  }

  func testGoToDiscoveryWithSubcategoryId_ValidSubcategoryId_RoutesToSubcategory() async {
    let gamesTemplate = RootCategoriesEnvelope.template
      |> RootCategoriesEnvelope.lens.categories .~ [
        .art,
        .filmAndVideo,
        .illustration,
        .documentary,
        .games
      ]

    let mockService = MockService(fetchGraphCategoriesResult: .success(gamesTemplate))

    await withEnvironment(apiService: mockService) {
      self.vm.inputs.applicationDidFinishLaunching(
        application: UIApplication.shared,
        launchOptions: [:]
      )

      self.goToDiscovery.assertValues([])

      let url =
        URL(
          string: "https://www.kickstarter.com/discover/advanced?category_id=34&sort=magic&seed=2714369&page=1"
        )!
      let result = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: url,
        options: [:]
      )
      XCTAssertTrue(result)
      await self.settingsFeature.waitForOperations()

      let params = .defaults |> DiscoveryParams.lens.category .~ .tabletopGames
        |> DiscoveryParams.lens.sort .~ .magic
        |> DiscoveryParams.lens.seed .~ 2_714_369
        |> DiscoveryParams.lens.page .~ 1
      await self.deepLinkRouter.waitForOperations()
      self.goToDiscovery.assertValues([params])
    }
  }

  func testGoToLogin() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )

    self.goToLoginWithIntent.assertValueCount(0)

    let result = self.vm.inputs.applicationOpenUrl(
      application: UIApplication.shared,
      url: URL(string: "https://www.kickstarter.com/authorize")!,
      options: [:]
    )
    XCTAssertTrue(result)

    self.goToLoginWithIntent.assertValueCount(1)
  }

  func testGoToProfile() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )

    self.goToProfile.assertValueCount(0)

    let result = self.vm.inputs.applicationOpenUrl(
      application: UIApplication.shared,
      url: URL(string: "https://www.kickstarter.com/profile/me")!,
      options: [:]
    )
    XCTAssertTrue(result)

    self.goToProfile.assertValueCount(1)
  }

  func testGoToSearch() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )

    self.goToSearch.assertValueCount(0)

    let result = self.vm.inputs.applicationOpenUrl(
      application: UIApplication.shared,
      url: URL(string: "https://www.kickstarter.com/search")!,
      options: [:]
    )
    XCTAssertTrue(result)

    self.goToSearch.assertValueCount(1)
  }

  func testDeeplink_IsActivated_Success() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )

    await withEnvironment(currentUser: nil) {
      let result = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: URL(string: "https://www.kickstarter.com/search")!,
        options: [:]
      )

      XCTAssertTrue(result)

      self.goToSearch.assertValueCount(1)
    }
  }

  private func receiveDeviceToken(_ data: Data) {
    self.devicePushRegistration.receive(
      deviceToken: data,
      registerWithMessagingSDK: { self.registerPushTokenInBraze.record($0) },
      onRegistered: { [weak self] in self?.pushTokenSuccessfullyRegistered.record($0) }
    )
  }

  func testRegisterPushNotifications_Prompted() async {
    let segmentClient = MockTrackingClient()

    MockPushRegistration.authorizedValue = false
    MockPushRegistration.registerValue = true

    await withEnvironment(
      apiService: MockService(),
      currentUser: .template,
      ksrAnalytics: KSRAnalytics(segmentClient: segmentClient),
      pushRegistrationType: MockPushRegistration.self
    ) {
      self.pushRegistrationStarted.assertValueCount(0)
      self.pushTokenSuccessfullyRegistered.assertValueCount(0)

      self.launchApplication(application: UIApplication.shared, launchOptions: [:])
      self.vm.inputs.userSessionStarted()
      self.pushAuthorization.requestAuthorization()

      self.pushRegistrationStarted.assertValueCount(1)

      self.receiveDeviceToken("token".data(using: .utf8)!)
      await (self.vm as? AppDelegateViewModel)?.waitForUserRefresh()
      await self.settingsFeature.waitForOperations()

      await self.devicePushRegistration.waitForScheduledDelivery()
      await self.deepLinkRouter.waitForOperations()
      self.pushTokenSuccessfullyRegistered.assertValueCount(1)

      XCTAssertEqual([], segmentClient.events)
    }
  }

  func testRegisterPushNotifications_PreviouslyAccepted() async {
    let segmentClient = MockTrackingClient()

    MockPushRegistration.authorizedValue = true
    MockPushRegistration.registerValue = true

    await withEnvironment(
      apiService: MockService(),
      currentUser: .template,
      ksrAnalytics: KSRAnalytics(segmentClient: segmentClient),
      pushRegistrationType: MockPushRegistration.self
    ) {
      self.pushRegistrationStarted.assertValueCount(0)
      self.pushTokenSuccessfullyRegistered.assertValueCount(0)

      self.launchApplication(application: UIApplication.shared, launchOptions: [:])
      self.vm.inputs.userSessionStarted()

      self.pushRegistrationStarted.assertValueCount(1)

      self.receiveDeviceToken("token".data(using: .utf8)!)
      await (self.vm as? AppDelegateViewModel)?.waitForUserRefresh()
      await self.settingsFeature.waitForOperations()

      await self.devicePushRegistration.waitForScheduledDelivery()
      await self.deepLinkRouter.waitForOperations()
      self.pushTokenSuccessfullyRegistered.assertValueCount(1)

      XCTAssertEqual([], segmentClient.events)
    }
  }

  func testRegisterPushNotifications_WhenNotPreviouslyAccepted() async {
    let segmentClient = MockTrackingClient()
    MockPushRegistration.authorizedValue = true
    MockPushRegistration.registerValue = true

    await withEnvironment(
      apiService: MockService(),
      currentUser: .template,
      ksrAnalytics: KSRAnalytics(segmentClient: segmentClient),
      pushRegistrationType: MockPushRegistration.self
    ) {
      self.pushRegistrationStarted.assertValueCount(0)
      self.pushTokenSuccessfullyRegistered.assertValueCount(0)

      self.launchApplication(application: UIApplication.shared, launchOptions: [:])
      self.vm.inputs.userSessionStarted()

      self.pushRegistrationStarted.assertValueCount(1)

      self.receiveDeviceToken("token".data(using: .utf8)!)
      await (self.vm as? AppDelegateViewModel)?.waitForUserRefresh()
      await self.settingsFeature.waitForOperations()

      await self.devicePushRegistration.waitForScheduledDelivery()
      await self.deepLinkRouter.waitForOperations()
      self.pushTokenSuccessfullyRegistered.assertValueCount(1)

      XCTAssertEqual([], segmentClient.events)
    }
  }

  func testTrackingPushAuthorizationOptIn() async {
    let segmentClient = MockTrackingClient()

    MockPushRegistration.authorizedValue = false
    MockPushRegistration.registerValue = true

    await withEnvironment(
      currentUser: .template,
      ksrAnalytics: KSRAnalytics(segmentClient: segmentClient),
      pushRegistrationType: MockPushRegistration.self
    ) {
      XCTAssertEqual([], segmentClient.events)

      self.launchApplication(application: UIApplication.shared, launchOptions: [:])
      self.vm.inputs.userSessionStarted()

      self.pushAuthorization.requestAuthorization()
    }
  }

  func testRegisterDeviceToken() async {
    await withEnvironment(currentUser: .template) {
      self.vm.inputs.applicationDidFinishLaunching(
        application: UIApplication.shared,
        launchOptions: [:]
      )
      self.receiveDeviceToken("deadbeef".data(using: .utf8)!)
      await (self.vm as? AppDelegateViewModel)?.waitForUserRefresh()
      await self.settingsFeature.waitForOperations()

      await self.devicePushRegistration.waitForScheduledDelivery()
      await self.deepLinkRouter.waitForOperations()
      self.pushTokenSuccessfullyRegistered.assertValueCount(1)
    }
  }

  func testRegisterPushTokenInBraze() async {
    let data = Data("deadbeef".utf8)

    self.registerPushTokenInBraze.assertDidNotEmitValue()

    await withEnvironment(currentUser: .template) {
      self.vm.inputs.applicationDidFinishLaunching(
        application: UIApplication.shared,
        launchOptions: [:]
      )
      self.receiveDeviceToken(data)

      self.registerPushTokenInBraze.assertValues([data])
      await self.devicePushRegistration.waitForScheduledDelivery()
    }
  }

  func testOpenPushNotification_WhileInBackground() async {
    await withEnvironment(apiService: MockService(fetchProjectResult: .success(.template))) {
      self.vm.inputs.applicationDidFinishLaunching(
        application: UIApplication.shared,
        launchOptions: [:]
      )

      self.presentViewController.assertValueCount(0)

      self.vm.inputs.didReceive(remoteNotification: friendBackingPushData)

      await self.deepLinkRouter.waitForOperations()
      self.presentViewController.assertValueCount(1)
    }
  }

  func testOpenDecodedPushNotification_WhileInBackground() async throws {
    let decoded: PushEnvelope? = PushEnvelope.decodeJSONDictionary(friendBackingPushData)
    let envelope = try XCTUnwrap(decoded)
    await withEnvironment(apiService: MockService(fetchProjectResult: .success(.template))) {
      self.vm.inputs.applicationDidFinishLaunching(
        application: UIApplication.shared,
        launchOptions: [:]
      )
      self.presentViewController.assertValueCount(0)
      self.vm.inputs.didReceive(pushEnvelope: envelope)
      await self.deepLinkRouter.waitForOperations()
      self.presentViewController.assertValueCount(1)
    }
  }

  func testOpenNotification_NewBacking_ForCreator_WithBadData() async {
    var badPushData = backingForCreatorPushData
    var badActivityData = badPushData["activity"] as? [String: AnyObject]
    badActivityData?["project_id"] = nil
    badPushData["activity"] = badActivityData

    self.vm.inputs.didReceive(remoteNotification: badPushData)
  }

  func testOpenNotification_Order() async {
    self.vm.inputs.didReceive(remoteNotification: orderPushData)

    await self.deepLinkRouter.waitForOperations()
    self.presentViewController.assertValueCount(1)
  }

  func testOpenNotification_Order_BadData() async {
    var badPushData = orderPushData
    badPushData["order"]?["id"] = nil

    self.vm.inputs.didReceive(remoteNotification: badPushData)

    self.presentViewController.assertValueCount(0)
  }

  func testOpenNotification_ProjectUpdate() async {
    await withEnvironment(apiService: MockService(fetchProjectResult: .success(.template))) {
      self.vm.inputs.didReceive(remoteNotification: updatePushData)

      await self.deepLinkRouter.waitForOperations()
      self.presentViewController.assertValueCount(1)
    }
  }

  func testOpenNotification_ProjectUpdate_BadData() async {
    var badPushData = updatePushData
    badPushData["activity"]?["update_id"] = nil

    self.vm.inputs.didReceive(remoteNotification: badPushData)

    self.presentViewController.assertValueCount(0)
  }

  func testOpenNotification_SurveyResponse() async {
    self.vm.inputs.didReceive(remoteNotification: surveyResponsePushData)

    await self.deepLinkRouter.waitForOperations()
    self.presentViewController.assertValueCount(1)
  }

  func testOpenNotification_SurveyResponse_BadData() async {
    var badPushData = surveyResponsePushData
    badPushData["survey"]?["id"] = nil

    self.vm.inputs.didReceive(remoteNotification: badPushData)

    self.presentViewController.assertValueCount(0)
  }

  func testOpenNotification_UpdateComment() async {
    await withEnvironment(apiService: MockService(fetchProjectResult: .success(.template))) {
      self.vm.inputs.didReceive(remoteNotification: updateCommentPushData)

      await self.deepLinkRouter.waitForOperations()
      self.presentViewController.assertValueCount(1)
    }
  }

  func testOpenNotification_UpdateComment_BadData() async {
    var badPushData = updatePushData
    badPushData["activity"]?["update_id"] = nil

    self.vm.inputs.didReceive(remoteNotification: badPushData)

    self.presentViewController.assertValueCount(0)
  }

  func testOpenNotification_ProjectComment() async {
    await withEnvironment(apiService: MockService(fetchProjectResult: .success(.template))) {
      self.vm.inputs.didReceive(remoteNotification: projectCommentPushData)

      await self.deepLinkRouter.waitForOperations()
      self.presentViewController.assertValueCount(1)
    }
  }

  func testOpenNotification_ProjectComment_WithBadData() async {
    await withEnvironment(apiService: MockService(fetchProjectResult: .success(.template))) {
      var badPushData = updatePushData
      badPushData["activity"]?["project_id"] = nil

      self.vm.inputs.didReceive(remoteNotification: badPushData)

      self.presentViewController.assertValueCount(0)
    }
  }

  func testOpenNotification_GenericProject() async {
    await withEnvironment(apiService: MockService(fetchProjectResult: .success(.template))) {
      self.vm.inputs.didReceive(remoteNotification: genericProjectPushData)

      await self.deepLinkRouter.waitForOperations()
      self.presentViewController.assertValueCount(1)
    }
  }

  func testOpenNotification_ProjectStateChanges() async {
    await withEnvironment(apiService: MockService(fetchProjectResult: .success(.template))) {
      let states: [Activity.Category] = [.failure, .launch, .success, .cancellation, .suspension]

      self.vm.inputs.applicationDidFinishLaunching(
        application: UIApplication.shared,
        launchOptions: [:]
      )

      for (idx, state) in states.enumerated() {
        var pushData = genericActivityPushData
        pushData["activity"]?["category"] = state.rawValue

        self.vm.inputs.didReceive(remoteNotification: pushData)

        await self.deepLinkRouter.waitForOperations()
        self.presentViewController.assertValueCount(
          idx + 1, "Presents controller for \(state.rawValue) state change."
        )
      }
    }
  }

  func testOpenNotification_PostLike() async {
    await withEnvironment(apiService: MockService(fetchProjectResult: .success(.template))) {
      let pushData: [String: Any] = [
        "aps": [
          "alert": "Blob liked your update: Important message..."
        ],
        "post": [
          "id": 1,
          "project_id": 2
        ]
      ]

      self.vm.inputs.didReceive(remoteNotification: pushData)

      await self.deepLinkRouter.waitForOperations()
      self.presentViewController.assertValues([2])
    }
  }

  func testOpenNotification_UnrecognizedActivityType() async {
    let categories: [Activity.Category] = [.follow, .funding, .unknown, .watch]

    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )

    categories.enumerated().forEach { _, state in
      var pushData = genericActivityPushData
      pushData["activity"]?["category"] = state.rawValue

      self.vm.inputs.didReceive(remoteNotification: pushData)

      self.goToDiscovery.assertValueCount(0)
      self.presentViewController.assertValueCount(0)
    }
  }

  func testContinueUserActivity_ValidActivity() async {
    let userActivity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    userActivity.webpageURL = URL(string: "https://www.kickstarter.com/activity")

    self.vm.inputs.applicationDidFinishLaunching(application: .shared, launchOptions: [:])

    self.goToActivity.assertValueCount(0)
    XCTAssertFalse(self.vm.outputs.continueUserActivityReturnValue)

    let result = self.vm.inputs.applicationContinueUserActivity(userActivity)
    XCTAssertTrue(result)

    self.goToActivity.assertValueCount(1)
    XCTAssertTrue(self.vm.outputs.continueUserActivityReturnValue)
  }

  func testContinueUserActivity_InvalidActivity() async {
    let userActivity = NSUserActivity(activityType: "Other")

    self.vm.inputs.applicationDidFinishLaunching(application: .shared, launchOptions: [:])
    let result = self.vm.inputs.applicationContinueUserActivity(userActivity)
    XCTAssertFalse(result)

    XCTAssertFalse(self.vm.outputs.continueUserActivityReturnValue)
  }

  func testContinueUserActivity_Success() async {
    let userActivity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    userActivity.webpageURL = URL(string: "https://www.kickstarter.com/activity")

    await withEnvironment(currentUser: nil) {
      self.vm.inputs.applicationDidFinishLaunching(application: .shared, launchOptions: [:])

      self.goToActivity.assertValueCount(0)
      XCTAssertFalse(self.vm.outputs.continueUserActivityReturnValue)

      let result = self.vm.inputs.applicationContinueUserActivity(userActivity)
      XCTAssertTrue(result)

      XCTAssertTrue(self.vm.outputs.continueUserActivityReturnValue)
      self.goToActivity.assertValueCount(1)
    }
  }

  func testSetApplicationShortcutItems() async {
    self.setApplicationShortcutItems.assertValues([])

    self.vm.inputs.applicationDidFinishLaunching(application: .shared, launchOptions: [:])

    self.setApplicationShortcutItems.assertValues([])
    await (self.vm as? AppDelegateViewModel)?.waitForUserRefresh()
    await self.settingsFeature.waitForOperations()

    await self.deepLinkRouter.waitForOperations()
    await (self.vm as? AppDelegateViewModel)?.waitForShortcutUpdate()
    self.setApplicationShortcutItems.assertValues([[.projectsWeLove, .search]])

    self.vm.inputs.applicationWillEnterForeground()
    await (self.vm as? AppDelegateViewModel)?.waitForUserRefresh()
    await self.settingsFeature.waitForOperations()

    await self.deepLinkRouter.waitForOperations()
    await (self.vm as? AppDelegateViewModel)?.waitForShortcutUpdate()
    self.setApplicationShortcutItems.assertValues(
      [
        [.projectsWeLove, .search],
        [.projectsWeLove, .search]
      ]
    )
  }

  func testSetApplicationShortcutItems_LoggedInUser_NonMember() async {
    let currentUser = User.template
      |> \.stats.memberProjectsCount .~ 0

    await withEnvironment(
      apiService: MockService(fetchUserSelfResponse: currentUser),
      currentUser: currentUser
    ) {
      self.setApplicationShortcutItems.assertValues([])

      self.vm.inputs.applicationDidFinishLaunching(application: .shared, launchOptions: [:])

      self.setApplicationShortcutItems.assertValues([])
      await (self.vm as? AppDelegateViewModel)?.waitForUserRefresh()
      await self.settingsFeature.waitForOperations()

      await self.deepLinkRouter.waitForOperations()
      await (self.vm as? AppDelegateViewModel)?.waitForShortcutUpdate()
      self.setApplicationShortcutItems.assertValues([
        [.recommendedForYou, .projectsWeLove, .search]
      ])
    }
  }

  func testSetApplicationShortcutItems_LoggedInUser_Member() async {
    let currentUser = User.template
      |> \.stats.memberProjectsCount .~ 2

    await withEnvironment(
      apiService: MockService(fetchUserSelfResponse: currentUser),
      currentUser: currentUser
    ) {
      self.setApplicationShortcutItems.assertValues([])

      self.vm.inputs.applicationDidFinishLaunching(application: .shared, launchOptions: [:])

      self.setApplicationShortcutItems.assertValues([])
      await (self.vm as? AppDelegateViewModel)?.waitForUserRefresh()
      await self.settingsFeature.waitForOperations()

      await self.deepLinkRouter.waitForOperations()
      await (self.vm as? AppDelegateViewModel)?.waitForShortcutUpdate()
      self.setApplicationShortcutItems.assertValues([
        [.recommendedForYou, .projectsWeLove, .search]
      ])
    }
  }

  func testPerformShortcutItem_ProjectsWeLove() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )

    self.goToDiscovery.assertValueCount(0)

    self.vm.inputs.applicationPerformActionForShortcutItem(
      ShortcutItem.projectsWeLove.applicationShortcutItem
    )

    let params = .defaults
      |> DiscoveryParams.lens.staffPicks .~ true
      |> DiscoveryParams.lens.sort .~ .magic
    await self.deepLinkRouter.waitForOperations()
    self.goToDiscovery.assertValues([params])
  }

  func testLaunchShortcutItem_ProjectsWeLove() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [
        UIApplication.LaunchOptionsKey.shortcutItem: ShortcutItem.projectsWeLove.applicationShortcutItem
      ]
    )

    let params = .defaults
      |> DiscoveryParams.lens.staffPicks .~ true
      |> DiscoveryParams.lens.sort .~ .magic
    await self.deepLinkRouter.waitForOperations()
    self.goToDiscovery.assertValues([params])
    XCTAssertFalse(self.vm.outputs.applicationDidFinishLaunchingReturnValue)
  }

  func testPerformShortcutItem_RecommendedForYou() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )

    self.goToDiscovery.assertValueCount(0)

    self.vm.inputs.applicationPerformActionForShortcutItem(
      ShortcutItem.recommendedForYou.applicationShortcutItem
    )

    let params = .defaults
      |> DiscoveryParams.lens.recommended .~ true
      |> DiscoveryParams.lens.sort .~ .magic
    await self.deepLinkRouter.waitForOperations()
    self.goToDiscovery.assertValues([params])
  }

  func testLaunchShortcutItem_RecommendedForYou() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [
        UIApplication.LaunchOptionsKey.shortcutItem: ShortcutItem.recommendedForYou.applicationShortcutItem
      ]
    )

    let params = .defaults
      |> DiscoveryParams.lens.recommended .~ true
      |> DiscoveryParams.lens.sort .~ .magic
    await self.deepLinkRouter.waitForOperations()
    self.goToDiscovery.assertValues([params])
    XCTAssertFalse(self.vm.outputs.applicationDidFinishLaunchingReturnValue)
  }

  func testPerformShortcutItem_Search() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )

    self.goToSearch.assertValueCount(0)

    self.vm.inputs.applicationPerformActionForShortcutItem(ShortcutItem.search.applicationShortcutItem)

    self.goToSearch.assertValueCount(1)
  }

  func testPerformShortcutItem_Success() async {
    await withEnvironment(currentUser: nil) {
      self.vm.inputs.applicationDidFinishLaunching(
        application: UIApplication.shared,
        launchOptions: [:]
      )
      self.vm.inputs.applicationPerformActionForShortcutItem(ShortcutItem.search.applicationShortcutItem)

      self.goToSearch.assertValueCount(1)
    }
  }

  func testLaunchShortcutItem_Search() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [
        UIApplication.LaunchOptionsKey.shortcutItem: ShortcutItem.search.applicationShortcutItem
      ]
    )

    self.goToSearch.assertValueCount(1)
    XCTAssertFalse(self.vm.outputs.applicationDidFinishLaunchingReturnValue)
  }

  func testLaunchShortcutItem_Failure() async {
    await withEnvironment(currentUser: nil) {
      self.vm.inputs.applicationDidFinishLaunching(
        application: UIApplication.shared,
        launchOptions: [
          UIApplication.LaunchOptionsKey.shortcutItem: ShortcutItem.search.applicationShortcutItem
        ]
      )

      self.goToSearch.assertValueCount(1)
      XCTAssertFalse(self.vm.outputs.applicationDidFinishLaunchingReturnValue)
    }
  }

  private func recordEmailRedirect(_ url: URL) -> URL? {
    self.findRedirectUrl.record(url)
    return self.emailRedirectDestination
  }

  func testEmailDeepLinking() async throws {
    let emailURL = try XCTUnwrap(URL(string: "https://clicks.kickstarter.com/?qs=deadbeef"))
    self.emailRedirectDestination = try XCTUnwrap(
      URL(string: "https://www.kickstarter.com/projects/creator/project")
    )

    await withEnvironment(apiService: MockService(fetchProjectResult: .success(.template))) {
      XCTAssertTrue(self.vm.inputs.applicationOpenUrl(application: .shared, url: emailURL, options: [:]))
      self.presentViewController.assertDidNotEmitValue()
      await self.deepLinkRouter.waitForOperations()
      self.findRedirectUrl.assertValues([emailURL])
      self.presentViewController.assertValueCount(1)
      self.goToMobileSafari.assertDidNotEmitValue()
    }
  }

  func testEmailDeepLinking_ContinuedUserActivity() async throws {
    let emailURL = try XCTUnwrap(URL(string: "https://emails.kickstarter.com/?qs=deadbeef"))
    self.emailRedirectDestination = try XCTUnwrap(
      URL(string: "https://www.kickstarter.com/projects/creator/project")
    )
    let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    activity.webpageURL = emailURL

    await withEnvironment(apiService: MockService(fetchProjectResult: .success(.template))) {
      XCTAssertTrue(self.vm.inputs.applicationContinueUserActivity(activity))
      await self.deepLinkRouter.waitForOperations()
      self.findRedirectUrl.assertValues([emailURL])
      self.presentViewController.assertValueCount(1)
      self.goToMobileSafari.assertDidNotEmitValue()
    }
  }

  func testEmailDeepLinking_UnrecognizedUrl() async throws {
    let emailURL = try XCTUnwrap(URL(string: "https://clicks.kickstarter.com/?qs=deadbeef"))
    let unrecognizedURL = try XCTUnwrap(URL(string: "https://www.kickstarter.com/unreconizable"))
    self.emailRedirectDestination = unrecognizedURL

    XCTAssertTrue(self.vm.inputs.applicationOpenUrl(application: .shared, url: emailURL, options: [:]))
    await self.deepLinkRouter.waitForOperations()
    self.findRedirectUrl.assertValues([emailURL])
    self.presentViewController.assertDidNotEmitValue()
    self.goToMobileSafari.assertValues([unrecognizedURL])
  }

  func testEmailDeepLinking_UnrecognizedUrl_ProjectPreview() async throws {
    let emailURL = try XCTUnwrap(URL(string: "https://emails.kickstarter.com/?qs=deadbeef"))
    let previewURL = try XCTUnwrap(URL(string: "https://www.kickstarter.com/projects/creator/project?token=4"))
    self.emailRedirectDestination = previewURL

    XCTAssertTrue(self.vm.inputs.applicationOpenUrl(application: .shared, url: emailURL, options: [:]))
    await self.deepLinkRouter.waitForOperations()
    self.findRedirectUrl.assertValues([emailURL])
    self.presentViewController.assertDidNotEmitValue()
    self.goToMobileSafari.assertValues([previewURL])
  }

  func testProjectSurveyDeepLink() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )

    self.presentViewController.assertValues([])

    let projectUrl = "https://www.kickstarter.com"
      + "/projects/tequila/help-me-transform-this-pile-of-wood/surveys/123"
    let result = self.vm.inputs.applicationOpenUrl(
      application: UIApplication.shared,
      url: URL(string: projectUrl)!,
      options: [:]
    )
    XCTAssertTrue(result)

    await self.deepLinkRouter.waitForOperations()
    self.presentViewController.assertValues([1])
  }

  func testErroredPledgeDeepLink_LoggedIn() async {
    let project = Project.template
      |> \.personalization.backing .~ .template
    let service = MockService(fetchProjectResult: .success(project))

    await withEnvironment(apiService: service, currentUser: .template) {
      self.vm.inputs.applicationDidFinishLaunching(
        application: UIApplication.shared,
        launchOptions: [:]
      )

      self.goToLoginWithIntent.assertDidNotEmitValue()
      self.presentViewController.assertValues([])

      let projectUrl = "https://www.kickstarter.com"
        + "/projects/sshults/greensens-the-easy-way-to-take-care-of-your-houseplants-0"
        + "/pledge?at=4f7d35e7c9d2bb57&ref=ksr_email_backer_failed_transaction"

      let result = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: URL(string: projectUrl)!,
        options: [:]
      )
      XCTAssertTrue(result)

      self.goToLoginWithIntent.assertDidNotEmitValue()
      await self.deepLinkRouter.waitForOperations()
      self.presentViewController.assertValues([2])
    }
  }

  func testErroredPledgeDeepLink_LoggedOut() async {
    await withEnvironment(
      apiService: MockService(fetchProjectResult: .success(.template)),
      currentUser: nil
    ) {
      self.vm.inputs.applicationDidFinishLaunching(
        application: UIApplication.shared,
        launchOptions: [:]
      )

      self.goToLoginWithIntent.assertDidNotEmitValue()
      self.presentViewController.assertValues([])

      let projectUrl = "https://www.kickstarter.com"
        + "/projects/sshults/greensens-the-easy-way-to-take-care-of-your-houseplants-0"
        + "/pledge?at=4f7d35e7c9d2bb57&ref=ksr_email_backer_failed_transaction"

      let result = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: URL(string: projectUrl)!,
        options: [:]
      )
      XCTAssertTrue(result)

      self.goToLoginWithIntent.assertValues([.erroredPledge])
      self.presentViewController.assertDidNotEmitValue()
    }
  }

  func testErroredPledgePushDeepLink_LoggedIn() async {
    let project = Project.template
      |> \.personalization.backing .~ .template
    let service = MockService(fetchProjectResult: .success(project))

    await withEnvironment(apiService: service, currentUser: .template) {
      self.goToLoginWithIntent.assertDidNotEmitValue()
      self.presentViewController.assertDidNotEmitValue()

      let pushData: [String: Any] = [
        "aps": [
          "alert": "You have an errored pledge."
        ],
        "errored_pledge": [
          "project_id": 2
        ]
      ]

      self.vm.inputs.didReceive(remoteNotification: pushData)

      self.goToLoginWithIntent.assertDidNotEmitValue()
      await self.deepLinkRouter.waitForOperations()
      self.presentViewController.assertValues([2])
    }
  }

  func testErroredPledgePushDeepLink_LoggedOut() async {
    await withEnvironment(
      apiService: MockService(fetchProjectResult: .success(.template)),
      currentUser: nil
    ) {
      self.goToLoginWithIntent.assertDidNotEmitValue()
      self.presentViewController.assertDidNotEmitValue()

      let pushData: [String: Any] = [
        "aps": [
          "alert": "You have an errored pledge."
        ],
        "errored_pledge": [
          "project_id": 2
        ]
      ]

      self.vm.inputs.didReceive(remoteNotification: pushData)

      self.goToLoginWithIntent.assertValues([.erroredPledge])
      self.presentViewController.assertDidNotEmitValue()
    }
  }

  func testUserSurveyDeepLink() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )

    self.presentViewController.assertValues([])

    let projectUrl = "https://www.kickstarter.com/users/tequila/surveys/123"
    let result = self.vm.inputs.applicationOpenUrl(
      application: UIApplication.shared,
      url: URL(string: projectUrl)!,
      options: [:]
    )
    XCTAssertTrue(result)

    await self.deepLinkRouter.waitForOperations()
    self.presentViewController.assertValues([1])
  }

  func testVerifyEmail_Success() async {
    self.emailVerificationCompletedMessage.assertDidNotEmitValue()
    self.emailVerificationCompletedSuccess.assertDidNotEmitValue()

    guard let url = URL(string: "https://www.kickstarter.com/profile/verify_email?at=12345") else {
      XCTFail("Should have a url")
      return
    }

    let env = EmailVerificationResponseEnvelope(
      message: "Thanks—you’ve successfully verified your email address."
    )

    let mockService = MockService(verifyEmailResult: .success(env))

    await withEnvironment(apiService: mockService) {
      _ = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: url,
        options: [:]
      )
      await self.settingsFeature.waitForOperations()

      await self.settingsLinks.waitForOperations()
      self.emailVerificationCompletedSuccess.assertValues([true])
      self.emailVerificationCompletedMessage.assertValues(
        ["Thanks—you’ve successfully verified your email address."]
      )
    }
  }

  func testVerifyEmail_Failure() async {
    self.emailVerificationCompletedMessage.assertDidNotEmitValue()
    self.emailVerificationCompletedSuccess.assertDidNotEmitValue()

    guard let url = URL(string: "https://www.kickstarter.com/profile/verify_email?at=12345") else {
      XCTFail("Should have a url")
      return
    }

    let errorEnvelope = ErrorEnvelope(
      errorMessages: ["Error Message"],
      ksrCode: .UnknownCode,
      httpCode: 403,
      exception: nil
    )

    let mockService = MockService(verifyEmailResult: .failure(errorEnvelope))

    await withEnvironment(apiService: mockService) {
      _ = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: url,
        options: [:]
      )
      await self.settingsFeature.waitForOperations()

      await self.settingsLinks.waitForOperations()
      self.emailVerificationCompletedSuccess.assertValues([false])
      self.emailVerificationCompletedMessage.assertValues(
        ["Error Message"]
      )
    }
  }

  func testVerifyEmail_Failure_UnknownError() async {
    self.emailVerificationCompletedMessage.assertDidNotEmitValue()
    self.emailVerificationCompletedSuccess.assertDidNotEmitValue()

    guard let url = URL(string: "https://www.kickstarter.com/profile/verify_email?at=12345") else {
      XCTFail("Should have a url")
      return
    }

    let errorEnvelope = ErrorEnvelope(
      errorMessages: [],
      ksrCode: .UnknownCode,
      httpCode: 500,
      exception: nil
    )

    let mockService = MockService(verifyEmailResult: .failure(errorEnvelope))

    await withEnvironment(apiService: mockService) {
      _ = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: url,
        options: [:]
      )
      await self.settingsFeature.waitForOperations()

      await self.settingsLinks.waitForOperations()
      self.emailVerificationCompletedSuccess.assertValues([false])
      self.emailVerificationCompletedMessage.assertValues(
        ["Something went wrong, please try again."]
      )
    }
  }

  func testDeepLinkNotificationFailureDoesNotReportSuccess() async throws {
    AppEnvironment.login(AccessTokenEnvelope(accessToken: "fixture-token", user: .template))
    let original = AppEnvironment.current.currentUser?.notifications
    let url =
      try XCTUnwrap(URL(string: "https://www.kickstarter.com/settings/notify_mobile_of_messages/true"))
    await withEnvironment(apiService: MockService(updateUserSelfError: .couldNotParseJSON)) {
      XCTAssertTrue(self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared, url: url, options: [:]
      ))
      await self.settingsLinks.waitForOperations()
      self.notificationSettingsUpdated.assertDidNotEmitValue()
      self.updateCurrentUserInEnvironment.assertDidNotEmitValue()
      XCTAssertEqual(AppEnvironment.current.currentUser?.notifications, original)
      XCTAssertNotNil(self.settingsFeature.lastError)
    }
  }

  func testDeepLinkCompletionDoesNotReplaySavedUserAfterPresentationDelay() async throws {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    self.settingsLinkDelay = { _ in
      for await _ in stream { break }
      try Task.checkCancellation()
    }
    AppEnvironment.login(AccessTokenEnvelope(accessToken: "fixture-token", user: .template))
    let url =
      try XCTUnwrap(URL(string: "https://www.kickstarter.com/settings/notify_mobile_of_messages/true"))
    XCTAssertTrue(self.vm.inputs.applicationOpenUrl(
      application: UIApplication.shared, url: url, options: [:]
    ))
    await self.settingsFeature.waitForOperations()
    XCTAssertEqual(AppEnvironment.current.currentUser?.notifications.mobileMessages, true)
    self.notificationSettingsUpdated.assertDidNotEmitValue()
    var newer = try XCTUnwrap(AppEnvironment.current.currentUser)
    newer.newsletters.games = true
    AppEnvironment.updateCurrentUser(newer)
    continuation.yield(())
    continuation.finish()
    await self.settingsLinks.waitForOperations()
    self.notificationSettingsUpdated.assertValueCount(1)
    self.updateCurrentUserInEnvironment.assertDidNotEmitValue()
    XCTAssertEqual(AppEnvironment.current.currentUser?.newsletters.games, true)
  }

  func testDeepLinkNotificationDoesNotReportSuccessAfterSessionReplacement() async throws {
    let delayStarted = self.expectation(description: "Settings write reached the presentation delay")
    let (delayGate, release) = AsyncStream<Void>.makeStream()
    let handler = try XCTUnwrap(self.vm as? AppDelegateViewModel)
    self.settingsLinkDelay = { _ in
      delayStarted.fulfill()
      for await _ in delayGate { break }
    }

    AppEnvironment.login(AccessTokenEnvelope(accessToken: "fixture-token", user: .template))
    let url = try XCTUnwrap(
      URL(string: "https://www.kickstarter.com/settings/notify_mobile_of_messages/true")
    )
    XCTAssertTrue(handler.applicationOpenUrl(application: UIApplication.shared, url: url, options: [:]))
    await self.fulfillment(of: [delayStarted], timeout: 2)
    self.settingsFeature.sessionFeature.sessionChanged()
    release.yield(())
    release.finish()
    await self.settingsLinks.waitForOperations()

    self.notificationSettingsUpdated.assertDidNotEmitValue()
  }

  func testDeepLink_UserDidUpdateNotificationSettings() async {
    self.updateCurrentUserInEnvironment.assertDidNotEmitValue()

    await withEnvironment(apiService: MockService()) {
      let user = User.template
        |> User.lens.notifications.mobileMessages .~ false

      let env = AccessTokenEnvelope(accessToken: "deadbeef", user: user)
      AppEnvironment.login(env)

      self.vm.inputs.applicationDidFinishLaunching(
        application: UIApplication.shared,
        launchOptions: [:]
      )
      await (self.vm as? AppDelegateViewModel)?.waitForUserRefresh()
      await self.settingsFeature.waitForOperations()

      self.updateCurrentUserInEnvironment.assertValues([user])

      let updatedUser = user
        |> User.lens.notifications.mobileMessages .~ true

      let url =
        "https://\(AppEnvironment.current.apiService.serverConfig.webBaseUrl.host ?? "")/settings/notify_mobile_of_messages/true"

      let result = self.vm.inputs.applicationOpenUrl(
        application: UIApplication.shared,
        url: URL(string: url)!,
        options: [:]
      )
      XCTAssertTrue(result)

      self.updateCurrentUserInEnvironment.assertValues([user])

      await self.settingsFeature.waitForOperations()
      await self.settingsFeature.waitForOperations()

      self.updateCurrentUserInEnvironment.assertValues([user])
      await self.settingsLinks.waitForOperations()
      self.notificationSettingsUpdated.assertValueCount(1)
      XCTAssertEqual(AppEnvironment.current.currentUser?.notifications, updatedUser.notifications)
    }
  }

  func testRequestATTrackingAuthorizationStatus_WhenAppBecomesActive_WhenAdvertisingIdentifierNil_WhenShouldRequestAuthorizationStatusTrue_RequestAllowed_ShowsConsentDialogAndUpdatesAdId_whenHasSeenOnboardingIsTrue(
  ) async {
    let appTrackingTransparency = MockAppTrackingTransparency()
    appTrackingTransparency.requestAndSetAuthorizationStatusFlag = true
    appTrackingTransparency.shouldRequestAuthStatus = true

    userDefaults.set(true, forKey: AppKeys.hasSeenOnboarding.rawValue)

    await withEnvironment(
      appTrackingTransparency: appTrackingTransparency
    ) {
      XCTAssertEqual(appTrackingTransparency.requestCount, 0)

      XCTAssertNil(appTrackingTransparency.advertisingIdentifier)

      self.trackingConsent.applicationActive(state: false)
      self.vm.inputs.applicationDidFinishLaunching(application: UIApplication.shared, launchOptions: nil)
      self.trackingConsent.applicationDidFinishLaunching()
      self.trackingConsent.applicationActive(state: true)
      await self.trackingConsent.waitForRequests()
      await self.settingsFeature.waitForOperations()

      XCTAssertEqual(appTrackingTransparency.advertisingIdentifier, "advertisingIdentifier")
      XCTAssertEqual(appTrackingTransparency.requestCount, 1)
    }
  }

  func testRequestATTrackingAuthorizationStatus_WhenAppBecomesActive_WhenAdvertisingIdentifierNil_WhenShouldRequestAuthorizationStatusTrue_RequestAllowed_ShowsConsentDialogAndUpdatesAdId_WhenHasSeenOnboardingIsFalse(
  ) async {
    let appTrackingTransparency = MockAppTrackingTransparency()
    appTrackingTransparency.requestAndSetAuthorizationStatusFlag = true
    appTrackingTransparency.shouldRequestAuthStatus = true

    await withEnvironment(
      appTrackingTransparency: appTrackingTransparency
    ) {
      XCTAssertEqual(appTrackingTransparency.requestCount, 0)

      XCTAssertNil(appTrackingTransparency.advertisingIdentifier)

      self.trackingConsent.applicationActive(state: false)
      self.vm.inputs.applicationDidFinishLaunching(application: UIApplication.shared, launchOptions: nil)
      self.trackingConsent.applicationDidFinishLaunching()
      self.trackingConsent.applicationActive(state: true)
      await self.trackingConsent.waitForRequests()
      await self.settingsFeature.waitForOperations()

      XCTAssertNil(appTrackingTransparency.advertisingIdentifier)
      XCTAssertEqual(appTrackingTransparency.requestCount, 0)
    }
  }

  func testRequestATTrackingAuthorizationStatus_WhenAppBecomesActive_WhenAdvertisingIdentifierNil_WhenConsentManagementFeatureFlagOn_WhenShouldRequestAuthorizationStatusTrue_RequestAllowed_DoesNot_ShowConsentDialogAndUpdateAdId(
  ) async {
    let appTrackingTransparency = MockAppTrackingTransparency()
    appTrackingTransparency.requestAndSetAuthorizationStatusFlag = true
    appTrackingTransparency.shouldRequestAuthStatus = true

    await withEnvironment(
      appTrackingTransparency: appTrackingTransparency
    ) {
      XCTAssertEqual(appTrackingTransparency.requestCount, 0)

      XCTAssertNil(appTrackingTransparency.advertisingIdentifier)

      self.trackingConsent.applicationActive(state: false)
      self.vm.inputs.applicationDidFinishLaunching(application: UIApplication.shared, launchOptions: nil)
      self.trackingConsent.applicationDidFinishLaunching()
      self.trackingConsent.applicationActive(state: true)
      await self.trackingConsent.waitForRequests()
      await self.settingsFeature.waitForOperations()

      XCTAssertNil(appTrackingTransparency.advertisingIdentifier)
      XCTAssertEqual(appTrackingTransparency.requestCount, 0)
    }
  }

  func testRequestATTrackingAuthorizationStatus_WhenAppBecomesActive_WhenAdvertisingIdentifierNil_WhenConsentManagementFeatureFlagOn_WhenShouldRequestAuthorizationStatusFalse_RequestAllowed_DoesNotShowConsentDialogAndDoesNotUpdateAdId(
  ) async {
    let appTrackingTransparency = MockAppTrackingTransparency()
    appTrackingTransparency.requestAndSetAuthorizationStatusFlag = true
    appTrackingTransparency.shouldRequestAuthStatus = false

    userDefaults.set(true, forKey: AppKeys.hasSeenOnboarding.rawValue)

    await withEnvironment(
      appTrackingTransparency: appTrackingTransparency
    ) {
      XCTAssertEqual(appTrackingTransparency.requestCount, 0)

      XCTAssertNil(appTrackingTransparency.advertisingIdentifier)

      self.trackingConsent.applicationActive(state: false)
      self.vm.inputs.applicationDidFinishLaunching(application: UIApplication.shared, launchOptions: nil)
      self.trackingConsent.applicationDidFinishLaunching()
      self.trackingConsent.applicationActive(state: true)
      await self.trackingConsent.waitForRequests()
      await self.settingsFeature.waitForOperations()

      XCTAssertNil(appTrackingTransparency.advertisingIdentifier)
      XCTAssertEqual(appTrackingTransparency.requestCount, 0)
    }
  }

  func testTriggerOnboardingFlow_WhenUserHasNotDeterminedPushNotificationsOrATTPermissions() async {
    MockPushRegistration.authorizedValue = false
    MockPushRegistration.registerValue = true

    let appTrackingTransparency = MockAppTrackingTransparency()
    appTrackingTransparency.requestAndSetAuthorizationStatusFlag = true
    appTrackingTransparency.shouldRequestAuthStatus = true

    await withEnvironment(
      appTrackingTransparency: appTrackingTransparency,
      pushRegistrationType: MockPushRegistration.self
    ) {
      self.triggerOnboardingFlow.assertValueCount(0)

      self.pushRegistrationStarted.assertValueCount(0)
      self.pushTokenSuccessfullyRegistered.assertValueCount(0)

      XCTAssertNil(appTrackingTransparency.advertisingIdentifier)

      self.trackingConsent.applicationActive(state: false)
      self.launchApplication(application: UIApplication.shared, launchOptions: nil)
      self.trackingConsent.applicationDidFinishLaunching()
      self.trackingConsent.applicationActive(state: true)
      await self.trackingConsent.waitForRequests()
      await (self.vm as? AppDelegateViewModel)?.waitForUserRefresh()
      await self.settingsFeature.waitForOperations()

      self.pushRegistrationStarted.assertValueCount(0)
      XCTAssertNil(appTrackingTransparency.advertisingIdentifier)
      XCTAssertEqual(appTrackingTransparency.requestCount, 0)

      self.triggerOnboardingFlow.assertValueCount(1)
    }
  }

  func testTriggerOnboardingFlow_IsNotCalled_WhenUserHasAuthorizedPushNotifications_ButNotATTPermissions(
  ) async {
    MockPushRegistration.authorizedValue = true
    MockPushRegistration.registerValue = true

    let appTrackingTransparency = MockAppTrackingTransparency()
    appTrackingTransparency.requestAndSetAuthorizationStatusFlag = false
    appTrackingTransparency.shouldRequestAuthStatus = false

    await withEnvironment(
      appTrackingTransparency: appTrackingTransparency,
      pushRegistrationType: MockPushRegistration.self
    ) {
      self.triggerOnboardingFlow.assertValueCount(0)

      self.trackingConsent.applicationActive(state: false)
      self.launchApplication(application: UIApplication.shared, launchOptions: nil)
      self.trackingConsent.applicationDidFinishLaunching()
      self.trackingConsent.applicationActive(state: true)
      await self.trackingConsent.waitForRequests()
      await (self.vm as? AppDelegateViewModel)?.waitForUserRefresh()
      await self.settingsFeature.waitForOperations()

      self.triggerOnboardingFlow.assertValueCount(0)
    }
  }

  func testTriggerOnboardingFlow_IsNotCalled_WhenUserHasAuthorizedATTPermissions_ButNotPushNotifications(
  ) async {
    MockPushRegistration.authorizedValue = false
    MockPushRegistration.registerValue = false

    let appTrackingTransparency = MockAppTrackingTransparency()
    appTrackingTransparency.requestAndSetAuthorizationStatusFlag = true
    appTrackingTransparency.shouldRequestAuthStatus = false

    await withEnvironment(
      appTrackingTransparency: appTrackingTransparency,
      pushRegistrationType: MockPushRegistration.self
    ) {
      self.triggerOnboardingFlow.assertValueCount(0)

      self.trackingConsent.applicationActive(state: false)
      self.launchApplication(application: UIApplication.shared, launchOptions: nil)
      self.trackingConsent.applicationDidFinishLaunching()
      self.trackingConsent.applicationActive(state: true)
      await self.trackingConsent.waitForRequests()
      await (self.vm as? AppDelegateViewModel)?.waitForUserRefresh()
      await self.settingsFeature.waitForOperations()

      self.triggerOnboardingFlow.assertValueCount(0)
    }
  }

  func testTriggerOnboardingFlow_IsNotCalled_WhenOnboardingFlowFeatureFlagDisabled() async {
    MockPushRegistration.authorizedValue = false
    MockPushRegistration.registerValue = false

    let appTrackingTransparency = MockAppTrackingTransparency()
    appTrackingTransparency.requestAndSetAuthorizationStatusFlag = false
    appTrackingTransparency.shouldRequestAuthStatus = false

    await withEnvironment(
      appTrackingTransparency: appTrackingTransparency,
      pushRegistrationType: MockPushRegistration.self
    ) {
      self.triggerOnboardingFlow.assertValueCount(0)

      self.trackingConsent.applicationActive(state: false)
      self.launchApplication(application: UIApplication.shared, launchOptions: nil)
      self.trackingConsent.applicationDidFinishLaunching()
      self.trackingConsent.applicationActive(state: true)
      await self.trackingConsent.waitForRequests()
      await (self.vm as? AppDelegateViewModel)?.waitForUserRefresh()
      await self.settingsFeature.waitForOperations()

      self.triggerOnboardingFlow.assertValueCount(0)
    }
  }

  func testTriggerOnboardingFlow_IsNotCalled_UserDefaultsHasSeenOnboardingIsTrue() async {
    MockPushRegistration.authorizedValue = false
    MockPushRegistration.registerValue = true

    let appTrackingTransparency = MockAppTrackingTransparency()
    appTrackingTransparency.requestAndSetAuthorizationStatusFlag = true
    appTrackingTransparency.shouldRequestAuthStatus = true

    userDefaults.set(true, forKey: AppKeys.hasSeenOnboarding.rawValue)

    await withEnvironment(
      appTrackingTransparency: appTrackingTransparency,
      pushRegistrationType: MockPushRegistration.self
    ) {
      self.triggerOnboardingFlow.assertValueCount(0)

      self.pushRegistrationStarted.assertValueCount(0)
      self.pushTokenSuccessfullyRegistered.assertValueCount(0)

      XCTAssertNil(appTrackingTransparency.advertisingIdentifier)

      self.trackingConsent.applicationActive(state: false)
      self.launchApplication(application: UIApplication.shared, launchOptions: nil)
      self.trackingConsent.applicationDidFinishLaunching()
      self.trackingConsent.applicationActive(state: true)
      await self.trackingConsent.waitForRequests()
      await (self.vm as? AppDelegateViewModel)?.waitForUserRefresh()
      await self.settingsFeature.waitForOperations()

      self.pushRegistrationStarted.assertValueCount(0)
      XCTAssertEqual(appTrackingTransparency.advertisingIdentifier, "advertisingIdentifier")
      XCTAssertEqual(appTrackingTransparency.requestCount, 1)

      self.triggerOnboardingFlow.assertValueCount(0)
    }
  }

  func testTriggerOnboardingFlow_WhenUserDefaultsHasSeenOnboardingIsFalse() async {
    MockPushRegistration.authorizedValue = false
    MockPushRegistration.registerValue = true

    let appTrackingTransparency = MockAppTrackingTransparency()
    appTrackingTransparency.requestAndSetAuthorizationStatusFlag = true
    appTrackingTransparency.shouldRequestAuthStatus = true

    await withEnvironment(
      appTrackingTransparency: appTrackingTransparency,
      pushRegistrationType: MockPushRegistration.self
    ) {
      self.triggerOnboardingFlow.assertValueCount(0)

      self.pushRegistrationStarted.assertValueCount(0)
      self.pushTokenSuccessfullyRegistered.assertValueCount(0)

      XCTAssertNil(appTrackingTransparency.advertisingIdentifier)

      self.trackingConsent.applicationActive(state: false)
      self.launchApplication(application: UIApplication.shared, launchOptions: nil)
      self.trackingConsent.applicationDidFinishLaunching()
      self.trackingConsent.applicationActive(state: true)
      await self.trackingConsent.waitForRequests()
      await (self.vm as? AppDelegateViewModel)?.waitForUserRefresh()
      await self.settingsFeature.waitForOperations()

      self.pushRegistrationStarted.assertValueCount(0)
      XCTAssertNil(appTrackingTransparency.advertisingIdentifier)
      XCTAssertEqual(appTrackingTransparency.requestCount, 0)

      XCTAssertFalse(userDefaults.bool(forKey: AppKeys.hasSeenOnboarding.rawValue))

      self.triggerOnboardingFlow.assertValueCount(1)
    }
  }

  func testRequestATTrackingAuthorizationStatus_WhenAppBecomesActive_WhenAdvertisingIdentifierNil_WhenShouldRequestAuthorizationStatusTrue_RequestDenied_DoesNotShowConsentDialogAndDoesNotUpdateAdId(
  ) async {
    let appTrackingTransparency = MockAppTrackingTransparency()
    appTrackingTransparency.requestAndSetAuthorizationStatusFlag = false
    appTrackingTransparency.shouldRequestAuthStatus = true

    await withEnvironment(
      appTrackingTransparency: appTrackingTransparency
    ) {
      XCTAssertEqual(appTrackingTransparency.requestCount, 0)

      XCTAssertNil(appTrackingTransparency.advertisingIdentifier)

      self.trackingConsent.applicationActive(state: false)
      self.vm.inputs.applicationDidFinishLaunching(application: UIApplication.shared, launchOptions: nil)
      self.trackingConsent.applicationDidFinishLaunching()
      self.trackingConsent.applicationActive(state: true)
      await self.trackingConsent.waitForRequests()
      await self.settingsFeature.waitForOperations()

      XCTAssertNil(appTrackingTransparency.advertisingIdentifier)
      XCTAssertEqual(appTrackingTransparency.requestCount, 0)
    }
  }

  func testRequestAppTrackingSignalAuthorize() async {
    let appTrackingTransparency = MockAppTrackingTransparency()
    await withEnvironment(
      appTrackingTransparency: appTrackingTransparency
    ) {
      self.trackingConsent.applicationActive(state: false)
      self.vm.inputs.applicationDidFinishLaunching(application: UIApplication.shared, launchOptions: nil)
      self.trackingConsent.applicationDidFinishLaunching()

      appTrackingTransparency.authorizationStatusValue = .notDetermined
      XCTAssertEqual(self.trackingAuthorizationStatus.values, [.notDetermined])
      XCTAssertTrue(appTrackingTransparency.shouldRequestAuthStatus)

      appTrackingTransparency.requestAndSetAuthorizationStatus()
      XCTAssertEqual(self.trackingAuthorizationStatus.values, [.notDetermined, .authorized])
      XCTAssertFalse(appTrackingTransparency.shouldRequestAuthStatus)
    }
  }

  func testTrackingObservationDoesNotDuplicateAcrossLifecycleEvents() async {
    let tracking = MockAppTrackingTransparency()
    await withEnvironment(appTrackingTransparency: tracking) {
      self.trackingConsent.applicationActive(state: false)
      self.vm.inputs.applicationDidFinishLaunching(application: UIApplication.shared, launchOptions: nil)
      self.trackingConsent.applicationDidFinishLaunching()
      self.trackingConsent.applicationActive(state: true)
      await self.trackingConsent.waitForRequests()
      tracking.authorizationStatusValue = .denied
      XCTAssertEqual(self.trackingAuthorizationStatus.values, [.notDetermined, .denied])
    }
  }

  func testRequestAppTrackingSignalDeny() async {
    let appTrackingTransparency = MockAppTrackingTransparency()
    await withEnvironment(
      appTrackingTransparency: appTrackingTransparency
    ) {
      self.trackingConsent.applicationActive(state: false)
      self.vm.inputs.applicationDidFinishLaunching(application: UIApplication.shared, launchOptions: nil)
      self.trackingConsent.applicationDidFinishLaunching()

      appTrackingTransparency.authorizationStatusValue = .notDetermined
      XCTAssertEqual(self.trackingAuthorizationStatus.values, [.notDetermined])
      XCTAssertTrue(appTrackingTransparency.shouldRequestAuthStatus)

      appTrackingTransparency.authorizationStatusValue = .denied
      XCTAssertEqual(self.trackingAuthorizationStatus.values, [.notDetermined, .denied])
      XCTAssertFalse(appTrackingTransparency.shouldRequestAuthStatus)
    }
  }

  func testPresentViewController_BrazeInAppNotificationDeeplink_ProjectCommentThread_Success() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )

    await withEnvironment(apiService: MockService(fetchCommentRepliesEnvelopeResult: .success(
      CommentRepliesEnvelope
        .successfulRepliesTemplate
    ), fetchProjectResult: .success(.template))) {
      let url =
        "https://\(AppEnvironment.current.apiService.serverConfig.webBaseUrl.host ?? "")/projects/fjorden/fjorden-iphone-photography-reinvented/"

      self.presentViewController.assertValues([])

      self.vm.inputs.urlFromBrazeNotification(URL(string: url)!)

      await self.deepLinkRouter.waitForOperations()
      self.presentViewController.assertValues([1])
    }
  }

  func testGoToMobileSafari_BrazeInAppNotificaton() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )

    let url = URL(string: "https://fake-url.com")!
    self.vm.inputs.urlFromBrazeNotification(url)

    self.goToMobileSafari.assertValues([url])
    self.presentViewController.assertValues([])
  }

  func testGoToMobileSafari_unrecognizedDeeplink() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )

    let url = URL(string: "https://fake-url.com")!
    _ = self.vm.inputs.applicationOpenUrl(application: nil, url: url, options: [:])

    self.goToMobileSafari.assertLastValue(url)
  }

  func testGoToMobileSafari_deeplinkFound() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )

    let url = URL(string: "https://kickstarter.com/activity")!
    _ = self.vm.inputs.applicationOpenUrl(application: nil, url: url, options: [:])

    self.goToMobileSafari.assertDidNotEmitValue()
  }

  func testGoToMobileSafari_ksrUnrecognizedDeeplink() async throws {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )

    let url = URL(string: "ksr://fake-url.com")!
    _ = self.vm.inputs.applicationOpenUrl(application: nil, url: url, options: [:])

    self.goToMobileSafari.assertDidNotEmitValue()
  }

  func testGoToMobileSafari_ksrDeeplinkFound() async {
    self.vm.inputs.applicationDidFinishLaunching(
      application: UIApplication.shared,
      launchOptions: [:]
    )

    let url = URL(string: "https://kickstarter.com/activity")!
    _ = self.vm.inputs.applicationOpenUrl(application: nil, url: url, options: [:])

    self.goToMobileSafari.assertDidNotEmitValue()
  }

  func testUserSessionStarted_fetchesUserEmail_andClearsOnLogout() async {
    let fetchUserSetupQueryData = GraphAPI.FetchUserSetupQuery.Data(
      me: GraphAPI.FetchUserSetupQuery.Data.Me(
        email: "user@example.com",
        enabledFeatures: []
      )
    )

    guard let envelope = UserEnvelope<GraphUserSetup>.userEnvelope(from: fetchUserSetupQueryData) else {
      XCTFail()
      return
    }

    let mockService = MockService(
      fetchGraphUserSetupResult: .success(envelope)
    )

    await withEnvironment(apiService: mockService) {
      XCTAssertNil(AppEnvironment.current.currentUserEmail)

      self.vm.inputs.userSessionStarted()
      await self.settingsFeature.waitForOperations()

      XCTAssertEqual(AppEnvironment.current.currentUserEmail, "user@example.com")

      AppEnvironment.logout()

      XCTAssertNil(AppEnvironment.current.currentUserEmail)
    }
  }
}

private let backingForCreatorPushData: [String: Any] = [
  "aps": [
    "alert": "HEYYYY"
  ],
  "activity": [
    "category": "backing",
    "id": 1,
    "project_id": 1
  ],
  "for_creator": true
]

private let friendBackingPushData = [
  "aps": [
    "alert": "HEYYYY"
  ],
  "activity": [
    "category": "backing",
    "id": 1,
    "project_id": 1
  ]
]

private let genericActivityPushData = [
  "aps": [
    "alert": "HEYYYY"
  ],
  "activity": [
    "category": "success",
    "id": 1,
    "project_id": 1
  ]
]

private let genericProjectPushData = [
  "aps": [
    "alert": "HEYYYY"
  ],
  "project": [
    "id": 1
  ]
]
private let projectCommentPushData = [
  "aps": [
    "alert": "HEYYYY"
  ],
  "activity": [
    "category": "comment-project",
    "id": 1,
    "project_id": 1
  ]
]

private let orderPushData = [
  "aps": [
    "alert": "Response needed! Get your reward for backing some project."
  ],
  "order": [
    "id": 1,
    "project_id": 1,
    "pledge_manager_path": "/projects/fakeCreatorId/1/backing/redeem"
  ]
]

private let surveyResponsePushData = [
  "aps": [
    "alert": "Response needed! Get your reward for backing some project."
  ],
  "survey": [
    "id": 1,
    "project_id": 1,
    "urls": [
      "web": [
        "survey": "/projects/fakeCreatorId/1/surveys/0"
      ]
    ]
  ]
]

private let updateCommentPushData = [
  "aps": [
    "alert": "HEYYYY"
  ],
  "activity": [
    "category": "comment-post",
    "id": 1,
    "project_id": 1,
    "update_id": 1
  ]
]

private let updatePushData = [
  "aps": [
    "alert": "HEYYYY"
  ],
  "activity": [
    "category": "update",
    "id": 1,
    "project_id": 1,
    "update_id": 1
  ]
]
