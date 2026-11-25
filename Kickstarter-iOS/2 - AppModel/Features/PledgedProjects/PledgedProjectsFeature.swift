import Combine
import Foundation
import GraphAPI
import KsApi

@MainActor
public protocol PledgedProjectsProvider {
  func fetchPledgedProjectsPage(tiers: [PledgeProjectsOverviewSort], cursor: String?, limit: Int) async throws
    -> PledgedProjectsResponse
}

@MainActor
public struct AsyncPledgedProjectsProvider: PledgedProjectsProvider {
  private let service: any ServiceType
  public init(service: any ServiceType) { self.service = service }
  public func fetchPledgedProjectsPage(tiers: [PledgeProjectsOverviewSort], cursor: String?, limit: Int) async throws
    -> PledgedProjectsResponse
  {
    try await self.service.pledgedProjects(tiers: tiers, cursor: cursor, limit: limit)
  }
}

/// Owns overview requests, pagination and account isolation. Combine carries snapshots only.
@MainActor
public final class PledgedProjectsFeature {
  public typealias Snapshot = PaginationResult<PPOProjectCardModel, String, ErrorEnvelope>
  public struct Analytics {
    public enum CardEvent: Equatable {
      case authenticateCard
      case confirmAddress
      case editAddress
      case fixPayment
      case manageLivePledge
      case openPledgeManager
      case sendMessage
      case updateRewardReceived(Bool)
      case viewProjectDetails
      case completeSurvey
    }

    let dashboardOpened: @MainActor (KSRAnalytics.PledgedProjectOverviewProperties) -> Void
    let cardEvent: @MainActor (
      CardEvent,
      ProjectAnalyticsSnapshot,
      KSRAnalytics.PledgedProjectOverviewProperties
    ) -> Void
    let addressConfirmed: @MainActor (
      ProjectAnalyticsSnapshot,
      KSRAnalytics.PledgedProjectOverviewProperties
    ) -> Void

    public init(
      dashboardOpened: @escaping @MainActor (
        KSRAnalytics.PledgedProjectOverviewProperties
      ) -> Void = { _ in },
      cardEvent: @escaping @MainActor (
        CardEvent,
        ProjectAnalyticsSnapshot,
        KSRAnalytics.PledgedProjectOverviewProperties
      ) -> Void = { _, _, _ in },
      addressConfirmed: @escaping @MainActor (
        ProjectAnalyticsSnapshot,
        KSRAnalytics.PledgedProjectOverviewProperties
      ) -> Void = { _, _ in }
    ) {
      self.dashboardOpened = dashboardOpened
      self.cardEvent = cardEvent
      self.addressConfirmed = addressConfirmed
    }
  }

  public enum OverviewVersion: Equatable {
    case projectAlerts
    case fundedProjects
    case allBackings
  }

  private let sessionFeature: SessionFeature
  private let settingsFeature: SettingsFeature
  private let makeProvider: () -> any PledgedProjectsProvider
  private let locale: () -> Locale
  private let analytics: Analytics

  public init(
    sessionFeature: SessionFeature,
    settingsFeature: SettingsFeature,
    makeProvider: @escaping () -> any PledgedProjectsProvider,
    locale: @escaping () -> Locale,
    analytics: Analytics = Analytics()
  ) {
    self.sessionFeature = sessionFeature
    self.settingsFeature = settingsFeature
    self.makeProvider = makeProvider
    self.locale = locale
    self.analytics = analytics
  }

  public func trackDashboardOpened(
    properties: KSRAnalytics.PledgedProjectOverviewProperties
  ) {
    self.analytics.dashboardOpened(properties)
  }

  public func trackCardEvent(
    _ event: Analytics.CardEvent,
    project: ProjectAnalyticsSnapshot,
    properties: KSRAnalytics.PledgedProjectOverviewProperties
  ) {
    self.analytics.cardEvent(event, project, properties)
  }

  public func trackAddressConfirmed(
    project: ProjectAnalyticsSnapshot,
    properties: KSRAnalytics.PledgedProjectOverviewProperties
  ) {
    self.analytics.addressConfirmed(project, properties)
  }

  public var overviewVersion: OverviewVersion {
    if self.settingsFeature.isRemoteConfigurationEnabled(.pledgedProjectsOverviewV4Enabled) {
      return .allBackings
    }
    if self.isOverviewV2Enabled { return .fundedProjects }
    return .projectAlerts
  }

  public var isOverviewV2Enabled: Bool {
    self.settingsFeature.isRemoteConfigurationEnabled(.pledgedProjectsOverviewV2Enabled)
  }

  public var enabledTiers: [PledgeProjectsOverviewSort] {
    switch self.overviewVersion {
    case .allBackings: return PPOTierType.allGraphQLTypes()
    case .fundedProjects: return PPOTierType.fundedProjectGraphQLTypes()
    case .projectAlerts: return PPOTierType.projectAlertGraphQLTypes()
    }
  }

  private struct Session: Equatable {
    let userID: Int?
    let generation: Int
  }
  private var session: Session {
    Session(userID: self.sessionFeature.currentUser?.id, generation: self.sessionFeature.generation)
  }
  private struct Pending {
    let id: UUID
    let cursor: String?
    let tiers: [PledgeProjectsOverviewSort]
    let session: Session
    let task: Task<Void, Never>
  }
  private final class Route {
    let snapshots = CurrentValueSubject<Snapshot, Never>(.unloaded)
    var pending: Pending?
    var session: Session?
    var tiers: [PledgeProjectsOverviewSort] = []
  }
  private var routes: [UUID: Route] = [:]
  private var pageLoadTasks: [UUID: Task<Void, Never>] = [:]

  private func route(_ id: UUID) -> Route {
    if let route = self.routes[id] { return route }
    let route = Route()
    self.routes[id] = route
    return route
  }
  public func snapshots(route: UUID) -> AnyPublisher<Snapshot, Never> {
    self.route(route).snapshots.eraseToAnyPublisher()
  }

  @discardableResult
  public func startFirstPledgedProjectsPageLoad(route: UUID) -> Task<Void, Never> {
    self.startPledgedProjectsPageLoad(route: route, cursor: nil)
  }
  public func refreshPledgedProjects(route: UUID) async {
    guard !Task.isCancelled else { return }
    await self.startFirstPledgedProjectsPageLoad(route: route).value
  }
  public func loadNextPledgedProjectsPage(route id: UUID) async {
    guard !Task.isCancelled else { return }
    let route = self.route(id)
    if route.session != self.session || route.tiers != self.enabledTiers {
      await self.refreshPledgedProjects(route: id)
    } else if let pending = route.pending {
      await pending.task.value
    } else if let cursor = route.snapshots.value.cursor {
      await self.startPledgedProjectsPageLoad(route: id, cursor: cursor).value
    }
    // A terminal page is already complete; it must never wait for another publication.
  }

  private func startPledgedProjectsPageLoad(route id: UUID, cursor: String?) -> Task<Void, Never> {
    let route = self.route(id)
    let session = self.session
    let tiers = self.enabledTiers
    if let pending = route.pending, pending.cursor == cursor, pending.session == session,
      pending.tiers == tiers
    {
      return pending.task
    }
    route.pending?.task.cancel()
    let previous: Snapshot
    if route.session != session {
      previous = .unloaded
    } else if case .loading(let loaded) = route.snapshots.value {
      previous = loaded
    } else {
      previous = route.snapshots.value
    }
    let provider = self.makeProvider()
    let locale = self.locale()
    let requestID = UUID()
    let task = Task { [self] in
      defer {
        self.pageLoadTasks[requestID] = nil
        if route.pending?.id == requestID { route.pending = nil }
      }
      do {
        try Task.checkCancellation()
        let data = try await provider.fetchPledgedProjectsPage(tiers: tiers, cursor: cursor, limit: 10)
        try Task.checkCancellation()
        guard route.pending?.id == requestID, self.session == session else { return }
        let newCards = data.cards.compactMap {
          PPOProjectCardModel(
            card: $0,
            showRewardReceivedToggle: self.isOverviewV2Enabled,
            locale: locale
          )
        }
        let cards = (cursor == nil ? [] : previous.values) + newCards
        let page =
          newCards.isEmpty
          ? (cursor == nil ? nil : previous.page) : (cursor == nil ? 1 : (previous.page ?? 0) + 1)
        let snapshot: Snapshot
        if cards.isEmpty {
          snapshot = .empty
        } else if let next = data.cursor, !newCards.isEmpty {
          snapshot = .someLoaded(
            values: cards, cursor: next, total: data.total, page: page)
        } else {
          snapshot = .allLoaded(values: cards, page: page)
        }
        route.snapshots.send(snapshot)
      } catch {
        guard !Task.isCancelled, !(error is CancellationError), route.pending?.id == requestID,
          self.session == session
        else { return }
        route.snapshots.send(.error((error as? ErrorEnvelope) ?? .couldNotParseJSON))
      }
    }
    route.session = session
    route.tiers = tiers
    route.pending = Pending(
      id: requestID, cursor: cursor, tiers: tiers, session: session, task: task)
    self.pageLoadTasks[requestID] = task
    route.snapshots.send(.loading(previous: previous))
    return task
  }
  public func release(route: UUID) {
    self.routes.removeValue(forKey: route)?.pending?.task.cancel()
  }
  public func resetForSessionChange() {
    for route in self.routes.values {
      route.pending?.task.cancel()
      route.pending = nil
      route.session = nil
      route.snapshots.send(.unloaded)
    }
  }
  public func waitForOperations() async {
    while !self.pageLoadTasks.isEmpty {
      for task in Array(self.pageLoadTasks.values) { await task.value }
    }
  }
}
