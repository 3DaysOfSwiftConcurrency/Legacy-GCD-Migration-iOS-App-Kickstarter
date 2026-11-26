// Configuration regression tests by Matthew Thomas.
@testable import Kickstarter_iOS
@testable import KsApi
import Foundation
import Prelude
import XCTest

@MainActor
final class ApplicationConfigurationServiceTests: XCTestCase {
  func testLiveRefreshPreservesDebugOverridesAndUsesServerFlagsInRelease() async {
    let stored = Config.template |> Config.lens.features .~ [
      "enabled_flag": true, "disabled_flag": false, "removed_flag": true
    ]
    let incoming = Config.template |> Config.lens.features .~ [
      "enabled_flag": false, "disabled_flag": true, "new_flag": true
    ]
    let apiService = MockService(fetchConfigResponse: incoming)
    let debugBundle = MockBundle(bundleIdentifier: KickstarterBundleIdentifier.beta.rawValue)

    await withEnvironment(apiService: apiService, config: stored, cookieStorage: MockCookieStorage(),
                          mainBundle: debugBundle) {
      _ = await ApplicationConfigurationService.live().startConfigurationRefresh().result
      XCTAssertEqual(AppEnvironment.current.config?.features, [
        "enabled_flag": true, "disabled_flag": false, "new_flag": true
      ])
    }

    let releaseBundle = MockBundle(bundleIdentifier: KickstarterBundleIdentifier.release.rawValue)
    await withEnvironment(apiService: apiService, config: stored, cookieStorage: MockCookieStorage(),
                          mainBundle: releaseBundle) {
      _ = await ApplicationConfigurationService.live().startConfigurationRefresh().result
      XCTAssertEqual(AppEnvironment.current.config?.features, incoming.features)
    }
  }

  func testEquivalentPrefetchesShareWithoutApplyingConfiguration() async throws {
    let gate = AccountRequestGate<Config>()
    defer { gate.releaseAll() }
    let service = ApplicationConfigurationService(
      load: { try await gate.request() },
      applyConfiguration: { _ in XCTFail("Prefetch applied configuration") }
    )
    let first = service.startConfigurationLoad()
    let second = service.startConfigurationLoad()
    await gate.waitFor(1)
    try gate.finish(0, .success(.template))
    _ = try await first.value
    _ = try await second.value
    let next = service.startConfigurationLoad()
    await gate.waitFor(2)
    try gate.finish(1, .success(.template))
    _ = try await next.value
    XCTAssertEqual(gate.count, 2)
  }

  func testResetRejectsAnOldConfiguration() async throws {
    let gate = AccountRequestGate<Config>()
    defer { gate.releaseAll() }
    var applied: [Config] = []
    let service = ApplicationConfigurationService(
      load: { try await gate.request() },
      applyConfiguration: { applied.append($0) }
    )
    let old = service.startConfigurationRefresh()
    await gate.waitFor(1)
    service.cancelPendingConfigurationLoad()
    let current = service.startConfigurationRefresh()
    await gate.waitFor(2)
    try gate.finish(0, .success(.template))
    try gate.finish(1, .success(.template))
    if case .success = await old.result { XCTFail("Reset configuration completed") }
    let config = try await current.value
    XCTAssertEqual(applied, [config])
  }

  func testConcurrentRefreshesApplyASharedPrefetchOnce() async throws {
    let gate = AccountRequestGate<Config>()
    defer { gate.releaseAll() }
    var applied: [Config] = []
    let service = ApplicationConfigurationService(
      load: { try await gate.request() },
      applyConfiguration: { applied.append($0) }
    )
    let prefetch = service.startConfigurationLoad()
    await gate.waitFor(1)
    let first = service.startConfigurationRefresh()
    let second = service.startConfigurationRefresh()
    try gate.finish(0, .success(.template))
    _ = try await first.value
    _ = try await second.value
    let config = try await prefetch.value
    XCTAssertEqual(gate.count, 1)
    XCTAssertEqual(applied, [config])
  }
}
