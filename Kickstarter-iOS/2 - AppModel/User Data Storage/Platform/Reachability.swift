import Foundation
import SystemConfiguration

public enum Reachability: Sendable {
  case wifi
  case wwan
  case none

  static func from(flags: SCNetworkReachabilityFlags) -> Reachability {
    // Preserve the existing classification, including WWAN precedence.
    if flags.contains(.isWWAN) { return .wwan }
    return flags.contains(.reachable) ? .wifi : .none
  }
}

public protocol ReachabilityMonitoring: AnyObject {
  var initial: Reachability { get }
  var updates: AsyncStream<Reachability> { get }
}

/// SystemConfiguration has no native async sequence. Its required serial callback
/// queue only yields immutable values; the application state belongs to the Feature.
/// The handle and C callback context remain retained until this owner is released.
public final class SystemReachabilityMonitor: ReachabilityMonitoring {
  public let initial: Reachability
  public let updates: AsyncStream<Reachability>
  private let reference: SCNetworkReachability
  private let continuation: AsyncStream<Reachability>.Continuation

  public init?() {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout.size(ofValue: address))
    address.sin_family = sa_family_t(AF_INET)
    guard let reference = withUnsafePointer(to: &address, { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        SCNetworkReachabilityCreateWithAddress(nil, $0)
      }
    }) else { return nil }
    var flags = SCNetworkReachabilityFlags()
    guard SCNetworkReachabilityGetFlags(reference, &flags) else { return nil }
    let (updates, continuation) = AsyncStream<Reachability>.makeStream()
    self.reference = reference
    self.initial = Reachability.from(flags: flags)
    self.updates = updates
    self.continuation = continuation

    let contextOwner = ReachabilityCallback(continuation: continuation)
    var context = SCNetworkReachabilityContext(
      version: 0, info: Unmanaged.passUnretained(contextOwner).toOpaque(),
      retain: { info in
        _ = Unmanaged<ReachabilityCallback>.fromOpaque(info).retain()
        return info
      }, release: { info in
        Unmanaged<ReachabilityCallback>.fromOpaque(info).release()
      }, copyDescription: nil)
    let registered = withExtendedLifetime(contextOwner) {
      SCNetworkReachabilitySetCallback(reference, { _, flags, info in
        guard let info else { return }
        Unmanaged<ReachabilityCallback>.fromOpaque(info).takeUnretainedValue()
          .continuation.yield(Reachability.from(flags: flags))
      }, &context)
    }
    guard registered,
      SCNetworkReachabilitySetDispatchQueue(reference, DispatchQueue(label: "com.kickstarter.reachability"))
    else {
      SCNetworkReachabilitySetCallback(reference, nil, nil)
      continuation.finish()
      return nil
    }
  }

  deinit {
    SCNetworkReachabilitySetDispatchQueue(self.reference, nil)
    SCNetworkReachabilitySetCallback(self.reference, nil, nil)
    self.continuation.finish()
  }
}

private final class ReachabilityCallback: Sendable {
  let continuation: AsyncStream<Reachability>.Continuation
  init(continuation: AsyncStream<Reachability>.Continuation) { self.continuation = continuation }
}

/// Main-actor state consumed by the owning domain Feature.
@MainActor
public final class ConnectivityState {
  public var value: Reachability {
    didSet { for observer in Array(self.observers.values) { observer(self.value) } }
  }
  private var observers: [UUID: (Reachability) -> Void] = [:]
  public init(_ value: Reachability = .none) { self.value = value }
  public func observe(_ observer: @escaping (Reachability) -> Void) -> MainActorObservation {
    let id = UUID()
    self.observers[id] = observer
    observer(self.value)
    return MainActorObservation { [weak self] in self?.observers.removeValue(forKey: id) }
  }
}

public final class MainActorObservation {
  private let cancel: @MainActor () -> Void
  @MainActor init(_ cancel: @escaping @MainActor () -> Void) { self.cancel = cancel }
  @MainActor public func stop() { self.cancel() }
  deinit {
    let cancel = self.cancel
    Task { @MainActor in cancel() }
  }
}

/// Application-scoped bridge from SystemConfiguration's callback stream to the
/// observable connectivity state used by Features. It is infrastructure, not a
/// product feature, and therefore survives account/session resets.
@MainActor
public final class ConnectivityService {
  private let makeMonitor: () -> (any ReachabilityMonitoring)?
  private var monitor: (any ReachabilityMonitoring)?
  private var task: Task<Void, Never>?
  private var started = false
  private let state: ConnectivityState

  public init(
    state: ConnectivityState = ConnectivityState(),
    makeMonitor: @escaping () -> (any ReachabilityMonitoring)? = { nil }
  ) {
    self.state = state
    self.makeMonitor = makeMonitor
  }

  public var connectivity: Reachability {
    self.start()
    return self.state.value
  }

  public var source: ConnectivityState {
    self.start()
    return self.state
  }

  private func start() {
    guard !self.started else { return }
    self.started = true
    guard let monitor = self.makeMonitor() else { return }
    self.monitor = monitor
    self.state.value = monitor.initial
    let updates = monitor.updates
    self.task = Task { [weak self] in
      for await value in updates {
        guard !Task.isCancelled, let self else { return }
        self.state.value = value
      }
    }
  }

  deinit { self.task?.cancel() }
}
