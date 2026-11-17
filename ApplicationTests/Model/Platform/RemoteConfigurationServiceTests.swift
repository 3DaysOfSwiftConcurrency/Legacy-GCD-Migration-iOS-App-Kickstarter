// Configuration regression tests by Matthew Thomas.
@testable import Kickstarter_iOS
@testable import KsApi
import Foundation
import Prelude
import XCTest

@MainActor
final class RemoteConfigurationServiceTests: XCTestCase {
  func testSharedActivationReportsFailureOnceAndPublishesSuccessAfterRetry() async throws {
    let center = NotificationCenter()
    var reportedErrors: [URLError.Code] = []
    let service = RemoteConfigurationService(notificationCenter: center) { error in
      if let error = error as? URLError { reportedErrors.append(error.code) }
    }
    var notifications: [Notification.Name] = []
    let observers = [
      MainActorNotificationObservation(center: center, name: .ksr_remoteConfigClientConfigured) {
        notifications.append($0.name)
      },
      MainActorNotificationObservation(center: center, name: .ksr_remoteConfigClientConfigurationFailed) {
        notifications.append($0.name)
      }
    ]
    defer { observers.forEach { $0.cancel() } }

    let gate = AccountRequestGate<Void>()
    let client = GatedRemoteConfigClient(gate: gate)
    defer { gate.releaseAll() }
    let first = service.activate(client: client)
    let second = service.activate(client: client)
    await gate.waitFor(1)
    try gate.finish(0, .failure(URLError(.notConnectedToInternet)))
    for request in [first, second] {
      if case .success = await request.result { XCTFail("Failure was swallowed") }
    }
    XCTAssertEqual(notifications, [.ksr_remoteConfigClientConfigurationFailed])
    XCTAssertEqual(reportedErrors, [.notConnectedToInternet])

    let retry = service.activate(client: client)
    await gate.waitFor(2)
    try gate.finish(1, .success(()))
    try await retry.value
    XCTAssertEqual(gate.count, 2)
    XCTAssertEqual(notifications, [.ksr_remoteConfigClientConfigurationFailed, .ksr_remoteConfigClientConfigured])
    XCTAssertEqual(reportedErrors, [.notConnectedToInternet])
  }

  func testReplacingClientSuppressesBothLateSuccessAndLateFailure() async throws {
    let center = NotificationCenter()
    let service = RemoteConfigurationService(notificationCenter: center) { _ in
      XCTFail("Obsolete client error was reported")
    }
    var publishedSuccesses = 0
    let configured = MainActorNotificationObservation(center: center, name: .ksr_remoteConfigClientConfigured) {
      _ in publishedSuccesses += 1
    }
    let failed = MainActorNotificationObservation(center: center, name: .ksr_remoteConfigClientConfigurationFailed) {
      _ in XCTFail("Obsolete client failure was published")
    }
    defer { configured.cancel(); failed.cancel() }

    for obsoleteResult: Result<Void, Error> in [.success(()), .failure(URLError(.notConnectedToInternet))] {
      let gate = AccountRequestGate<Void>()
      defer { gate.releaseAll() }
      let old = service.activate(client: GatedRemoteConfigClient(gate: gate))
      await gate.waitFor(1)
      let replacement = service.activate(client: GatedRemoteConfigClient(gate: gate))
      await gate.waitFor(2)
      try gate.finish(1, .success(()))
      try await replacement.value
      try gate.finish(0, obsoleteResult)
      if case .success = await old.result { XCTFail("Replaced activation completed") }
    }
    XCTAssertEqual(publishedSuccesses, 2)
  }
}

private final class GatedRemoteConfigClient: MockRemoteConfigClient {
  private let gate: AccountRequestGate<Void>

  init(gate: AccountRequestGate<Void>) {
    self.gate = gate
    super.init()
  }

  override func fetchAndActivateAsync() async throws {
    try await self.gate.request()
  }
}
