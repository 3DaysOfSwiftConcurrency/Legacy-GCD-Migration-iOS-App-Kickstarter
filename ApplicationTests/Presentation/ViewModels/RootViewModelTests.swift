@testable import Kickstarter_iOS

@testable import KsApi


import Prelude
import UIKit
import XCTest

@MainActor
final class RootViewModelTests: TestCase {
  override var requiresSnapshotReferenceSimulator: Bool { false }
  private let sessionFeature = SessionFeature(makeProvider: {
    AsyncSessionProvider(service: AppEnvironment.current.apiService)
  })
  private lazy var settingsFeature = SettingsFeature(
    sessionFeature: self.sessionFeature,
    applicationSettings: .test(
      userDefaults: { AppEnvironment.current.userDefaults },
      remoteClient: { AppEnvironment.current.remoteConfigClient }
    ),
    makeProvider: { AsyncAccountPreferencesProvider(service: AppEnvironment.current.apiService) }
  )
  private lazy var vm = self.makeViewModel(profileFeature: ProfileFeature(
    sessionFeature: self.sessionFeature,
    makeProvider: { AsyncProfileProvider(service: AppEnvironment.current.apiService) }
  ))

  private func makeViewModel(
    profileFeature: ProfileFeature,
    settingsFeature: SettingsFeature? = nil
  ) -> RootViewModel {
    RootViewModel(
      sessionFeature: profileFeature.sessionFeature,
      profileFeature: profileFeature,
      activityFeature: ActivityFeature(
        sessionFeature: profileFeature.sessionFeature,
        makeProvider: { AsyncActivityProvider(service: AppEnvironment.current.apiService) },
        applicationBadgeNumber: {
          AppEnvironment.current.application.applicationIconBadgeNumber
        }
      ),
      settingsFeature: settingsFeature ?? self.settingsFeature,
      analytics: { AppEnvironment.current.ksrAnalytics },
      isVoiceOverRunning: { AppEnvironment.current.isVoiceOverRunning() }
    )
  }
  let viewControllerNames = ValueRecorder<[String]>()
  let filterDiscovery = ValueRecorder<DiscoveryParams>()
  let floatingTabBarEnabled = ValueRecorder<Bool>()
  let selectedIndex = ValueRecorder<RootViewControllerIndex>()
  let setBadgeValueAtIndexValue = ValueRecorder<String?>()
  let setBadgeValueAtIndexIndex = ValueRecorder<RootViewControllerIndex>()
  let scrollToTopControllerName = ValueRecorder<String>()
  let tabBarItemsData = ValueRecorder<TabBarItemsData>()
  let updateUserInEnvironment = ValueRecorder<User>()

  func testAvatarLogoutSuppressesLateImage() async throws {
    let gate = RootAvatarRequestGate<Data>()
    defer { gate.releaseAll() }
    let session = SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) }, currentUser: { .template })
    let feature = ProfileFeature(sessionFeature: session, makeProvider: { AsyncProfileProvider(service: MockService()) }, loadAvatar: { _ in try await gate.request() })
    let vm = self.makeViewModel(profileFeature: feature)
    var delivered = 0
    vm.onAvatarImage = { _, _, _ in delivered += 1 }
    let url = try XCTUnwrap(URL(string: User.template.avatar.small))
    let request = vm.requestAvatar(url: url, index: 3, isLoggedIn: true)
    await gate.waitFor(1)
    vm.requestAvatar(url: nil, index: 3, isLoggedIn: false)
    try gate.finish(0, .success(Data([1])))
    await request?.value
    XCTAssertEqual(delivered, 0)
  }
  func testAvatarTabRebuildUsesNewIndexAndSharesDownload() async throws {
    let gate = RootAvatarRequestGate<Data>()
    defer { gate.releaseAll() }
    let session = SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) }, currentUser: { .template })
    let feature = ProfileFeature(sessionFeature: session, makeProvider: { AsyncProfileProvider(service: MockService()) }, loadAvatar: { _ in try await gate.request() })
    let vm = self.makeViewModel(profileFeature: feature)
    var indices: [Int] = []
    vm.onAvatarImage = { _, _, index in indices.append(index) }
    let url = try XCTUnwrap(URL(string: User.template.avatar.small))
    let old = vm.requestAvatar(url: url, index: 3, isLoggedIn: true)
    await gate.waitFor(1)
    let current = vm.requestAvatar(url: url, index: 2, isLoggedIn: true)
    await _Concurrency.Task.yield()
    try gate.finish(0, .success(Data([1])))
    await old?.value; await current?.value
    XCTAssertEqual(indices, [2])
    XCTAssertEqual(gate.count, 1)
  }

  override func setUp() async throws {
    try await super.setUp()

    MainActor.assumeIsolated {
      self.vm.outputs.onSetViewControllers = { [weak self] in
        self?.viewControllerNames.record(extractRootNames($0))
      }

      self.vm.outputs.onFilterDiscovery = { [weak self] in self?.filterDiscovery.record($0.1) }
      self.vm.outputs.onFloatingTabBarEnabled = { [weak self] in self?.floatingTabBarEnabled.record($0) }
      self.vm.outputs.onSelectedIndex = { [weak self] in self?.selectedIndex.record($0) }
      self.vm.outputs.onSetBadgeValue = { [weak self] data in
        self?.setBadgeValueAtIndexValue.record(data.0)
        self?.setBadgeValueAtIndexIndex.record(data.1)
      }
      self.vm.outputs.onUserUpdated = { [weak self] in self?.updateUserInEnvironment.record($0) }

      self.vm.outputs.onScrollToTop = { [weak self] index in
        guard let self, let names = self.viewControllerNames.lastValue, !names.isEmpty else { return }
        self.scrollToTopControllerName.record(names[clamp(0, names.count - 1)(index)])
      }

      self.vm.outputs.onTabBarItemsData = { [weak self] in self?.tabBarItemsData.record($0) }
    }
  }

  override func tearDown() async throws {
    await self.vm.waitForBadgeUpdate()
    try await super.tearDown()
  }

  func testBadgeRefreshDeliversUpdatedUser() async {
    let application = MockApplication()
    application.applicationIconBadgeNumber = 5
    await withEnvironment(
      apiService: MockService(clearUserUnseenActivityResult: .success(.init(activityIndicatorCount: 0))),
      application: application,
      currentUser: .template
    ) {
      self.vm.viewDidLoad()
      self.vm.applicationWillEnterForeground()
      self.vm.didSelect(index: 1)
      await self.vm.waitForBadgeUpdate()
      XCTAssertEqual(AppEnvironment.current.currentUser?.unseenActivityCount, 0)
      self.updateUserInEnvironment.assertValueCount(1)
    }
  }

  func testBadgeSaveFailureKeepsImmediateTabDisplayAndDoesNotNotify() async {
    let application = MockApplication()
    application.applicationIconBadgeNumber = 5
    let user = User.template |> User.lens.unseenActivityCount .~ 5
    await withEnvironment(
      apiService: MockService(clearUserUnseenActivityResult: .failure(.couldNotParseJSON)),
      application: application,
      currentUser: user
    ) {
      self.vm.viewDidLoad()
      self.vm.applicationWillEnterForeground()
      self.vm.didSelect(index: 1)
      await self.vm.waitForBadgeUpdate()
      self.setBadgeValueAtIndexValue.assertValues(["5", nil])
      self.updateUserInEnvironment.assertValueCount(0)
      XCTAssertEqual(AppEnvironment.current.currentUser?.unseenActivityCount, 5)
    }
  }

  func testSetBadgeValueAtIndex_NoValue() {
    let mockApplication = MockApplication()
    mockApplication.applicationIconBadgeNumber = 0

    self.setBadgeValueAtIndexValue.assertValues([])
    self.setBadgeValueAtIndexIndex.assertValues([])

    withEnvironment(application: mockApplication) {
      self.vm.inputs.viewDidLoad()
      self.vm.inputs.applicationWillEnterForeground()

      self.setBadgeValueAtIndexValue.assertValues([nil])
      self.setBadgeValueAtIndexIndex.assertValues([1])
    }
  }

  func testSetBadgeValueAtIndex_ValueSet() {
    let mockApplication = MockApplication()
    mockApplication.applicationIconBadgeNumber = 5

    self.setBadgeValueAtIndexValue.assertValues([])
    self.setBadgeValueAtIndexIndex.assertValues([])

    withEnvironment(application: mockApplication) {
      self.vm.inputs.viewDidLoad()
      self.vm.inputs.applicationWillEnterForeground()

      self.setBadgeValueAtIndexValue.assertValues(["5"])
      self.setBadgeValueAtIndexIndex.assertValues([1])
    }
  }

  func testSetBadgeValueAtIndex_MaxValueSet() {
    let mockApplication = MockApplication()
    mockApplication.applicationIconBadgeNumber = 100

    self.setBadgeValueAtIndexValue.assertValues([])
    self.setBadgeValueAtIndexIndex.assertValues([])

    withEnvironment(application: mockApplication) {
      self.vm.inputs.viewDidLoad()
      self.vm.inputs.applicationWillEnterForeground()

      self.setBadgeValueAtIndexValue.assertValues(["99+"])
      self.setBadgeValueAtIndexIndex.assertValues([1])
    }
  }

  func testSetBadgeValueAtIndex_MaxValueSet_ToggleVoiceOver() {
    let mockApplication = MockApplication()
    mockApplication.applicationIconBadgeNumber = 100

    self.setBadgeValueAtIndexValue.assertValues([])
    self.setBadgeValueAtIndexIndex.assertValues([])

    withEnvironment(application: mockApplication, isVoiceOverRunning: { false }) {
      self.vm.inputs.viewDidLoad()
      self.vm.inputs.applicationWillEnterForeground()

      self.setBadgeValueAtIndexValue.assertValues(["99+"])
      self.setBadgeValueAtIndexIndex.assertValues([1])
    }

    withEnvironment(application: mockApplication, isVoiceOverRunning: { true }) {
      self.vm.inputs.voiceOverStatusDidChange()

      self.setBadgeValueAtIndexValue.assertValues(["99+", "100"])
      self.setBadgeValueAtIndexIndex.assertValues([1, 1])
    }

    withEnvironment(application: mockApplication, isVoiceOverRunning: { false }) {
      self.vm.inputs.voiceOverStatusDidChange()

      self.setBadgeValueAtIndexValue.assertValues(["99+", "100", "99+"])
      self.setBadgeValueAtIndexIndex.assertValues([1, 1, 1])
    }
  }

  func testSetBadgeValueAtIndex_AppWillEnterForeground() {
    let mockApplication = MockApplication()
    mockApplication.applicationIconBadgeNumber = 100

    self.setBadgeValueAtIndexValue.assertValues([])
    self.setBadgeValueAtIndexIndex.assertValues([])

    withEnvironment(application: mockApplication) {
      self.vm.inputs.viewDidLoad()

      self.vm.inputs.applicationWillEnterForeground()
      self.setBadgeValueAtIndexValue.assertValues(["99+"])
      self.setBadgeValueAtIndexIndex.assertValues([1])

      mockApplication.applicationIconBadgeNumber = 50

      self.vm.inputs.applicationWillEnterForeground()
      self.setBadgeValueAtIndexValue.assertValues(["99+", "50"])
      self.setBadgeValueAtIndexIndex.assertValues([1, 1])
    }
  }

  func testClearBadgeValueOnActivitiesTabSelected() async {
    let initialActivitiesCount = 100

    let mockApplication = MockApplication()
    mockApplication.applicationIconBadgeNumber = initialActivitiesCount

    self.updateUserInEnvironment.assertValues([])
    self.setBadgeValueAtIndexValue.assertValues([])
    self.setBadgeValueAtIndexIndex.assertValues([])

    let mockService = MockService(
      clearUserUnseenActivityResult: Result.success(.init(activityIndicatorCount: 0))
    )

    let user = User.template
      |> User.lens.unseenActivityCount .~ initialActivitiesCount

    await withEnvironment(apiService: mockService, application: mockApplication, currentUser: user) {
      self.vm.inputs.viewDidLoad()
      self.vm.inputs.applicationWillEnterForeground()

      self.updateUserInEnvironment.assertValues([])
      self.setBadgeValueAtIndexValue.assertValues(["99+"])
      self.setBadgeValueAtIndexIndex.assertValues([1])

      self.vm.inputs.didSelect(index: 1)

      self.updateUserInEnvironment.assertValues([])
      self.setBadgeValueAtIndexValue.assertValues(["99+", nil])
      self.setBadgeValueAtIndexIndex.assertValues([1, 1])

      await self.vm.waitForBadgeUpdate()
      XCTAssertEqual(AppEnvironment.current.currentUser?.unseenActivityCount, 0)
      XCTAssertEqual(self.updateUserInEnvironment.values.map { $0.id }, [user.id])
      self.setBadgeValueAtIndexValue.assertValues(["99+", nil])
      self.setBadgeValueAtIndexIndex.assertValues([1, 1])
    }
  }

  func testClearBadgeValueOnActivitiesTabSelected_LoggedOut() {
    let initialActivitiesCount = 100

    let mockApplication = MockApplication()
    mockApplication.applicationIconBadgeNumber = initialActivitiesCount

    self.updateUserInEnvironment.assertValues([])
    self.setBadgeValueAtIndexValue.assertValues([])
    self.setBadgeValueAtIndexIndex.assertValues([])

    let mockService = MockService(
      clearUserUnseenActivityResult: Result.success(.init(activityIndicatorCount: 0))
    )

    withEnvironment(apiService: mockService, application: mockApplication) {
      self.vm.inputs.viewDidLoad()
      self.vm.inputs.applicationWillEnterForeground()

      self.updateUserInEnvironment.assertValues([])
      self.setBadgeValueAtIndexValue.assertValues(["99+"])
      self.setBadgeValueAtIndexIndex.assertValues([1])

      self.vm.inputs.didSelect(index: 1)

      self.updateUserInEnvironment.assertValues([])
      self.setBadgeValueAtIndexValue.assertValues(["99+", nil])
      self.setBadgeValueAtIndexIndex.assertValues([1, 1])


      self.updateUserInEnvironment.assertValues([])
      self.setBadgeValueAtIndexValue.assertValues(["99+", nil])
      self.setBadgeValueAtIndexIndex.assertValues([1, 1])
    }
  }

  func testSetBadgeValueAtIndex_CurrentUserUpdated_SessionEnded() {
    let mockApplication = MockApplication()
    mockApplication.applicationIconBadgeNumber = 0

    self.setBadgeValueAtIndexValue.assertValues([])
    self.setBadgeValueAtIndexIndex.assertValues([])

    withEnvironment(application: mockApplication) {
      self.vm.inputs.viewDidLoad()
      self.vm.inputs.applicationWillEnterForeground()

      self.setBadgeValueAtIndexValue.assertValues([nil])
      self.setBadgeValueAtIndexIndex.assertValues([1])
    }

    let user = .template
      |> User.lens.unseenActivityCount .~ 50

    withEnvironment(application: mockApplication) {
      AppEnvironment.login(.init(accessToken: "deadbeef", user: user))
      self.vm.inputs.currentUserUpdated()

      self.setBadgeValueAtIndexValue.assertValues([nil, "50"])
      self.setBadgeValueAtIndexIndex.assertValues([1, 1])

      AppEnvironment.logout()
      self.vm.inputs.userSessionEnded()

      self.setBadgeValueAtIndexValue.assertValues([nil, "50", nil])
      self.setBadgeValueAtIndexIndex.assertValues([1, 1, 1])
    }
  }

  func testSetBadgeValueAtIndex_FromNotification() {
    let mockApplication = MockApplication()
    mockApplication.applicationIconBadgeNumber = 100

    self.setBadgeValueAtIndexValue.assertValues([])
    self.setBadgeValueAtIndexIndex.assertValues([])

    withEnvironment(application: mockApplication) {
      self.vm.inputs.viewDidLoad()
      self.vm.inputs.applicationWillEnterForeground()

      self.setBadgeValueAtIndexValue.assertValues(["99+"])
      self.setBadgeValueAtIndexIndex.assertValues([1])

      self.vm.inputs.didReceiveBadgeValue(10)

      self.setBadgeValueAtIndexValue.assertValues(["99+", "10"])
      self.setBadgeValueAtIndexIndex.assertValues([1, 1])

      self.vm.inputs.didReceiveBadgeValue(0)

      self.setBadgeValueAtIndexValue.assertValues(["99+", "10", nil])
      self.setBadgeValueAtIndexIndex.assertValues([1, 1, 1])
    }
  }

  func testSetViewControllers() {
    let viewControllerNames = ValueRecorder<[String]>()

    let previousHandler = self.vm.outputs.onSetViewControllers
    self.vm.outputs.onSetViewControllers = { data in
      previousHandler?(data)
      viewControllerNames.record(extractRootNames(data))
    }

    self.vm.inputs.viewDidLoad()

    viewControllerNames.assertValues(
      [
        ["Discovery", "Activities", "Search", "LoginTout"]
      ],
      "Show the logged out tabs."
    )

    AppEnvironment.login(AccessTokenEnvelope(accessToken: "deadbeef", user: .template))
    self.vm.inputs.userSessionStarted()

    viewControllerNames.assertValues(
      [
        ["Discovery", "Activities", "Search", "LoginTout"],
        ["Discovery", "PPOContainer", "Search", "BackerDashboard"]
      ],
      "Show the logged in tabs."
    )

    AppEnvironment.updateCurrentUser(.template |> \.stats.memberProjectsCount .~ 1)
    self.vm.inputs.currentUserUpdated()

    viewControllerNames.assertValues(
      [
        ["Discovery", "Activities", "Search", "LoginTout"],
        ["Discovery", "PPOContainer", "Search", "BackerDashboard"]
      ],
      "Updating the member projects does not trigger any view controller changes"
    )

    AppEnvironment.logout()
    self.vm.inputs.userSessionEnded()

    viewControllerNames.assertValues(
      [
        ["Discovery", "Activities", "Search", "LoginTout"],
        ["Discovery", "PPOContainer", "Search", "BackerDashboard"],
        ["Discovery", "Activities", "Search", "LoginTout"]
      ],
      "Show the logged out tabs."
    )
  }

  func testViewControllersDontOverEmit() {
    let viewControllerNames = ValueRecorder<[String]>()
    let previousHandler = self.vm.outputs.onSetViewControllers
    self.vm.outputs.onSetViewControllers = { data in
      previousHandler?(data)
      viewControllerNames.record(extractRootNames(data))
    }

    self.vm.inputs.viewDidLoad()

    viewControllerNames.assertValueCount(1)

    withEnvironment(currentUser: User.template) {
      self.vm.inputs.currentUserUpdated()

      viewControllerNames.assertValueCount(2)
    }
  }

  func testUpdateUserLocalePreferences() {
    let viewControllerNames = ValueRecorder<[String]>()
    let previousHandler = self.vm.outputs.onSetViewControllers
    self.vm.outputs.onSetViewControllers = { data in
      previousHandler?(data)
      viewControllerNames.record(extractRootNames(data))
    }

    withEnvironment(language: .en, locale: Locale(identifier: "en")) {
      self.vm.inputs.viewDidLoad()

      viewControllerNames.assertValueCount(1)
      self.tabBarItemsData.assertValueCount(1)
    }

    withEnvironment(language: .de, locale: Locale(identifier: "de")) {
      self.vm.inputs.userLocalePreferencesChanged()

      viewControllerNames.assertValueCount(
        2,
        "The view controllers should be regenerated when the user language or currency changes."
      )
      self.tabBarItemsData.assertValueCount(2)
    }
  }

  func testSelectedIndex() {
    self.selectedIndex.assertValues([], "No index selected before view loads.")

    self.vm.inputs.viewDidLoad()

    self.selectedIndex.assertValues([0], "Default index selected immediately.")

    self.vm.inputs.didSelect(index: 1)
    self.selectedIndex.assertValues([0, 1], "Selects index immediately.")

    self.vm.inputs.didSelect(index: 0)
    self.selectedIndex.assertValues([0, 1, 0], "Selects index immediately.")

    self.vm.inputs.didSelect(index: 2)
    self.selectedIndex.assertValues([0, 1, 0, 2], "Selects index immediately.")

    XCTAssertEqual(
      ["activity_feed", "discover"],
      self.segmentTrackingClient.properties(forKey: "context_page")
    )
    XCTAssertEqual(
      ["discover", "search"],
      self.segmentTrackingClient.properties(forKey: "context_cta")
    )

    self.vm.inputs.didSelect(index: 10)
    self.selectedIndex.assertValues([0, 1, 0, 2, 3], "Selects index immediately.")
  }

  func testScrollToTop() {
    self.scrollToTopControllerName.assertDidNotEmitValue()

    self.vm.inputs.viewDidLoad()

    self.scrollToTopControllerName.assertDidNotEmitValue()

    self.vm.inputs.shouldSelect(index: 1)
    self.vm.inputs.didSelect(index: 1)

    self.scrollToTopControllerName.assertDidNotEmitValue("Selecting index doesn't cause scroll to top.")

    self.vm.inputs.shouldSelect(index: 0)
    self.vm.inputs.didSelect(index: 0)

    self.scrollToTopControllerName.assertDidNotEmitValue(
      "Selecting different index doesn't cause scroll to top."
    )

    self.vm.inputs.shouldSelect(index: 0)
    self.vm.inputs.didSelect(index: 0)

    self.scrollToTopControllerName.assertValues(
      ["Discovery"],
      "Selecting same index again causes scroll to top."
    )
  }

  func testSwitchingTabs() {
    self.vm.inputs.viewDidLoad()
    self.selectedIndex.assertValues([0])
    self.vm.inputs.switchToDiscovery(params: nil)
    self.selectedIndex.assertValues([0, 0])
    self.vm.inputs.switchToActivities()
    self.selectedIndex.assertValues([0, 0, 1])
    self.vm.inputs.switchToSearch()
    self.selectedIndex.assertValues([0, 0, 1, 2])
    self.vm.inputs.switchToProfile()
    self.selectedIndex.assertValues([0, 0, 1, 2])
    self.vm.inputs.switchToLogin()
    self.selectedIndex.assertValues([0, 0, 1, 2, 3])

    AppEnvironment.login(AccessTokenEnvelope(accessToken: "deadbeef", user: .template))
    self.vm.inputs.userSessionStarted()

    self.selectedIndex.assertValues([0, 0, 1, 2, 3, 3])
    self.vm.inputs.switchToProfile()
    self.selectedIndex.assertValues([0, 0, 1, 2, 3, 3, 3])
    self.vm.inputs.switchToLogin()
    self.selectedIndex.assertValues([0, 0, 1, 2, 3, 3, 3])
  }

  func testSwitchToDiscoveryParam() {
    self.vm.inputs.viewDidLoad()

    let params = DiscoveryParams.defaults

    self.filterDiscovery.assertValues([])
    self.vm.inputs.switchToDiscovery(params: params)
    self.filterDiscovery.assertValues([params])
  }

  func testSwitchToSearch() {
    self.selectedIndex.assertDidNotEmitValue()

    self.vm.inputs.viewDidLoad()

    self.selectedIndex.assertLastValue(0)
    self.vm.inputs.switchToSearch()
    self.selectedIndex.assertLastValue(2)
  }

  func testSearchFollowsTheActiveLayoutWithoutSpuriousAnalytics() {
    let remoteConfig = MockRemoteConfigClient()
    withEnvironment(remoteConfigClient: remoteConfig) {
      self.vm.inputs.viewDidLoad()
      self.vm.inputs.didSelect(index: 2)
      self.selectedIndex.assertLastValue(2)

      remoteConfig.features = [RemoteConfigFeature.floatingTabBar.rawValue: true]
      self.vm.inputs.applicationWillEnterForeground()
      self.selectedIndex.assertLastValue(1)
      self.viewControllerNames.assertLastValue(["Discovery", "Search", "LoginTout"])
      self.tabBarItemsData.assertLastValue(TabBarItemsData(
        items: [.home(index: 0), .search(index: 1), .profile(avatarUrl: nil, index: 2)],
        isLoggedIn: false
      ))

      self.vm.inputs.switchToDiscovery(params: nil)
      self.vm.inputs.switchToSearch()
      self.selectedIndex.assertValues([0, 2, 1, 0, 1])

      remoteConfig.features = [:]
      self.vm.inputs.applicationWillEnterForeground()
      self.selectedIndex.assertLastValue(2)
      XCTAssertEqual(self.segmentTrackingClient.properties(forKey: "context_cta"), ["search"])
    }
  }

  func testRemovingTheSelectedActivityTabFallsBackToDiscovery() {
    let remoteConfig = MockRemoteConfigClient()
    withEnvironment(remoteConfigClient: remoteConfig) {
      self.vm.inputs.viewDidLoad()
      self.vm.inputs.didSelect(index: 1)

      remoteConfig.features = [RemoteConfigFeature.floatingTabBar.rawValue: true]
      self.vm.inputs.applicationWillEnterForeground()

      self.selectedIndex.assertValues([0, 1, 0])
    }
  }

  func testBadgeUpdatesSkipFloatingSearchAndResumeOnActivity() {
    let application = MockApplication()
    application.applicationIconBadgeNumber = 5
    let remoteConfig = MockRemoteConfigClient()
    withEnvironment(application: application, remoteConfigClient: remoteConfig) {
      self.vm.inputs.viewDidLoad()
      self.vm.inputs.applicationWillEnterForeground()
      self.setBadgeValueAtIndexValue.assertValues(["5"])
      self.setBadgeValueAtIndexIndex.assertValues([1])

      remoteConfig.features = [RemoteConfigFeature.floatingTabBar.rawValue: true]
      self.vm.inputs.applicationWillEnterForeground()
      self.vm.inputs.didReceiveBadgeValue(8)
      self.vm.inputs.voiceOverStatusDidChange()
      self.vm.inputs.currentUserUpdated()
      self.setBadgeValueAtIndexValue.assertValues(["5"])
      self.setBadgeValueAtIndexIndex.assertValues([1])

      application.applicationIconBadgeNumber = 9
      remoteConfig.features = [:]
      self.vm.inputs.applicationWillEnterForeground()
      self.setBadgeValueAtIndexValue.assertValues(["5", "9"])
      self.setBadgeValueAtIndexIndex.assertValues([1, 1])
    }
  }

  func testTabBarItemStyles() {
    let user = User.template |> \.avatar.small .~ "http://image.com/image"
    let creator = User.template
      |> \.stats.memberProjectsCount .~ 1
      |> \.avatar.small .~ "http://image.com/image2"

    let items: [TabBarItem] = [
      .home(index: 0),
      .activity(index: 1),
      .search(index: 2),
      .profile(avatarUrl: nil, index: 3)
    ]

    let itemsLoggedIn: [TabBarItem] = [
      .home(index: 0),
      .activity(index: 1),
      .search(index: 2),
      .profile(avatarUrl: URL(string: user.avatar.small), index: 3)
    ]

    let itemsCreator: [TabBarItem] = [
      .home(index: 0),
      .activity(index: 1),
      .search(index: 2),
      .profile(avatarUrl: URL(string: creator.avatar.small), index: 3)
    ]

    let tabData = TabBarItemsData(items: items, isLoggedIn: false)
    let tabDataLoggedIn = TabBarItemsData(items: itemsLoggedIn, isLoggedIn: true)
    let tabDataCreator = TabBarItemsData(items: itemsCreator, isLoggedIn: true)

    self.tabBarItemsData.assertValueCount(0)

    self.vm.inputs.viewDidLoad()
    self.tabBarItemsData.assertValues([tabData])

    AppEnvironment.login(AccessTokenEnvelope(accessToken: "deadbeef", user: user))
    self.vm.inputs.userSessionStarted()
    self.tabBarItemsData.assertValues([tabData, tabDataLoggedIn])

    self.vm.inputs.currentUserUpdated()
    self.tabBarItemsData.assertValues([tabData, tabDataLoggedIn, tabDataLoggedIn])

    AppEnvironment.logout()
    self.vm.inputs.userSessionEnded()
    self.tabBarItemsData.assertValues([tabData, tabDataLoggedIn, tabDataLoggedIn, tabData])

    AppEnvironment.login(AccessTokenEnvelope(accessToken: "deadbeef", user: creator))
    self.vm.inputs.userSessionStarted()
    self.tabBarItemsData.assertValues([
      tabData,
      tabDataLoggedIn,
      tabDataLoggedIn,
      tabData,
      tabDataCreator
    ])
  }

  func testSetViewControllers_DoesNotFilterDiscovery() {
    self.filterDiscovery.assertValueCount(0)

    let viewControllerNames = ValueRecorder<[String]>()
    let previousHandler = self.vm.outputs.onSetViewControllers
    self.vm.outputs.onSetViewControllers = { data in
      previousHandler?(data)
      viewControllerNames.record(extractRootNames(data))
    }

    self.vm.inputs.viewDidLoad()

    let params = DiscoveryParams.defaults
    self.vm.inputs.switchToDiscovery(params: params)
    self.filterDiscovery.assertValues([params])

    AppEnvironment.login(AccessTokenEnvelope(accessToken: "deadbeef", user: .template))
    self.vm.inputs.userSessionStarted()

    AppEnvironment.logout()
    self.vm.inputs.userSessionEnded()

    viewControllerNames.assertValueCount(3)
    self.filterDiscovery.assertValues([params])
  }

  func testPPOTabBarBadging_WithoutPersistence() {
    let user = User.template
      |> \.unseenActivityCount .~ 50
      |> \.erroredBackingsCount .~ 4

    self.setBadgeValueAtIndexValue.assertValues([])
    self.setBadgeValueAtIndexIndex.assertValues([])

    withEnvironment(currentUserPPOSettings: nil) {
      self.vm.inputs.viewDidLoad()

      AppEnvironment.login(.init(accessToken: "deadbeef", user: user))
      withEnvironment(currentUserPPOSettings: PPOUserSettings(hasAction: true, backingActionCount: 1)) {
        self.vm.inputs.currentUserUpdated()
      }

      self.setBadgeValueAtIndexValue.assertValues([""])
      self.setBadgeValueAtIndexIndex.assertValues([1])
    }
  }

  func testPPOTabBarBadging_WithPersistence() {
    let user = User.template
      |> \.unseenActivityCount .~ 50
      |> \.erroredBackingsCount .~ 4

    self.setBadgeValueAtIndexValue.assertValues([])
    self.setBadgeValueAtIndexIndex.assertValues([])

    withEnvironment(currentUserPPOSettings: PPOUserSettings(hasAction: true, backingActionCount: 1)) {
      self.vm.inputs.viewDidLoad()

      AppEnvironment.login(.init(accessToken: "deadbeef", user: user))
      self.vm.inputs.currentUserUpdated()

      self.setBadgeValueAtIndexValue.assertValues([""])
      self.setBadgeValueAtIndexIndex.assertValues([1])
    }
  }

  func testSetViewControllers_LoggedIn() {
    withEnvironment(currentUser: nil) {
      self.vm.inputs.viewDidLoad()

      self.viewControllerNames.assertValues(
        [
          ["Discovery", "Activities", "Search", "LoginTout"]
        ],
        "Shows regular Activities tab initially"
      )

      AppEnvironment.login(AccessTokenEnvelope(accessToken: "deadbeef", user: .template))
      self.vm.inputs.userSessionStarted()

      self.viewControllerNames.assertValues(
        [
          ["Discovery", "Activities", "Search", "LoginTout"],
          ["Discovery", "PPOContainer", "Search", "BackerDashboard"]
        ],
        "Shows PPO tab when logged in with feature flag enabled"
      )

      AppEnvironment.logout()
      self.vm.inputs.userSessionEnded()

      self.viewControllerNames.assertValues(
        [
          ["Discovery", "Activities", "Search", "LoginTout"],
          ["Discovery", "PPOContainer", "Search", "BackerDashboard"],
          ["Discovery", "Activities", "Search", "LoginTout"]
        ],
        "Shows regular Activities tab when logged out again"
      )
    }
  }

  func testFloatingTabBarEnabled_DefaultsToStandardTabBarOnFirstLoad() {
    self.floatingTabBarEnabled.assertValues([])
    self.viewControllerNames.assertValues([])

    self.vm.inputs.viewDidLoad()

    self.floatingTabBarEnabled.assertValues(
      [false],
      "First load should default to the standard tab bar to avoid buggy UI states."
    )

    self.viewControllerNames.assertValues(
      [
        ["Discovery", "Activities", "Search", "LoginTout"]
      ],
      "First load should use standard tab bar items order"
    )
  }

  func testFloatingTabBarPolicyComesFromInjectedSettingsFeature() {
    let injectedRemoteConfig = MockRemoteConfigClient()
    injectedRemoteConfig.features = [RemoteConfigFeature.floatingTabBar.rawValue: true]
    let globalRemoteConfig = MockRemoteConfigClient()
    globalRemoteConfig.features = [RemoteConfigFeature.floatingTabBar.rawValue: false]
    let settingsFeature = SettingsFeature(
      sessionFeature: self.sessionFeature,
      applicationSettings: .test(remoteClient: { injectedRemoteConfig }),
      makeProvider: { AsyncAccountPreferencesProvider(service: MockService()) }
    )
    let viewModel = self.makeViewModel(
      profileFeature: ProfileFeature(
        sessionFeature: self.sessionFeature,
        makeProvider: { AsyncProfileProvider(service: MockService()) }
      ),
      settingsFeature: settingsFeature
    )
    var receivedValues: [Bool] = []
    viewModel.outputs.onFloatingTabBarEnabled = { receivedValues.append($0) }

    withEnvironment(remoteConfigClient: globalRemoteConfig) {
      viewModel.inputs.viewDidLoad()
    }

    XCTAssertEqual(receivedValues, [true])
  }

  func testSetViewControllersAndTabBarItemsData_ReTriggerOnAppWillEnterForeground() {
    self.viewControllerNames.assertValues([])
    self.tabBarItemsData.assertValues([])
    self.floatingTabBarEnabled.assertValues([])

    self.vm.inputs.viewDidLoad()

    self.viewControllerNames.assertValueCount(1)
    self.tabBarItemsData.assertValueCount(1)
    self.floatingTabBarEnabled.assertValueCount(1)

    self.vm.inputs.applicationWillEnterForeground()

    self.viewControllerNames.assertValueCount(1, "State didn't change so do not recreate data.")
    self.tabBarItemsData.assertValueCount(1, "State didn't change so do not recreate data.")
    self.floatingTabBarEnabled.assertValueCount(1, "State didn't change so do not recreate data.")

    let remoteConfig = MockRemoteConfigClient()
    remoteConfig.features = [
      RemoteConfigFeature.floatingTabBar.rawValue: true
    ]
    withEnvironment(remoteConfigClient: remoteConfig) {
      self.vm.inputs.applicationWillEnterForeground()

      self.viewControllerNames.assertValueCount(2, "One rebuild for the changed layout.")
      self.tabBarItemsData.assertValueCount(2, "One style update for the changed layout.")
      self.floatingTabBarEnabled.assertValueCount(2, "State changed so recreate data.")
    }
  }
}

@MainActor
final class RootTabsNavigationTests: TestCase {
  override var requiresSnapshotReferenceSimulator: Bool { false }

  func testSearchShortcutSupersedesQueuedFloatingActivityLink() async throws {
    self.remoteConfigClient.features = [RemoteConfigFeature.floatingTabBar.rawValue: true]
    let root = Storyboard.Main.instantiate(RootTabBarViewController.self)
    let window = UIWindow()
    window.rootViewController = root
    let delegate = AppDelegate()
    delegate.window = window

    let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    activity.webpageURL = try XCTUnwrap(URL(string: "https://www.kickstarter.com/activity"))
    XCTAssertTrue(delegate.application(UIApplication.shared, continue: activity, restorationHandler: { _ in }))
    delegate.application(UIApplication.shared, performActionFor: ShortcutItem.search.applicationShortcutItem) {
      XCTAssertTrue($0)
    }
    await root.waitForPresentation()

    let selected = try XCTUnwrap(root.selectedViewController as? UINavigationController)
    XCTAssertTrue(selected.viewControllers.first is SearchViewController)
    let discovery = try XCTUnwrap(root.viewControllers?.first as? UINavigationController)
    XCTAssertEqual(discovery.viewControllers.count, 1)
    XCTAssertTrue(discovery.topViewController is DiscoveryViewController)
  }

  func testFloatingLayoutOpensActivityFromDiscoveryAndCanReturn() async throws {
    self.remoteConfigClient.features = [RemoteConfigFeature.floatingTabBar.rawValue: true]
    let root = Storyboard.Main.instantiate(RootTabBarViewController.self)
    root.switchToSearch()
    await root.waitForPresentation()

    let search = try XCTUnwrap(root.selectedViewController as? UINavigationController)
    XCTAssertTrue(search.viewControllers.first is SearchViewController)
    let discovery = try XCTUnwrap(root.viewControllers?.first as? UINavigationController)
    let discoveryRoot = try XCTUnwrap(discovery.viewControllers.first)

    root.switchToActivities()
    root.switchToActivities()
    await root.waitForPresentation()

    XCTAssertTrue(root.selectedViewController === discovery)
    XCTAssertEqual(discovery.viewControllers.count, 2)
    let activity = try XCTUnwrap(discovery.topViewController as? ActivitiesViewController)
    activity.emptyStatesViewController(
      EmptyStatesViewController.configuredWith(emptyState: .activity),
      goToDiscoveryWithParams: nil
    )
    await root.waitForPresentation()
    XCTAssertEqual(discovery.viewControllers, [discoveryRoot])
  }

  func testMessageLinkOpensOnProfileAndPreservesDiscoveryStack() async throws {
    AppEnvironment.replaceCurrentEnvironment(currentUser: .template)
    let root = Storyboard.Main.instantiate(RootTabBarViewController.self)
    root.loadViewIfNeeded()
    await root.waitForPresentation()
    let discovery = try XCTUnwrap(root.selectedViewController as? UINavigationController)
    let discoveryRoot = try XCTUnwrap(discovery.viewControllers.first)
    XCTAssertTrue(discoveryRoot is DiscoveryViewController)

    root.switchToMessageThread(.template)
    await root.waitForPresentation()

    let profile = try XCTUnwrap(root.selectedViewController as? UINavigationController)
    XCTAssertTrue(profile.viewControllers.first is BackerDashboardViewController)
    XCTAssertEqual(profile.viewControllers.count, 3)
    XCTAssertTrue(profile.viewControllers.dropFirst().first is MessageThreadsViewController)
    XCTAssertTrue(profile.topViewController is MessagesViewController)
    XCTAssertEqual(discovery.viewControllers, [discoveryRoot])
  }

  func testMessageLinkCanOpenBeforeTheTabsLoad() async throws {
    AppEnvironment.replaceCurrentEnvironment(currentUser: .template)
    let root = Storyboard.Main.instantiate(RootTabBarViewController.self)
    XCTAssertFalse(root.isViewLoaded)

    root.switchToMessageThread(.template)
    await root.waitForPresentation()

    let profile = try XCTUnwrap(root.selectedViewController as? UINavigationController)
    XCTAssertTrue(profile.viewControllers.first is BackerDashboardViewController)
    XCTAssertTrue(profile.topViewController is MessagesViewController)
  }

  func testQueuedMessageLinkDoesNotOpenAfterSessionEnds() async throws {
    AppEnvironment.replaceCurrentEnvironment(currentUser: .template)
    let root = Storyboard.Main.instantiate(RootTabBarViewController.self)
    root.loadViewIfNeeded()
    await root.waitForPresentation()
    let profile = try XCTUnwrap(root.viewControllers?.last as? UINavigationController)
    XCTAssertTrue(profile.viewControllers.first is BackerDashboardViewController)

    root.switchToMessageThread(.template)
    AppEnvironment.replaceCurrentEnvironment(currentUser: nil)
    await root.waitForPresentation()

    XCTAssertEqual(profile.viewControllers.count, 1)
  }
}

@MainActor
private func extractRootNames(_ vcs: [RootViewControllerData]) -> [String] {
  let root = RootTabBarViewController.instantiate()
  return vcs
    .map { root.viewController(from: $0) }
    .compact()
    .map(UINavigationController.init(rootViewController:))
    .compactMap(extractRootName)
}

private func extractRootName(_ vc: UIViewController) -> String? {
  return (vc as? UINavigationController)?
    .viewControllers
    .first
    .map(extractName)
}

private func extractName(_ vc: UIViewController) -> String {
  return "\(type(of: vc))".replacingOccurrences(of: "ViewController", with: "")
}

/// Controlled suspension with bounded admission waits. Tests explicitly release
/// all continuations on exit, including assertion/setup failures.
@MainActor
private final class RootAvatarRequestGate<Value> {
  private(set) var count = 0
  private var pending: [CheckedContinuation<Value, Error>?] = []
  private var waits: [(Int, XCTestExpectation)] = []

  func request() async throws -> Value {
    self.count += 1
    return try await withCheckedThrowingContinuation { continuation in
      self.pending.append(continuation)
      for (count, expectation) in self.waits where count == self.count { expectation.fulfill() }
    }
  }

  func waitFor(_ count: Int) async {
    if self.count >= count { return }
    let expectation = XCTestExpectation(description: "Account request admission")
    self.waits.append((count, expectation))
    let result = await XCTWaiter().fulfillment(of: [expectation], timeout: 2)
    XCTAssertEqual(result, .completed)
  }

  func finish(_ index: Int, _ result: Result<Value, Error>) throws {
    guard self.pending.indices.contains(index) else { XCTFail("Missing request"); return }
    let continuation = try XCTUnwrap(self.pending[index])
    self.pending[index] = nil
    continuation.resume(with: result)
  }

  func releaseAll() {
    for continuation in self.pending { continuation?.resume(throwing: CancellationError()) }
    self.pending.removeAll()
  }
}
