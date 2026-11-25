@testable import Kickstarter_iOS
import GraphAPI
@testable import KsApi


import Prelude
import XCTest

@MainActor
final class ProjectPageRelatedProjectsTests: TestCase {
  override var requiresSnapshotReferenceSimulator: Bool { false }
  private var vm: ProjectPageViewModel!
  private var tappedProjects: [ProjectCardProperties] = []
  private var states: [SimilarProjectsState] = []
  private var details: ProjectDetailsFeature!

  override func setUp() async throws {
    try await super.setUp()
    let nodes = (1...4).map { self.createMockProjectNode(id: $0, name: "Project \($0)") }
    let data = GraphAPI.FetchSimilarProjectsQuery.Data(projects: .init(nodes: nodes))
    let service = MockService(
      fetchGraphQLResponses: [(GraphAPI.FetchSimilarProjectsQuery.self, data)],
      fetchProjectPamphletResult: .success(.init(project: .template, backingId: nil)),
      fetchProjectRewardsResult: .success([.template])
    )
    self.prepare(provider: AsyncProjectDetailsProvider(service: service))
  }

  private func prepare(provider: any ProjectDetailsProvider) {
    let session = SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) })
    self.details = ProjectDetailsFeature(
      platform: .live(), sessionFeature: session,
      discussionFeature: DiscussionFeature(platform: .live(), sessionFeature: session,
        makeProvider: { AsyncDiscussionProvider(service: MockService()) }),
      makeProvider: { provider }, useFastLoading: { false }, includeRichText: { false },
      sleep: { _ in try Task.checkCancellation() }
    )
    self.vm = ProjectPageViewModelTests.makeViewModel(
      details: self.details,
      media: ProjectMediaFeature(sessionFeature: session,
        makeProvider: { AsyncProjectMediaProvider(service: MockService()) })
    )
    self.vm.onShowProjectPageTab = { [weak self] in self?.states.append($0.5) }
    self.vm.onNavigateToSimilarProject = { [weak self] in self?.tappedProjects.append($0) }
  }

  private func loadPage() async {
    self.vm.configureAndLoad(.left(.template))
    self.vm.projectNavigationSelectorViewDidSelect(index: NavigationSection.campaign.rawValue)
    await self.vm.loadingTask?.value
    await self.vm.waitForRelatedProjects()
  }

  override func tearDown() async throws {
    self.vm = nil
    self.details = nil
    try await super.tearDown()
  }

  func testInitialState() async {
    XCTAssertTrue(self.states.isEmpty)
    await self.loadPage()
    guard case .loading? = self.states.first else { return XCTFail("Expected initial loading state") }
  }

  func testProjectLoadedEmitsRelatedProjects() async {
    await self.loadPage()
    guard case let .loaded(projects)? = self.states.last else { return XCTFail("Expected recommendations") }
    XCTAssertEqual(projects.count, 4)
  }

  func testRelatedProjectSelectionNavigates() async throws {
    await self.loadPage()
    guard case let .loaded(projects)? = self.states.last else { return XCTFail("Expected recommendations") }
    let project = try XCTUnwrap(projects.first)
    self.vm.similarProjectTapped(project: project)
    XCTAssertEqual(self.tappedProjects.map(\.projectID), [project.projectID])
  }

  func testSessionChangeClearsLoadedRecommendationsAndReloadsTheSameProject() async {
    await self.loadPage()
    guard case .loaded? = self.states.last else { return XCTFail("Expected recommendations") }
    self.details.sessionFeature.sessionChanged()
    self.vm.userSessionChanged()
    self.vm.projectNavigationSelectorViewDidSelect(index: NavigationSection.overview.rawValue)
    guard case .loading? = self.states.last else { return XCTFail("Expected fresh state") }
    await self.vm.loadingTask?.value
    await self.vm.waitForRelatedProjects()
    guard case .loaded? = self.states.last else { return XCTFail("Expected replacement recommendations") }
  }

  func testNewProjectDisplaysLoadingUntilItsOwnRecommendationsComplete() async throws {
    let provider = ControlledProjectDetailsProvider()
    provider.pauseProjects = true
    provider.pauseRelated = true
    defer { provider.releaseAll() }
    self.prepare(provider: provider)
    self.vm.configureAndLoad(.left(.template))
    self.vm.projectNavigationSelectorViewDidSelect(index: NavigationSection.campaign.rawValue)
    await provider.waitFor("project")
    try provider.finishProject(0, id: 1)
    await self.vm.loadingTask?.value
    await provider.waitFor("related:1")
    try provider.finishRelated(0, error: nil)
    await self.vm.waitForRelatedProjects()
    guard case .loaded? = self.states.last else { return XCTFail("Expected first project's recommendations") }

    let next = Project.template |> Project.lens.id .~ 2
    self.vm.configureWith(projectOrParam: .left(next), refInfo: nil)
    self.vm.viewDidLoad()
    await provider.waitFor("project", count: 2)
    try provider.finishProject(1, id: 2)
    await self.vm.loadingTask?.value
    await provider.waitFor("related:2")
    guard case .loading? = self.states.last else { return XCTFail("Expected replacement loading state") }

    try provider.finishRelated(1, error: .graphError("replacement failed"))
    await self.vm.waitForRelatedProjects()
    guard case .error? = self.states.last else { return XCTFail("Expected current project's error") }
  }

  func testRefreshingTheSameProjectKeepsItsCompletedRecommendations() async {
    let provider = ControlledProjectDetailsProvider()
    self.prepare(provider: provider)
    await self.loadPage()
    guard case .loaded? = self.states.last else { return XCTFail("Expected recommendations") }

    self.vm.didBackProject()
    await self.vm.loadingTask?.value
    await self.vm.waitForRelatedProjects()

    XCTAssertEqual(provider.calls.filter { $0.hasPrefix("related:") }.count, 1)
    guard case .loaded? = self.states.last else { return XCTFail("Expected retained recommendations") }
  }

  // MARK: - SimilarProject Parsing Tests

  func testSimilarProjectParsing_ValidData_Success() async throws {
    // Create a valid ProjectCardFragment with all required fields
    let validProjectFragment = self.createMockProjectNode()

    // Test the parsing constructor
    let similarProject =
      try XCTUnwrap(ProjectCardProperties(validProjectFragment.fragments.projectCardFragment))

    // Verify the parsing succeeded
    XCTAssertNotNil(similarProject, "Parsing should succeed with valid data")

    // Verify the parsed data is correct
    XCTAssertEqual(similarProject.projectID, 123)
    XCTAssertEqual(similarProject.name, "Test Project")
    XCTAssertEqual(similarProject.isLaunched, true)
    XCTAssertEqual(similarProject.isPrelaunchActivated, false)
    XCTAssertEqual(similarProject.percentFunded, 75)
    XCTAssertEqual(similarProject.state, .live)

    // Verify dates are parsed correctly
    XCTAssertEqual(
      similarProject.launchedAt?.timeIntervalSince1970 ?? 0,
      TimeInterval(1_741_737_648),
      accuracy: 0.001
    )
    XCTAssertEqual(
      similarProject.deadlineAt?.timeIntervalSince1970 ?? 0,
      TimeInterval(1_742_737_648),
      accuracy: 0.001
    )

    // Verify money is parsed correctly
    XCTAssertEqual(similarProject.goal?.amount, 10_000)
    XCTAssertEqual(similarProject.pledged?.amount, 7_500)
  }

  func testSimilarProjectParsing_InvalidData_ReturnsNil() async {
    // Test with missing image URL
    let missingImageFragment = self.createMockProjectNode(imageURL: nil)

    let missingImageProject = ProjectCardProperties(missingImageFragment.fragments.projectCardFragment)
    XCTAssertNil(missingImageProject, "Parsing should fail with missing image URL")

    // Test with invalid image URL
    let invalidImageFragment = self.createMockProjectNode(imageURL: "127.0.0.1:8000/test")

    let invalidImageProject = ProjectCardProperties(invalidImageFragment.fragments.projectCardFragment)
    XCTAssertNil(invalidImageProject, "Parsing should fail with invalid image URL")

    // Test with invalid state
    let invalidStateNode = self.createMockProjectNode(state: "invalid_state")

    let invalidStateProject = ProjectCardProperties(invalidStateNode.fragments.projectCardFragment)
    XCTAssertNil(invalidStateProject, "Parsing should fail with invalid state")
  }

  // MARK: - ProjectPamphletMainCellProperties Tests

  func testProjectPamphletMainCellProperties_DirectProperties() async {
    // Create a mock project node with specific values
    let mockNode = self.createMockProjectNode(
      id: 456,
      name: "Test Project Properties",
      imageURL: "https://example.com/test-image.jpg",
      state: "LIVE",
      goal: 50_000,
      pledged: 25_000
    )

    // Get the ProjectPamphletMainCellProperties from the node
    let properties = mockNode
      .fragments.projectCardFragment
      .fragments.projectPamphletMainCellPropertiesFragment
      .projectPamphletMainCellProperties

    // Test direct properties
    XCTAssertEqual(properties.name, "Test Project Properties")
    XCTAssertEqual(properties.photo, "https://example.com/test-image.jpg")
    XCTAssertEqual(properties.state, .live)
    XCTAssertEqual(properties.goal.amount, 50_000)
    XCTAssertEqual(properties.pledged.amount, 25_000)
    XCTAssertEqual(properties.goal.currency, "USD")
    XCTAssertEqual(properties.pledged.currency, "USD")
    XCTAssertEqual(properties.goal.symbol, "$")
    XCTAssertEqual(properties.pledged.symbol, "$")
    XCTAssertEqual(properties.webURL, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
  }

  func testProjectPamphletMainCellProperties_DerivedProperties() async {
    // Create a mock project node with specific values for testing derived properties
    let mockNode = self.createMockProjectNode(
      id: 789,
      name: "Derived Properties Test",
      goal: 100_000,
      pledged: 75_000,
      projectUsdExchangeRate: 0.127515614
    )

    // Get the ProjectPamphletMainCellProperties from the node
    let properties = mockNode
      .fragments.projectCardFragment
      .fragments.projectPamphletMainCellPropertiesFragment
      .projectPamphletMainCellProperties

    // Test derived properties
    XCTAssertEqual(properties.fundingProgress, 0.75, accuracy: 0.001)
    XCTAssertFalse(properties.goalMet)

    // Test USD conversion properties
    XCTAssertEqual(properties.projectUsdExchangeRate, 0.127515614)
    XCTAssertEqual(properties.pledgedUsd, floor(Float(75_000) * properties.projectUsdExchangeRate))
    XCTAssertEqual(properties.goalUsd, floor(Float(100_000) * properties.projectUsdExchangeRate))

    // Test currency-related properties
    XCTAssertEqual(properties.resolvedCurrencyCode(fallback: nil), "USD")
    XCTAssertEqual(properties.currency, properties.resolvedCurrencyCode(fallback: nil))
  }

  func testProjectPamphletMainCellProperties_GoalMet() async {
    // Test when goal is met (pledged >= goal)
    let goalMetNode = self.createMockProjectNode(
      goal: 10_000,
      pledged: 10_000 // Exactly met
    )

    let goalMetProperties = goalMetNode
      .fragments.projectCardFragment
      .fragments.projectPamphletMainCellPropertiesFragment
      .projectPamphletMainCellProperties

    XCTAssertTrue(goalMetProperties.goalMet)

    // Test when goal is exceeded
    let goalExceededNode = self.createMockProjectNode(
      goal: 10_000,
      pledged: 15_000 // Exceeded
    )

    let goalExceededProperties = goalExceededNode
      .fragments.projectCardFragment
      .fragments.projectPamphletMainCellPropertiesFragment
      .projectPamphletMainCellProperties

    XCTAssertTrue(goalExceededProperties.goalMet)
  }

  func testProjectPamphletMainCellProperties_CurrencyConversion() async {
    // Create a mock project with different currency
    let mockNode = self.createMockProjectNode()
    let properties = mockNode
      .fragments.projectCardFragment
      .fragments.projectPamphletMainCellPropertiesFragment
      .projectPamphletMainCellProperties

    XCTAssertEqual(properties.currency, "USD")
    XCTAssertEqual(properties.resolvedCurrencyCode(fallback: nil), "USD")
    XCTAssertEqual(properties.resolvedCurrencyCode(fallback: "CAD"), "CAD")
  }

  func testProjectPamphletMainCellProperties_ZeroPledgeHandling() async {
    let zeroPledgeNode = self.createMockProjectNode(
      goal: 1_000,
      pledged: 0
    )

    let zeroPledgeProperties = zeroPledgeNode
      .fragments.projectCardFragment
      .fragments.projectPamphletMainCellPropertiesFragment
      .projectPamphletMainCellProperties

    XCTAssertEqual(zeroPledgeProperties.fundingProgress, 0.0)
    XCTAssertFalse(zeroPledgeProperties.goalMet)
  }

  // MARK: - Helpers

  // Helper method to create mock project nodes for testing
  private func createMockProjectNode(
    id: Int = 123,
    name: String = "Test Project",
    projectDescription: String = "Test blurb",
    imageURL: String? = "https://example.com/image.jpg",
    state: String = "live",
    isLaunched: Bool = true,
    prelaunchActivated: Bool = false,
    launchedAt: String? = "1741737648",
    deadlineAt: String? = "1742737648",
    percentFunded: Int = 75,
    goal: Double? = 10_000,
    pledged: Double = 7_500,
    isInPostCampaignPledgingPhase: Bool = false,
    isPostCampaignPledgingEnabled: Bool = false,
    url: String = "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    stateChangedAt: String = "1741737000",
    backersCount: Int = 150,
    fxRate: Float = 1.0,
    projectUsdExchangeRate: Float = 1.0,
    currency: String = "USD",
    countryCode: String = "US",
    countryName: String = "United States"
  ) -> GraphAPI.FetchSimilarProjectsQuery.Data.Projects.Node {
    let projectState = GraphAPI.ProjectState(rawValue: state.uppercased())
    let wrappedState = projectState.isSome ? GraphQLEnum.case(projectState!) : .unknown(state)

    return GraphAPI.FetchSimilarProjectsQuery.Data.Projects.Node(
      image: imageURL.isSome ? GraphAPI.FetchSimilarProjectsQuery.Data.Projects.Node.Image(
        id: "1",
        url: imageURL!
      ) : nil,
      pid: id,
      name: name,
      state: wrappedState,
      isLaunched: isLaunched,
      deadlineAt: deadlineAt,
      percentFunded: percentFunded,
      prelaunchActivated: prelaunchActivated,
      launchedAt: launchedAt,
      isInPostCampaignPledgingPhase: isInPostCampaignPledgingPhase,
      postCampaignPledgingEnabled: isPostCampaignPledgingEnabled,
      url: url,
      isWatched: false,
      goal: goal.isSome ? GraphAPI.FetchSimilarProjectsQuery.Data.Projects.Node.Goal(
        amount: String(goal!),
        currency: .case(GraphAPI.CurrencyCode.usd),
        symbol: "$"
      ) : nil,
      pledged: GraphAPI.FetchSimilarProjectsQuery.Data.Projects.Node.Pledged(
        amount: String(pledged),
        currency: GraphQLEnum.case(GraphAPI.CurrencyCode.usd),
        symbol: "$"
      ),
      backersCount: backersCount,
      commentsCount: 0,
      country: GraphAPI.FetchSimilarProjectsQuery.Data.Projects.Node.Country(
        code: .case(GraphAPI.CountryCode(rawValue: countryCode)!),
        name: countryName
      ),
      currency: .case(GraphAPI.CurrencyCode(rawValue: currency)!),
      isPrelaunchActivated: prelaunchActivated,
      projectTags: [],
      fxRate: Double(fxRate),
      posts: FetchSimilarProjectsQuery.Data.Projects.Node.Posts(totalCount: 0),
      projectDescription: description,
      stateChangedAt: stateChangedAt,
      projectUsdExchangeRate: Double(projectUsdExchangeRate)
    )
  }
}
