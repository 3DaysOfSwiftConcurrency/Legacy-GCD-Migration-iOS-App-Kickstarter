@testable import Kickstarter_iOS
import Experimentation


import XCTest

@MainActor
final class StatsigFeatureHelpersTests: TestCase {
  override var requiresSnapshotReferenceSimulator: Bool { false }

  func testFeatureLookupUsesTheReceiverInsteadOfAnotherEnvironmentClient() {
    let injected = MockStatsigWrapper()
    injected.features[.videoFeed] = true
    let environmentClient = MockStatsigWrapper()
    environmentClient.features[.videoFeed] = false

    withEnvironment(statsigClient: environmentClient) {
      XCTAssertTrue(injected.isFeatureEnabled(featureKey: .videoFeed))
      XCTAssertFalse(environmentClient.isFeatureEnabled(featureKey: .videoFeed))
    }
  }
}
