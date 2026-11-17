import AdSupport
import AppTrackingTransparency
import Foundation

public typealias AppTrackingAuthorization = ATTrackingManager.AuthorizationStatus

@MainActor
public protocol AppTrackingTransparencyType {
  var advertisingIdentifier: String? { get }
  func observeAuthorizationStatus(_ observer: @escaping @MainActor (AppTrackingAuthorization) -> Void) -> UUID
  func removeAuthorizationObserver(_ id: UUID)
  func updateAdvertisingIdentifier()
  func requestAndSetAuthorizationStatus(_ completion: ((ATTrackingManager.AuthorizationStatus) -> Void)?)
  func shouldRequestAuthorizationStatus() -> Bool
}

public class AppTrackingTransparency: AppTrackingTransparencyType {
  public private(set) var advertisingIdentifier: String?

  public init() {
    self.updateAdvertisingIdentifier()
  }

  public func requestAndSetAuthorizationStatus(
    _ completion: ((ATTrackingManager.AuthorizationStatus) -> Void)? = nil
  ) {
    if let completion { self.authorizationCompletions.append(completion) }
    guard self.authorizationTask == nil else { return }
    self.authorizationTask = Task {
      let authStatus = await ATTrackingManager.requestTrackingAuthorization()
      self.setAuthorizationStatus(authStatus)
      self.advertisingIdentifier = authStatus == .authorized
        ? ASIdentifierManager.shared().advertisingIdentifier.uuidString : nil
      let completions = self.authorizationCompletions
      self.authorizationCompletions.removeAll()
      self.authorizationTask = nil
      for completion in completions { completion(authStatus) }
    }
  }

  // Consent survives navigation: a system prompt cannot be retracted. The adapter
  // remains alive until its shared native request delivers every admitted completion.
  private var authorizationTask: Task<Void, Never>?
  private var authorizationCompletions: [(AppTrackingAuthorization) -> Void] = []

  public func shouldRequestAuthorizationStatus() -> Bool {
    ATTrackingManager.trackingAuthorizationStatus == .notDetermined
  }

  public func updateAdvertisingIdentifier() {
    let status = ATTrackingManager.trackingAuthorizationStatus
    self.setAuthorizationStatus(status)

    switch status {
    case .authorized:
      self.advertisingIdentifier = ASIdentifierManager.shared().advertisingIdentifier.uuidString
    default:
      self.advertisingIdentifier = nil
    }
  }

  private var authorizationStatus: AppTrackingAuthorization = .notDetermined
  private var authorizationObservers: [UUID: @MainActor (AppTrackingAuthorization) -> Void] = [:]

  public func observeAuthorizationStatus(_ observer: @escaping @MainActor (AppTrackingAuthorization) -> Void) -> UUID {
    let id = UUID()
    self.authorizationObservers[id] = observer
    observer(self.authorizationStatus)
    return id
  }

  public func removeAuthorizationObserver(_ id: UUID) {
    self.authorizationObservers[id] = nil
  }

  private func setAuthorizationStatus(_ status: AppTrackingAuthorization) {
    guard self.authorizationStatus != status else { return }
    self.authorizationStatus = status
    for observer in Array(self.authorizationObservers.values) { observer(status) }
  }
}

/// Owns app-wide tracking consent scheduling and the analytics status subscription.
@MainActor
public final class AppTrackingConsent {
  private let tracking: () -> any AppTrackingTransparencyType
  private let hasSeenOnboarding: () -> Bool
  private let delay: @MainActor () async throws -> Void
  private var hasLaunched = false
  private var latestActiveState: Bool?
  private var lastScheduledState: Bool?
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var observation: (tracking: any AppTrackingTransparencyType, id: UUID)?

  var onAuthorizationStatus: (@MainActor (AppTrackingAuthorization) -> Void)?

  public init(
    tracking: @escaping () -> any AppTrackingTransparencyType,
    hasSeenOnboarding: @escaping () -> Bool,
    delay: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }
  ) {
    self.tracking = tracking
    self.hasSeenOnboarding = hasSeenOnboarding
    self.delay = delay
  }

  deinit {
    self.tasks.values.forEach { $0.cancel() }
    if let observation = self.observation {
      Task { @MainActor in observation.tracking.removeAuthorizationObserver(observation.id) }
    }
  }

  func applicationDidFinishLaunching() {
    self.hasLaunched = true
    self.scheduleTrackingRequestIfNeeded()
    self.observeAuthorization()
  }

  func applicationActive(state: Bool) {
    self.latestActiveState = state
    self.scheduleTrackingRequestIfNeeded()
    self.observeAuthorization()
  }

  private func scheduleTrackingRequestIfNeeded() {
    guard self.hasLaunched, let active = self.latestActiveState, self.lastScheduledState != active else { return }
    self.lastScheduledState = active
    guard active else { return }

    let id = UUID()
    let delay = self.delay
    self.tasks[id] = Task { [weak self] in
      defer { self?.tasks[id] = nil }
      do {
        try await delay()
        try Task.checkCancellation()
        guard let self, self.hasSeenOnboarding() else { return }
        let tracking = self.tracking()
        if tracking.advertisingIdentifier == nil, tracking.shouldRequestAuthorizationStatus() {
          tracking.requestAndSetAuthorizationStatus(nil)
        }
      } catch { /* Cancellation ends pending consent checks. */ }
    }
  }

  private func observeAuthorization() {
    let tracking = self.tracking()
    if let previous = self.observation {
      if (previous.tracking as AnyObject) === (tracking as AnyObject) { return }
      previous.tracking.removeAuthorizationObserver(previous.id)
    }
    let id = tracking.observeAuthorizationStatus { [weak self] status in
      self?.onAuthorizationStatus?(status)
    }
    self.observation = (tracking, id)
  }

  func waitForRequests() async {
    for task in Array(self.tasks.values) { await task.value }
  }
}
