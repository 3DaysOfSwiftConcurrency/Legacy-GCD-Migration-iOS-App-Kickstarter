import Foundation
import KsApi
import Observation
import Prelude

@MainActor @Observable
public final class FindFriendsViewModel {
  public enum Event {
    case followAllConfirmation(Int)
    case error(AlertError)
    case discovery(DiscoveryParams)
  }
  public private(set) var source: FriendsSource = .findFriends
  public private(set) var friends: [User]?
  public private(set) var stats: FriendStatsEnvelope?
  public private(set) var showFacebookConnect: Bool?
  public private(set) var showLoadingIndicator = false
  @ObservationIgnored var onChange: (@MainActor () -> Void)?
  @ObservationIgnored var onEvent: (@MainActor (Event) -> Void)?
  @ObservationIgnored private let friendsFeature: FriendsFeature
  @ObservationIgnored private let refreshDelay: @MainActor () async throws -> Void
  @ObservationIgnored private let route = UUID()
  @ObservationIgnored private var pageObservation: Task<Void, Never>?
  @ObservationIgnored private var statisticsObservation: Task<Void, Never>?
  @ObservationIgnored private var followAllObservation: Task<Void, Never>?
  private var appeared = false
  private var lastPaginationTrigger = false
  private var showedInitialLoader = false

  public init(friendsFeature: FriendsFeature, refreshDelay: (@MainActor () async throws -> Void)? = nil) {
    self.friendsFeature = friendsFeature
    self.refreshDelay = refreshDelay ?? { try await Task.sleep(for: .seconds(2)) }
  }

  public func configureWith(source: FriendsSource) {
    self.source = source
    if self.appeared { self.onChange?() }
  }

  public func viewDidLoad() {
    self.appeared = true
    self.updateFacebookState()
  }

  public func findFriendsFacebookConnectCellDidFacebookConnectUser() { self.updateFacebookState() }
  public func findFriendsFacebookConnectCellDidDismissHeader() {}
  public func findFriendsFacebookConnectCellShowErrorAlert(_ alert: AlertError) { self.onEvent?(.error(alert)) }
  public func findFriendsStatsCellShowFollowAllFriendsAlert(friendCount: Int) { self.onEvent?(.followAllConfirmation(friendCount)) }
  public func updateFriend(_ updatedFriend: User) {}
  public func discoverButtonTapped() {
    self.onEvent?(.discovery(DiscoveryParams.defaults |> DiscoveryParams.lens.social .~ true |> DiscoveryParams.lens.sort .~ .magic))
  }

  private func updateFacebookState() {
    let show = FindFriendsFacebookConnectCellViewModel.showFacebookConnectionSection(
      for: self.friendsFeature.sessionFeature.currentUser
    )
    self.showFacebookConnect = show
    self.onChange?()
    if !show { self.loadPage(); self.loadStatistics() }
  }

  private func loadPage(next: Bool = false) {
    guard let task = self.friendsFeature.requestFriendsPage(route: self.route, next: next) else { return }
    let friendsFeature = self.friendsFeature, route = self.route
    let generation = friendsFeature.sessionFeature.generation
    let userID = friendsFeature.sessionFeature.currentUser?.id
    if !next, self.friends != nil { self.friends = []; self.onChange?() }
    if !self.showedInitialLoader {
      self.showedInitialLoader = true
      self.showLoadingIndicator = true
      self.onChange?()
    }
    self.pageObservation?.cancel()
    self.pageObservation = Task { [weak self] in
      await task.value
      guard let self, !Task.isCancelled, friendsFeature.sessionFeature.isCurrent(userID: userID, generation: generation) else { return }
      let snapshot = friendsFeature.snapshot(route: route)
      if snapshot.pageError == nil { self.friends = snapshot.users }
      self.showLoadingIndicator = false
      self.onChange?()
    }
  }

  private func loadStatistics() {
    let friendsFeature = self.friendsFeature, route = self.route
    let generation = friendsFeature.sessionFeature.generation
    let userID = friendsFeature.sessionFeature.currentUser?.id
    let task = friendsFeature.requestFriendStatistics(route: route)
    self.statisticsObservation?.cancel()
    self.statisticsObservation = Task { [weak self] in
      await task.value
      guard let self, !Task.isCancelled, friendsFeature.sessionFeature.isCurrent(userID: userID, generation: generation),
            self.showFacebookConnect == false else { return }
      if let stats = friendsFeature.snapshot(route: route).statistics { self.stats = stats; self.onChange?() }
    }
  }

  public func willDisplayRow(_ row: Int, outOf totalRows: Int) {
    let trigger = row >= totalRows - 3 && totalRows > 1
    guard trigger != self.lastPaginationTrigger else { return }
    self.lastPaginationTrigger = trigger
    if trigger { self.loadPage(next: true) }
  }

  public func confirmFollowAllFriends() {
    let friendsFeature = self.friendsFeature
    let generation = friendsFeature.sessionFeature.generation
    let userID = friendsFeature.sessionFeature.currentUser?.id
    let command = friendsFeature.startFollowAll()
    self.followAllObservation?.cancel()
    self.followAllObservation = Task { [weak self] in
      do {
        try await command.value
        guard let self, !Task.isCancelled,
              friendsFeature.sessionFeature.isCurrent(userID: userID, generation: generation) else { return }
        self.friends = []
        self.onChange?()
        try await self.refreshDelay()
        try Task.checkCancellation()
        guard friendsFeature.sessionFeature.isCurrent(userID: userID, generation: generation) else { return }
        self.loadPage()
      } catch { }
    }
  }

  func waitForObservations() async {
    await self.followAllObservation?.value
    await self.pageObservation?.value
    await self.statisticsObservation?.value
  }

  deinit {
    self.pageObservation?.cancel()
    self.statisticsObservation?.cancel()
    self.followAllObservation?.cancel()
    let friendsFeature = self.friendsFeature, route = self.route
    Task { @MainActor in friendsFeature.release(route: route) }
  }
}
