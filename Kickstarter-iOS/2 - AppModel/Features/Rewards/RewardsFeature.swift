import Experimentation
import Foundation
import KsApi

/// A substitution boundary for the shipping-sorted rewards API.
@MainActor
public protocol RewardsProvider {
  func fetchAddOns(slug: String, locationID: String?) async throws -> [Reward]?
  func fetchFastAddOns(baseRewardID: Int, country: String) async throws -> [Reward]
  func fetchShippingLocations(projectID: Int) async throws -> [Location]
  func fetchProjectRewards(projectID: Int, country: String?, inserter: any NoRewardInserter) async throws
    -> [Reward]
}

@MainActor
public struct AsyncRewardsProvider: RewardsProvider {
  private let service: any ServiceType
  public init(service: any ServiceType) { self.service = service }
  public func fetchAddOns(slug: String, locationID: String?) async throws -> [Reward]? {
    try await self.service.rewardAddOns(slug: slug, locationID: locationID)
  }
  public func fetchFastAddOns(baseRewardID: Int, country: String) async throws -> [Reward] {
    try await self.service.fastRewardAddOns(baseRewardID: baseRewardID, country: country)
  }
  public func fetchShippingLocations(projectID: Int) async throws -> [Location] {
    try await self.service.shippingLocations(projectID: projectID)
  }

  public func fetchProjectRewards(
    projectID: Int,
    country: String?,
    inserter: any NoRewardInserter
  ) async throws -> [Reward] {
    try await self.service.sortedProjectRewards(
      projectID: projectID, country: country, inserter: inserter)
  }
}

/// Owns shipping-sorted reward loading and visibility/insertion policy.
/// The API returns one complete list, not cursor pages. Each screen has an
/// independent route; a changed country supersedes that route's previous read.
@MainActor
public final class RewardsFeature {
  public struct Analytics {
    let rewardsViewed: @MainActor (Project, KSRAnalytics.CheckoutPropertiesData, RefTag?) -> Void
    let rewardClicked: @MainActor (Project, Reward, KSRAnalytics.CheckoutPropertiesData, RefTag?) -> Void
    let addOnsPageViewed: @MainActor (Project, Reward, KSRAnalytics.CheckoutPropertiesData, RefTag?) -> Void
    let addOnsContinue: @MainActor (Project, Reward, KSRAnalytics.CheckoutPropertiesData, RefTag?) -> Void

    public init(
      rewardsViewed: @escaping @MainActor (Project, KSRAnalytics.CheckoutPropertiesData, RefTag?) -> Void = { _, _, _ in },
      rewardClicked: @escaping @MainActor (Project, Reward, KSRAnalytics.CheckoutPropertiesData, RefTag?) -> Void = { _, _, _, _ in },
      addOnsPageViewed: @escaping @MainActor (Project, Reward, KSRAnalytics.CheckoutPropertiesData, RefTag?) -> Void = { _, _, _, _ in },
      addOnsContinue: @escaping @MainActor (Project, Reward, KSRAnalytics.CheckoutPropertiesData, RefTag?) -> Void = { _, _, _, _ in }
    ) {
      self.rewardsViewed = rewardsViewed
      self.rewardClicked = rewardClicked
      self.addOnsPageViewed = addOnsPageViewed
      self.addOnsContinue = addOnsContinue
    }
  }

  public struct Platform {
    let configuredCountry: @MainActor () -> String?
    let country: @MainActor () -> String
    let now: @MainActor () -> TimeInterval
    let recordThirdPartyEvent: @MainActor (KsApi.TriggerThirdPartyEventInput) -> Void

    public init(
      configuredCountry: @escaping @MainActor () -> String?,
      country: @escaping @MainActor () -> String,
      now: @escaping @MainActor () -> TimeInterval,
      recordThirdPartyEvent: @escaping @MainActor (KsApi.TriggerThirdPartyEventInput) -> Void
    ) {
      self.configuredCountry = configuredCountry
      self.country = country
      self.now = now
      self.recordThirdPartyEvent = recordThirdPartyEvent
    }
  }

  public func recordThirdPartyEvent(_ input: KsApi.TriggerThirdPartyEventInput) {
    self.platform.recordThirdPartyEvent(input)
  }
  public struct ShippingSnapshot {
    public fileprivate(set) var locations: [Location] = []
    public fileprivate(set) var selectedLocation: Location?
    public fileprivate(set) var isLoading = false
    public fileprivate(set) var error: ErrorEnvelope?
    public fileprivate(set) var hasResult = false
  }

  private struct ShippingIdentity: Equatable {
    let projectID: Int
    let selectedLocationID: Int?
    let hasShippableRewards: Bool
  }

  private struct ReadSession: Equatable {
    let userID: Int?
    let generation: Int

    @MainActor
    func isCurrent(in session: SessionFeature) -> Bool {
      session.isCurrent(userID: self.userID, generation: self.generation)
    }
  }

  private var readSession: ReadSession {
    ReadSession(userID: self.sessionFeature.currentUser?.id, generation: self.sessionFeature.generation)
  }

  private final class ShippingRoute {
    let session: ReadSession
    var snapshot = ShippingSnapshot()
    var activeLoad: (id: UUID, identity: ShippingIdentity, task: Task<Void, Never>)?

    init(session: ReadSession) { self.session = session }
  }

  private var shippingSelectionByRoute: [UUID: ShippingRoute] = [:]
  public func shippingSnapshot(for route: UUID) -> ShippingSnapshot {
    guard let entry = self.shippingSelectionByRoute[route], entry.session == self.readSession else {
      return ShippingSnapshot()
    }
    return entry.snapshot
  }

  public func loadShippingLocations(
    route: UUID, projectID: Int, selectedLocationID: Int?, hasShippableRewards: Bool
  ) async {
    guard !Task.isCancelled else { return }
    await self.startShippingLocationLoad(
      route: route, projectID: projectID, selectedLocationID: selectedLocationID,
      hasShippableRewards: hasShippableRewards
    ).value
  }

  /// A selector owns its route. Equivalent reads share execution; reconfiguration
  /// replaces only that selector's request, just as the former switchMap did.
  @discardableResult
  public func startShippingLocationLoad(
    route: UUID, projectID: Int, selectedLocationID: Int?, hasShippableRewards: Bool
  ) -> Task<Void, Never> {
    let identity = ShippingIdentity(
      projectID: projectID, selectedLocationID: selectedLocationID,
      hasShippableRewards: hasShippableRewards
    )
    let session = self.readSession
    let previous = self.shippingSelectionByRoute[route]
    if let previous, previous.session == session,
       let request = previous.activeLoad, request.identity == identity { return request.task }
    previous?.activeLoad?.task.cancel()
    let entry = previous.flatMap { $0.session == session ? $0 : nil } ?? ShippingRoute(session: session)
    self.shippingSelectionByRoute[route] = entry
    let requestID = UUID()
    let provider = self.makeProvider()
    let sessionFeature = self.sessionFeature
    entry.snapshot.isLoading = true
    entry.snapshot.error = nil
    entry.snapshot.hasResult = false
    let task = Task { [weak self] in
      defer {
        if self != nil, entry.activeLoad?.id == requestID {
          entry.activeLoad = nil
          entry.snapshot.isLoading = false
        }
      }
      do {
        try Task.checkCancellation()
        guard session.isCurrent(in: sessionFeature) else {
          throw CancellationError()
        }
        let locations =
          hasShippableRewards ? try await provider.fetchShippingLocations(projectID: projectID) : []
        try Task.checkCancellation()
        guard session.isCurrent(in: sessionFeature),
          let self, self.shippingSelectionByRoute[route]?.activeLoad?.id == requestID
        else { return }
        entry.snapshot.hasResult = true
        entry.snapshot.locations = locations
        entry.snapshot.selectedLocation =
          locations.first { $0.id == selectedLocationID }
          ?? defaultShippingLocation(fromLocations: locations, configuredCountry: self.platform.configuredCountry())
      } catch is CancellationError {
        // Obsolete reads do not notify the delegate or display an error.
      } catch {
        guard !Task.isCancelled, session.isCurrent(in: sessionFeature),
          let self, self.shippingSelectionByRoute[route]?.activeLoad?.id == requestID
        else { return }
        let failure = (error as? ErrorEnvelope) ?? ErrorEnvelope.couldNotParseJSON
        entry.snapshot.error = failure
        entry.snapshot.hasResult = true
      }
    }
    entry.activeLoad = (requestID, identity, task)
    return task
  }

  public func selectShippingLocation(_ location: Location, route: UUID) {
    guard let entry = self.shippingSelectionByRoute[route], entry.session == self.readSession else { return }
    entry.snapshot.selectedLocation = location
  }

  public func releaseShippingLocations(route: UUID) {
    guard let entry = self.shippingSelectionByRoute.removeValue(forKey: route) else { return }
    let task = entry.activeLoad?.task
    entry.activeLoad = nil
    task?.cancel()
  }

  public struct Snapshot {
    public fileprivate(set) var rewards: [Reward] = []
    public fileprivate(set) var isLoading = false
    public fileprivate(set) var error: ErrorEnvelope?
    public fileprivate(set) var hasResult = false
  }

  private struct Identity: Equatable {
    let projectID: Int
    let country: String?
    let locationID: Int?
    let moveNoReward: Bool
    let state: Project.State
    let postCampaign: Bool
    let creatorID: Int
    let backedRewardID: Int?
  }

  private final class Route {
    let session: ReadSession
    var snapshot = Snapshot()
    var activeLoad: (id: UUID, identity: Identity, task: Task<Void, Never>)?

    init(session: ReadSession) { self.session = session }
  }

  private var rewardCollectionByRoute: [UUID: Route] = [:]
  public let sessionFeature: SessionFeature
  private let makeProvider: @MainActor () -> any RewardsProvider
  private let platform: Platform
  private let fastCheckout: @MainActor () -> Bool
  private let moveNoReward: @MainActor () -> Bool
  private let applePayEligibility: @MainActor (Project) -> Bool
  private let analytics: Analytics
  private let rewardSelectionContext: @MainActor () -> (advertisingID: String, platformVersion: String)?

  public init(
    platform: Platform,
    sessionFeature: SessionFeature,
    makeProvider: @escaping @MainActor () -> any RewardsProvider,
    fastCheckout: @escaping @MainActor () -> Bool = {
      SpeedyCheckoutExperiment().boolValue(forKey: .speedy_checkout_enabled) == true
    },
    moveNoReward: @escaping @MainActor () -> Bool = {
      MoveNoRewardOptionExperiment().boolValue(forKey: .show_no_reward_after_available_rewards)
        == true
    },
    hasEligibleApplePayCard: @escaping @MainActor (Project) -> Bool = { _ in false },
    analytics: Analytics = Analytics(),
    rewardSelectionContext: @escaping @MainActor () -> (advertisingID: String, platformVersion: String)? = { nil }
  ) {
    self.sessionFeature = sessionFeature
    self.makeProvider = makeProvider
    self.platform = platform
    self.fastCheckout = fastCheckout
    self.moveNoReward = moveNoReward
    self.applePayEligibility = hasEligibleApplePayCard
    self.analytics = analytics
    self.rewardSelectionContext = rewardSelectionContext
  }

  public func hasEligibleApplePayCard(for project: Project) -> Bool {
    self.applePayEligibility(project)
  }

  public func trackRewardsViewed(
    project: Project, checkout: KSRAnalytics.CheckoutPropertiesData, refTag: RefTag?
  ) {
    self.analytics.rewardsViewed(project, checkout, refTag)
  }

  public func trackRewardClicked(
    project: Project, reward: Reward, checkout: KSRAnalytics.CheckoutPropertiesData, refTag: RefTag?
  ) {
    self.analytics.rewardClicked(project, reward, checkout, refTag)
  }

  public func trackAddOnsPageViewed(
    project: Project, reward: Reward, checkout: KSRAnalytics.CheckoutPropertiesData, refTag: RefTag?
  ) {
    self.analytics.addOnsPageViewed(project, reward, checkout, refTag)
  }

  public func trackAddOnsContinue(
    project: Project, reward: Reward, checkout: KSRAnalytics.CheckoutPropertiesData, refTag: RefTag?
  ) {
    self.analytics.addOnsContinue(project, reward, checkout, refTag)
  }

  public func recordRewardSelectionViewed(project: Project) {
    guard let context = self.rewardSelectionContext() else { return }
    var extInfo = Array(repeating: "", count: 16)
    extInfo[0] = "i2"
    extInfo[4] = context.platformVersion
    self.recordThirdPartyEvent(.init(
      deviceId: context.advertisingID,
      eventName: ThirdPartyEventInputName.RewardSelectionViewed.rawValue,
      projectId: String(project.id),
      pledgeAmount: nil,
      shipping: nil,
      transactionId: nil,
      userId: self.sessionFeature.currentUser.map { String($0.id) } ?? "",
      appData: .init(
        advertiserTrackingEnabled: true,
        applicationTrackingEnabled: true,
        extinfo: extInfo
      ),
      clientMutationId: ""
    ))
  }

  public func snapshot(for route: UUID) -> Snapshot {
    guard let entry = self.rewardCollectionByRoute[route], entry.session == self.readSession else { return Snapshot() }
    return entry.snapshot
  }

  public func loadProjectRewards(route: UUID, project: Project, location: Location?) async {
    guard !Task.isCancelled else { return }
    await self.startProjectRewardsLoad(route: route, project: project, location: location).value
  }

  @discardableResult
  public func startProjectRewardsLoad(route: UUID, project: Project, location: Location?) -> Task<Void, Never> {
    let identity = Identity(
      projectID: project.id, country: location?.country, locationID: location?.id,
      moveNoReward: self.moveNoReward(),
      state: project.state, postCampaign: project.isInPostCampaignPledgingPhase,
      creatorID: project.creator.id, backedRewardID: project.personalization.backing?.rewardId
    )
    let session = self.readSession
    let previous = self.rewardCollectionByRoute[route]
    if let previous, previous.session == session,
       let request = previous.activeLoad, request.identity == identity { return request.task }
    previous?.activeLoad?.task.cancel()
    let entry = previous.flatMap { $0.session == session ? $0 : nil } ?? Route(session: session)
    self.rewardCollectionByRoute[route] = entry
    let requestID = UUID()
    let provider = self.makeProvider()
    let sessionFeature = self.sessionFeature
    let inserter: any NoRewardInserter =
      identity.moveNoReward
      ? NoRewardAfterLastAvailableReward(
        shippingLocation: location,
        project: project,
        currentUser: self.sessionFeature.currentUser
      )
      : NoRewardFirst()
    entry.snapshot.isLoading = true
    entry.snapshot.error = nil
    entry.snapshot.hasResult = false
    let task = Task { [weak self] in
      defer {
        if entry.activeLoad?.id == requestID {
          entry.activeLoad = nil
          entry.snapshot.isLoading = false
        }
      }
      do {
        try Task.checkCancellation()
        guard session.isCurrent(in: sessionFeature) else {
          throw CancellationError()
        }
        let rewards = try await provider.fetchProjectRewards(
          projectID: project.id,
          country: location?.country,
          inserter: inserter
        )
        try Task.checkCancellation()
        guard session.isCurrent(in: sessionFeature),
          let self, self.rewardCollectionByRoute[route]?.activeLoad?.id == requestID
        else { return }
        let now = self.platform.now()
        let visibleRewards = rewards.filter { isStartDateBeforeToday(for: $0, now: now) }
        entry.snapshot.rewards = visibleRewards
        entry.snapshot.hasResult = true
      } catch is CancellationError {
        // Superseded reads do not produce product errors or empty success.
      } catch {
        guard !Task.isCancelled, session.isCurrent(in: sessionFeature),
          let self, self.rewardCollectionByRoute[route]?.activeLoad?.id == requestID
        else { return }
        entry.snapshot.error = (error as? ErrorEnvelope) ?? ErrorEnvelope.couldNotParseJSON
      }
    }
    entry.activeLoad = (requestID, identity, task)
    return task
  }

  public func cancelProjectRewardsLoad(route: UUID) {
    guard let entry = self.rewardCollectionByRoute[route] else { return }
    let task = entry.activeLoad?.task
    entry.activeLoad = nil
    entry.snapshot.isLoading = false
    task?.cancel()
  }

  public func release(route: UUID) {
    self.cancelProjectRewardsLoad(route: route)
    self.rewardCollectionByRoute.removeValue(forKey: route)
  }

  private enum AddOnsQuery: Equatable {
    case none
    case standard(String, String?)
    case fast(Int, String)
  }
  private struct AddOnsIdentity: Equatable {
    let query: AddOnsQuery
    let userID: Int?
    let generation: Int
  }
  private struct AddOnsRequest {
    let id: UUID
    let identity: AddOnsIdentity
    let task: Task<[Reward]?, Error>
  }
  private var addOnsRequests: [UUID: AddOnsRequest] = [:]
  private var addOnsVersions: [UUID: UUID] = [:]
  private var addOnsTasks: [UUID: Task<[Reward]?, Error>] = [:]
  private var addOnsObservers: [UUID: Task<Void, Never>] = [:]

  private func requireCurrentAddOns(_ identity: AddOnsIdentity, route: UUID, version: UUID) throws {
    try Task.checkCancellation()
    guard self.addOnsVersions[route] == version,
      self.sessionFeature.isCurrent(userID: identity.userID, generation: identity.generation)
    else { throw CancellationError() }
  }

  private func startAddOnsFetch(
    route: UUID, slug: String, baseReward: Reward?, shippingRule: ShippingRule?
  ) -> AddOnsRequest {
    let query: AddOnsQuery
    if let baseReward, !baseReward.isNoReward, baseReward.hasAddOns {
      if self.fastCheckout() {
        query = .fast(
          baseReward.id, shippingRule?.location.country ?? self.platform.country())
      } else {
        query = .standard(slug, shippingRule?.location.graphID)
      }
    } else {
      query = .none
    }
    let identity = AddOnsIdentity(
      query: query, userID: self.sessionFeature.currentUser?.id,
      generation: self.sessionFeature.generation)
    if let pending = self.addOnsRequests[route], pending.identity == identity { return pending }
    self.addOnsRequests[route]?.task.cancel()
    let id = UUID()
    self.addOnsVersions[route] = id
    let provider = self.makeProvider()
    let task = Task { [self] () throws -> [Reward]? in
      defer {
        self.addOnsTasks[id] = nil
        if self.addOnsRequests[route]?.id == id { self.addOnsRequests[route] = nil }
      }
      try self.requireCurrentAddOns(identity, route: route, version: id)
      do {
        let rewards: [Reward]?
        switch query {
        case .none: rewards = nil
        case .standard(let slug, let location):
          rewards = try await provider.fetchAddOns(slug: slug, locationID: location)
        case .fast(let rewardID, let country):
          rewards = try await provider.fetchFastAddOns(baseRewardID: rewardID, country: country)
        }
        try self.requireCurrentAddOns(identity, route: route, version: id)
        return rewards
      } catch {
        try self.requireCurrentAddOns(identity, route: route, version: id)
        throw error
      }
    }
    let request = AddOnsRequest(id: id, identity: identity, task: task)
    self.addOnsRequests[route] = request
    self.addOnsTasks[id] = task
    return request
  }

  public func loadAddOns(route: UUID, slug: String, baseReward: Reward?, shippingRule: ShippingRule?)
    async throws -> [Reward]?
  {
    try Task.checkCancellation()
    let request = self.startAddOnsFetch(
      route: route, slug: slug, baseReward: baseReward, shippingRule: shippingRule)
    do {
      let value = try await request.task.value
      try self.requireCurrentAddOns(request.identity, route: route, version: request.id)
      return value
    } catch {
      try self.requireCurrentAddOns(request.identity, route: route, version: request.id)
      throw error
    }
  }

  /// Admits the request immediately and owns its delivery until completion or cancellation.
  public func startAddOnsLoad(
    route: UUID, slug: String, baseReward: Reward?, shippingRule: ShippingRule?,
    completion: @escaping @MainActor (Result<[Reward]?, Error>) -> Void
  ) -> Task<Void, Never> {
    let request = self.startAddOnsFetch(
      route: route, slug: slug, baseReward: baseReward, shippingRule: shippingRule
    )
    let id = UUID()
    let task = Task { @MainActor [self] in
      defer { self.addOnsObservers[id] = nil }
      do {
        let value = try await request.task.value
        try self.requireCurrentAddOns(request.identity, route: route, version: request.id)
        completion(.success(value))
      } catch {
        guard !Task.isCancelled, !(error is CancellationError),
              self.addOnsVersions[route] == request.id,
              self.sessionFeature.isCurrent(userID: request.identity.userID, generation: request.identity.generation)
        else { return }
        completion(.failure(error))
      }
    }
    self.addOnsObservers[id] = task
    return task
  }

  public func releaseAddOns(route: UUID) {
    self.addOnsVersions[route] = nil
    self.addOnsRequests.removeValue(forKey: route)?.task.cancel()
  }
  public func waitForAddOnOperations() async {
    while !self.addOnsTasks.isEmpty || !self.addOnsObservers.isEmpty {
      for task in Array(self.addOnsTasks.values) { _ = await task.result }
      for task in Array(self.addOnsObservers.values) { await task.value }
    }
  }

  nonisolated public static func availableAddOns(
    _ addOns: [Reward], project: Project, baseReward: Reward, shippingRule: ShippingRule?
  ) -> [Reward] {
    filteredAddOns(
      addOns.filter { addOnIsAvailable($0, in: project) },
      filteredBy: shippingRule, baseReward: baseReward)
  }

}

private func addOnIsAvailable(_ addOn: Reward, in project: Project) -> Bool {
  // If the user is backing this addOn, it's available for editing
  if let backedAddOns = project.personalization.backing?.addOns,
    backedAddOns.map(\.id).contains(addOn.id)
  {
    return true
  }

  return addOn.isAvailable ?? false
}

private func filteredAddOns(
  _ addOns: [Reward],
  filteredBy shippingRule: ShippingRule?,
  baseReward: Reward
) -> [Reward] {
  let isBaseRewardDigital = isRewardDigital(baseReward)
  let isBaseRewardLocalPickup = isRewardLocalPickup(baseReward)

  return addOns.filter { addOn in
    var isValidAddonToDisplay = false
    let isAddOnDigital = isRewardDigital(addOn)
    let isAddOnLocalPickup = isRewardLocalPickup(addOn)
    let isAddOnLocalOrDigital = isAddOnDigital || isAddOnLocalPickup
    // For digital-only base rewards only return add-ons that are also digital-only.
    if isBaseRewardDigital, isAddOnDigital {
      isValidAddonToDisplay = true
    } else if isBaseRewardLocalPickup, isAddOnLocalOrDigital {
      isValidAddonToDisplay = true  // return all addons that are digital for local base reward

      if isAddOnLocalPickup {
        if let addOnLocationId = addOn.localPickup?.id,
          let baseRewardLocationId = baseReward.localPickup?.id,
          addOnLocationId == baseRewardLocationId
        {
          // if add on is local for local base, ensure locations are equal before displaying
          isValidAddonToDisplay = true
        } else {
          isValidAddonToDisplay = false
        }
      }
    } else if !isBaseRewardDigital, !isBaseRewardLocalPickup {
      /**
       For restricted or unrestricted shipping base rewards, unrestricted shipping
       or digital-only add-ons are available.
       */
      isValidAddonToDisplay =
        isAddOnDigital || addOnShipsToLocation(addOn, shipsTo: shippingRule?.location.id)
    }

    return isValidAddonToDisplay
  }
}

/// For base rewards that have restricted or unrestricted shipping, only return
/// add-ons that can ship to the selected shipping location.
private func addOnShipsToLocation(
  _ addOn: Reward,
  shipsTo locationId: Int?
) -> Bool {
  guard let selectedLocationId = locationId else { return false }

  let addOnShippingLocationIds: Set<Int> = Set(
    addOn.shippingRulesExpanded?.map(\.location).map(\.id) ?? []
  )

  return addOnShippingLocationIds.contains(selectedLocationId)
}
