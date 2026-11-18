@testable import Kickstarter_iOS
@testable import KsApi
import Experimentation
import XCTest

@MainActor
final class StatsigDebugViewModelTests: XCTestCase {
  func testConfiguredClientExposesStateAndReceivesActions() {
    let client = TrackingStatsigClient()
    let viewModel = StatsigDebugViewModel(settingsFeature: self.settingsFeature(client: client))

    XCTAssertTrue(viewModel.isStatsigEnabled)

    viewModel.reload()
    viewModel.showDebugger()

    XCTAssertEqual(client.reloadCount, 1)
    XCTAssertEqual(client.showDebuggerCount, 1)
  }

  func testMissingClientDisablesActions() {
    let viewModel = StatsigDebugViewModel(settingsFeature: self.settingsFeature(client: nil))

    XCTAssertFalse(viewModel.isStatsigEnabled)

    viewModel.reload()
    viewModel.showDebugger()
  }

  private func settingsFeature(client: TrackingStatsigClient?) -> SettingsFeature {
    SettingsFeature(
      sessionFeature: SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) }),
      applicationSettings: .test(statsigClient: { client }),
      makeProvider: { AsyncAccountPreferencesProvider(service: MockService()) }
    )
  }
}

private final class TrackingStatsigClient: StatsigClientType {
  private(set) var reloadCount = 0
  private(set) var showDebuggerCount = 0

  func reload(withUser _: StatsigClientUser) {
    self.reloadCount += 1
  }

  func showDebugger() {
    self.showDebuggerCount += 1
  }

  func checkGate(for _: StatsigFeature) -> Bool? { nil }

  func boolValue<T: StatsigExperimentProtocol>(
    forKey _: T.Parameters,
    inExperiment _: T
  ) -> Bool? { nil }
}
