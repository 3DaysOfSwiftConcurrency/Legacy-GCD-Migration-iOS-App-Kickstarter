// Connectivity regression tests by Matthew Thomas.
@testable import Kickstarter_iOS
import Foundation
import SystemConfiguration
import XCTest

@MainActor
final class ConnectivityServiceTests: XCTestCase {
  private let connectivityMonitor = ControlledReachabilityMonitor()
  private var monitorStarts = 0
  private func makeService() -> ConnectivityService {
    ConnectivityService(makeMonitor: { [weak self] in
      self?.monitorStarts += 1
      return self?.connectivityMonitor
    })
  }

  func testConnectivitySubscribersShareOneNativeMonitor() async {
    let service = self.makeService()
    XCTAssertEqual(self.monitorStarts, 0)
    XCTAssertEqual(service.connectivity, .wifi)
    var first: [Reachability] = []
    var second: [Reachability] = []
    let delivered = expectation(description: "both observers received offline")
    delivered.expectedFulfillmentCount = 2
    let a = service.connectivityState.observe {
      first.append($0)
      if $0 == .none { delivered.fulfill() }
    }
    let b = service.connectivityState.observe {
      second.append($0)
      if $0 == .none { delivered.fulfill() }
    }
    XCTAssertEqual(first, [.wifi])
    XCTAssertEqual(second, [.wifi])
    self.connectivityMonitor.continuation.yield(.wwan)
    self.connectivityMonitor.continuation.yield(.none)
    await fulfillment(of: [delivered], timeout: 2)
    XCTAssertEqual(first, [.wifi, .wwan, .none])
    XCTAssertEqual(second, first)
    XCTAssertEqual(self.monitorStarts, 1)
    withExtendedLifetime((a, b)) {}
  }

  func testConnectivityDisposalKeepsOtherObserverAndServiceReleaseStopsStream() async throws {
    var service: ConnectivityService? = self.makeService()
    let source = try XCTUnwrap(service).connectivityState
    let monitor = self.connectivityMonitor
    let stopped = expectation(description: "stream cancelled")
    monitor.continuation.onTermination = { _ in stopped.fulfill() }
    var stoppedValues: [Reachability] = []
    let a = source.observe { stoppedValues.append($0) }
    a.stop()
    let delivered = expectation(description: "remaining observer")
    let b = source.observe { if $0 == .wwan { delivered.fulfill() } }
    monitor.continuation.yield(.wwan)
    await fulfillment(of: [delivered], timeout: 2)
    XCTAssertEqual(stoppedValues, [.wifi])
    b.stop()
    weak var released = service
    service = nil
    XCTAssertNil(released)
    await fulfillment(of: [stopped], timeout: 2)
  }

  func testConnectivityObserverReceivesInitialValueSynchronously() {
    let service = self.makeService()
    var values: [Reachability] = []
    let observation = service.connectivityState.observe { values.append($0) }
    XCTAssertEqual(values, [.wifi])
    XCTAssertEqual(self.monitorStarts, 1)
    withExtendedLifetime(observation) {}
  }

  func testReachabilityPreservesNativeFlagClassification() {
    XCTAssertEqual(Reachability.from(flags: []), .none)
    XCTAssertEqual(Reachability.from(flags: [.reachable]), .wifi)
    XCTAssertEqual(Reachability.from(flags: [.isWWAN]), .wwan)
    XCTAssertEqual(Reachability.from(flags: [.isWWAN, .reachable]), .wwan)
    XCTAssertEqual(Reachability.from(flags: [.connectionRequired]), .none)
  }

  func testNativeReachabilityMonitorReleaseFinishesItsStream() async throws {
    var monitor: SystemReachabilityMonitor? = try XCTUnwrap(SystemReachabilityMonitor())
    let stream = try XCTUnwrap(monitor).updates
    weak var released = monitor
    monitor = nil
    XCTAssertNil(released)
    let ended = expectation(description: "native stream ended")
    let consumer = Task {
      for await _ in stream {}
      ended.fulfill()
    }
    await fulfillment(of: [ended], timeout: 2)
    consumer.cancel()
    await consumer.value
  }

}

final class ControlledReachabilityMonitor: ReachabilityMonitoring {
  let initial: Reachability = .wifi
  let updates: AsyncStream<Reachability>
  let continuation: AsyncStream<Reachability>.Continuation
  init() { (self.updates, self.continuation) = AsyncStream<Reachability>.makeStream() }
}
