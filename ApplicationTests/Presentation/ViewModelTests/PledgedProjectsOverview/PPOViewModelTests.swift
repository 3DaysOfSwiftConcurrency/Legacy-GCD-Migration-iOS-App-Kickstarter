@testable import Kickstarter_iOS
import Combine
import GraphAPI

@testable import KsApi


import XCTest

@MainActor
class PPOViewModelTests: XCTestCase {
  private var analyticsEventCount = 0
  private var trackedCardEvents: [PledgedProjectsFeature.Analytics.CardEvent] = []
  private let session = SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) })
  private lazy var settings = SettingsFeature(
    sessionFeature: self.session,
    applicationSettings: .test(remoteClient: { AppEnvironment.current.remoteConfigClient }),
    makeProvider: { AsyncAccountPreferencesProvider(service: MockService()) }
  )
  private lazy var feature = PledgedProjectsFeature(
    sessionFeature: self.session, settingsFeature: self.settings,
    makeProvider: {
      precondition(AppEnvironment.current.apiService is MockService)
      return AsyncPledgedProjectsProvider(service: AppEnvironment.current.apiService)
    }, locale: { AppEnvironment.current.locale }, analytics: .init(
      dashboardOpened: { _ in self.analyticsEventCount += 1 },
      cardEvent: { event, _, _ in
        self.trackedCardEvents.append(event)
        self.analyticsEventCount += 1
      },
      addressConfirmed: { _, _ in self.analyticsEventCount += 1 }
    ))
  var viewModel: PPOViewModel!
  var cancellables: Set<AnyCancellable>!

  override func setUp() async throws {
    try await super.setUp()
    MainActor.assumeIsolated {
      self.analyticsEventCount = 0
      self.trackedCardEvents = []
      self.viewModel = PPOViewModel(pledgedProjectsFeature: self.feature)
      self.cancellables = []
    }
  }

  override func tearDown() async throws {
    MainActor.assumeIsolated {
      self.feature.reset()
      self.viewModel = nil
      self.cancellables = nil
    }
    try await super.tearDown()
  }

  func testPresentationReadsFeaturePolicyAndPreservesIndependentV2Heading() {
    let remoteConfig = MockRemoteConfigClient()
    remoteConfig.features = [
      RemoteConfigFeature.pledgedProjectsOverviewV2Enabled.rawValue: true,
      RemoteConfigFeature.pledgedProjectsOverviewV4Enabled.rawValue: true
    ]
    withEnvironment(remoteConfigClient: remoteConfig) {
      XCTAssertEqual(self.viewModel.listHeaderTitle(numberOfValues: 2), Strings.Backings())
      XCTAssertEqual(self.viewModel.emptyStatePresentation, PPOEmptyStatePresentation(
        title: Strings.No_backings(),
        description: Strings.When_youve_backed_a_project_itll_show_up_here(),
        action: .exploreProjects
      ))
    }

    remoteConfig.features[RemoteConfigFeature.pledgedProjectsOverviewV2Enabled.rawValue] = false
    remoteConfig.features[RemoteConfigFeature.pledgedProjectsOverviewV4Enabled.rawValue] = false
    withEnvironment(remoteConfigClient: remoteConfig) {
      XCTAssertEqual(
        self.viewModel.listHeaderTitle(numberOfValues: 2),
        Strings.Alerts_count(count: 2.formatted())
      )
      XCTAssertEqual(self.viewModel.emptyStatePresentation.action, .backedProjects)
      XCTAssertEqual(self.viewModel.emptyStatePresentation.title, Strings.Youre_all_caught_up())
    }
  }

  func testInitialLoading_Once() async throws {
    let expectation = XCTestExpectation(description: "Initial loading")
    expectation.expectedFulfillmentCount = 3

    var values: [PPOViewModelResult] = []
    self.viewModel.$results
      .sink { value in
        values.append(value)
        expectation.fulfill()
      }
      .store(in: &self.cancellables)

    await withEnvironment(apiService: MockService(
      fetchPledgedProjectsResult: Result.success(try GraphAPI.FetchPledgedProjectsQuery.fakeData())
    )) { () async in
      self.viewModel.viewDidAppear()
      await self.feature.waitForOperations()
    }

    await fulfillment(of: [expectation], timeout: 2)

    guard
      case .unloaded = values[0],
      case .loading = values[1],
      case let .allLoaded(data, _) = values[2]
    else {
      return XCTFail()
    }
    XCTAssertEqual(data.count, 3)
    XCTAssertEqual(data.count, 3)
  }

  func testInitialLoading_Twice() async throws {
    let expectation = XCTestExpectation(description: "Initial loading twice")
    expectation.expectedFulfillmentCount = 3

    var values: [PPOViewModelResult] = []
    self.viewModel.$results
      .sink { value in
        values.append(value)
        expectation.fulfill()
      }
      .store(in: &self.cancellables)

    await withEnvironment(apiService: MockService(
      fetchPledgedProjectsResult: Result.success(try GraphAPI.FetchPledgedProjectsQuery.fakeData())
    )) { () async in
      self.viewModel.viewDidAppear()
      self.viewModel.viewDidAppear() // This should not trigger another load
      await self.feature.waitForOperations()
    }

    await fulfillment(of: [expectation], timeout: 2)

    XCTAssertEqual(values.count, 3)

    guard
      case .unloaded = values[0],
      case .loading = values[1],
      case let .allLoaded(data, _) = values[2]
    else {
      return XCTFail()
    }
    XCTAssertEqual(data.count, 3)
  }

  func testPullToRefresh_Once() async throws {
    let initialLoadExpectation = XCTestExpectation(description: "Initial load")
    initialLoadExpectation.expectedFulfillmentCount = 3
    let fullyLoadedExpectation = XCTestExpectation(description: "Pull to refresh")
    fullyLoadedExpectation.expectedFulfillmentCount = 5

    var values: [PPOViewModelResult] = []

    self.viewModel.$results
      .sink { value in
        values.append(value)
        initialLoadExpectation.fulfill()
        fullyLoadedExpectation.fulfill()
      }
      .store(in: &self.cancellables)

    await withEnvironment(apiService: MockService(
      fetchPledgedProjectsResult: Result
        .success(try GraphAPI.FetchPledgedProjectsQuery.fakeData(cursors: 1...3))
    )) { () async in
      self.viewModel.viewDidAppear() // Initial load
      await self.feature.waitForOperations()
    }

    await fulfillment(of: [initialLoadExpectation], timeout: 2)

    await withEnvironment(apiService: MockService(
      fetchPledgedProjectsResult: Result
        .success(try GraphAPI.FetchPledgedProjectsQuery.fakeData(cursors: 1...2))
    )) { () async in
      await self.viewModel.refresh()
    }

    await fulfillment(of: [fullyLoadedExpectation], timeout: 2)

    XCTAssertEqual(values.count, 5)

    guard
      case .unloaded = values[0],
      case .loading = values[1],
      case let .allLoaded(firstData, _) = values[2]
    else {
      return XCTFail()
    }
    XCTAssertEqual(firstData.count, 3)

    guard
      case .loading = values[3],
      case let .allLoaded(secondData, _) = values[4]
    else {
      return XCTFail()
    }
    XCTAssertEqual(secondData.count, 2)
  }

  func testPullToRefresh_Twice() async throws {
    let initialLoadExpectation = XCTestExpectation(description: "Initial load")
    initialLoadExpectation.expectedFulfillmentCount = 3
    let fullyLoadedExpectation = XCTestExpectation(description: "Pull to refresh twice")
    fullyLoadedExpectation.expectedFulfillmentCount = 7

    var values: [PPOViewModelResult] = []

    self.viewModel.$results
      .sink { value in
        values.append(value)
        initialLoadExpectation.fulfill()
        fullyLoadedExpectation.fulfill()
      }
      .store(in: &self.cancellables)

    await withEnvironment(apiService: MockService(
      fetchPledgedProjectsResult: Result
        .success(try GraphAPI.FetchPledgedProjectsQuery.fakeData(cursors: 1...3))
    )) { () async in
      self.viewModel.viewDidAppear() // Initial load
      await self.feature.waitForOperations()
    }

    await fulfillment(of: [initialLoadExpectation], timeout: 2)

    await withEnvironment(apiService: MockService(
      fetchPledgedProjectsResult: Result
        .success(try GraphAPI.FetchPledgedProjectsQuery.fakeData(cursors: 1...2))
    )) { () async in
      await self.viewModel.refresh() // Refresh
    }

    await withEnvironment(apiService: MockService(
      fetchPledgedProjectsResult: Result
        .success(try GraphAPI.FetchPledgedProjectsQuery.fakeData(cursors: 1...16))
    )) { () async in
      await self.viewModel.refresh() // Refresh a second time
    }

    await fulfillment(of: [fullyLoadedExpectation], timeout: 2)

    XCTAssertEqual(values.count, 7)

    guard
      case .unloaded = values[0],
      case .loading = values[1],
      case let .allLoaded(firstData, _) = values[2]
    else {
      return XCTFail()
    }
    XCTAssertEqual(firstData.count, 3)

    guard
      case .loading = values[3],
      case let .allLoaded(secondData, _) = values[4]
    else {
      return XCTFail()
    }
    XCTAssertEqual(secondData.count, 2)

    guard
      case .loading = values[5],
      case let .allLoaded(thirdData, _) = values[6]
    else {
      return XCTFail()
    }
    XCTAssertEqual(thirdData.count, 16)
  }

  func testLoadMore() async throws {
    let initialLoadExpectation = XCTestExpectation(description: "Initial load")
    initialLoadExpectation.expectedFulfillmentCount = 3
    let fullyLoadedExpectation = XCTestExpectation(description: "Load more")
    fullyLoadedExpectation.expectedFulfillmentCount = 5

    var values: [PPOViewModelResult] = []

    self.viewModel.$results
      .sink { value in
        values.append(value)
        initialLoadExpectation.fulfill()
        fullyLoadedExpectation.fulfill()
      }
      .store(in: &self.cancellables)

    await withEnvironment(apiService: MockService(
      fetchPledgedProjectsResult: Result.success(try GraphAPI.FetchPledgedProjectsQuery.fakeData(
        cursors: 1...4,
        hasNextPage: true
      ))
    )) { () async in
      self.viewModel.viewDidAppear() // Initial load
      await self.feature.waitForOperations()
    }

    await fulfillment(of: [initialLoadExpectation], timeout: 2)

    await withEnvironment(apiService: MockService(
      fetchPledgedProjectsResult: Result
        .success(try GraphAPI.FetchPledgedProjectsQuery.fakeData(cursors: 5...7))
    )) { () async in
      await self.viewModel.loadMore() // Load next page
    }

    await fulfillment(of: [fullyLoadedExpectation], timeout: 2)

    XCTAssertEqual(values.count, 5)

    guard
      case .unloaded = values[0],
      case .loading = values[1],
      case let .someLoaded(firstData, cursor, _, _) = values[2]
    else {
      return XCTFail()
    }
    XCTAssertEqual(firstData.count, 4)
    XCTAssertEqual(cursor, "4")

    guard
      case .loading = values[3],
      case let .allLoaded(secondData, _) = values[4]
    else {
      return XCTFail()
    }
    XCTAssertEqual(secondData.count, 7)
  }

  func testEventConfirmAddress() {
    let template = PPOProjectCardModel.confirmAddressTemplate
    let address = "fake address"
    let addressId = "fake id"
    let cardEvent = PPOCardEvent.confirmAddress(address: address, addressId: addressId)
    self.verifyPreparedEvent(
      { self.viewModel.handleCardEvent(cardEvent, from: template) },
      event: .confirmAddress(
        backingId: template.backingGraphId,
        addressId: addressId,
        address: address,
        onProgress: { _ in }
      )
    )
  }

  func testEventContactCreator() {
    self.verifyPreparedEvent(
      { self.viewModel.handleCardEvent(.sendMessage, from: .addressLockTemplate) },
      event: .contactCreator(messageSubject: MessageSubject.project(
        id: PPOProjectCardModel.addressLockTemplate.projectId,
        name: PPOProjectCardModel.addressLockTemplate.projectName
      ))
    )
  }

  func testEventFix3DSChallenge() {
    let clientSecret = "xyz"
    let onProgress: (PPOActionState) -> Void = { _ in }
    let cardEvent = PPOCardEvent.authenticateCard(
      clientSecret: clientSecret,
      onProgress: onProgress
    )
    self.verifyPreparedEvent(
      { self.viewModel.handleCardEvent(cardEvent, from: .authenticateCardTemplate) },
      event: .fix3DSChallenge(clientSecret: clientSecret, onProgress: onProgress)
    )
  }

  func testEventFixPaymentMethod() {
    let template = PPOProjectCardModel.fixPaymentTemplate
    self.verifyPreparedEvent(
      { self.viewModel.handleCardEvent(.fixPayment, from: template) },
      event: .fixPaymentMethod(
        projectId: template.projectId,
        backingId: template.backingId
      )
    )
  }

  func testEventOpenSurvey() {
    let template = PPOProjectCardModel.completeSurveyTemplate
    let url = "fakeSurveyUrl"
    self.verifyPreparedEvent(
      { self.viewModel.handleCardEvent(.completeSurvey(url: url), from: template) },
      event: .survey(url: url)
    )
  }

  func testEventOpenPledgeManager() {
    let template = PPOProjectCardModel.openPledgeManagerTemplate
    let url = "fakePledgeManagerUrl"
    self.verifyPreparedEvent(
      { self.viewModel.handleCardEvent(.openPledgeManager(url: url), from: template) },
      event: .openPledgeManager(url: url)
    )
  }

  func testEventViewProjectDetails() {
    let template = PPOProjectCardModel.noRewardPledgeCollected
    let param = template.projectPageParam!
    self.verifyPreparedEvent(
      // This could be tested with any template. All cards allow the user to view project details.
      { self.viewModel.handleCardEvent(.viewProjectDetails(param: param), from: template) },
      event: .projectDetails(param: param)
    )
  }

  func testAnalyticsEvents_NotTriggeredOnRefresh() async throws {
    let mockService = MockService(
      fetchPledgedProjectsResult: Result
        .success(try GraphAPI.FetchPledgedProjectsQuery.fakeData(cursors: 1...3))
    )

    let reloadedMockService = MockService(
      fetchPledgedProjectsResult: Result
        .success(try GraphAPI.FetchPledgedProjectsQuery.fakeData(cursors: 4...6))
    )

    let initialLoadExpectation = XCTestExpectation(description: "Initial load")
    initialLoadExpectation.expectedFulfillmentCount = 3
    let refreshExpectation = XCTestExpectation(description: "Refresh complete")
    refreshExpectation.expectedFulfillmentCount = 4

    var values: [PPOViewModelResult] = []
    self.viewModel.$results
      .sink { value in
        values.append(value)
        initialLoadExpectation.fulfill()
        refreshExpectation.fulfill()
      }
      .store(in: &self.cancellables)

    await withEnvironment(apiService: mockService) { () async in
      self.viewModel.viewDidAppear()

      // Trigger some actions that generate analytics
      self.viewModel.handleCardEvent(.completeSurvey(url: "fakeUrl"), from: .completeSurveyTemplate)
      self.viewModel.handleCardEvent(.fixPayment, from: .fixPaymentTemplate)
      self.viewModel.handleCardEvent(.sendMessage, from: .addressLockTemplate)

      await fulfillment(of: [initialLoadExpectation], timeout: 2)

      // Store analytics event counts before refresh
      let trackCountBefore = self.analyticsEventCount
      XCTAssertEqual(trackCountBefore, 4)
      XCTAssertEqual(self.trackedCardEvents.count, 3)
      XCTAssertTrue(self.trackedCardEvents.contains(.completeSurvey))
      XCTAssertTrue(self.trackedCardEvents.contains(.fixPayment))
      XCTAssertTrue(self.trackedCardEvents.contains(.sendMessage))

      await withEnvironment(apiService: reloadedMockService) { () async in
        await self.viewModel.refresh()
      }

      await fulfillment(of: [refreshExpectation], timeout: 2)

      // Verify analytics events weren't triggered again
      XCTAssertEqual(self.analyticsEventCount, trackCountBefore)
    }
  }

  func testInitialLoading_Empty() async throws {
    let expectation = XCTestExpectation(description: "Initial loading empty")
    expectation.expectedFulfillmentCount = 3

    var values: [PPOViewModelResult] = []
    self.viewModel.$results
      .sink { value in
        values.append(value)
        expectation.fulfill()
      }
      .store(in: &self.cancellables)

    await withEnvironment(apiService: MockService(
      fetchPledgedProjectsResult: Result.success(try GraphAPI.FetchPledgedProjectsQuery.fakeData(
        cursors: nil,
        hasNextPage: false
      ))
    )) { () async in
      self.viewModel.viewDidAppear()
      await self.feature.waitForOperations()
    }

    await fulfillment(of: [expectation], timeout: 2)

    XCTAssertEqual(values.count, 3)

    guard
      case .unloaded = values[0],
      case .loading = values[1],
      case .empty = values[2]
    else {
      return XCTFail()
    }
  }

  // Setup the view model to monitor prepared events, then run the closure, then check to make sure only that one event fired
  private func verifyPreparedEvent(_ closure: () -> Void, event: PPOPreparedEvent) {
    let beforeResults: PPOViewModelResult = self.viewModel.results

    let expectation = self.expectation(description: "VerifyPreparedEvent \(event)")

    var values: [PPOPreparedEvent] = []
    self.viewModel.preparedEvents
      .collect(.byTime(DispatchQueue.main, 0.1))
      .sink(receiveValue: { v in
        values = v
        expectation.fulfill()
      })
      .store(in: &self.cancellables)

    closure()

    self.wait(for: [expectation], timeout: 1)

    let afterResults: PPOViewModelResult = self.viewModel.results

    XCTAssertEqual(values.count, 1)
    guard case event = values[0] else {
      return XCTFail()
    }

    XCTAssertEqual(beforeResults, afterResults)
  }
}
