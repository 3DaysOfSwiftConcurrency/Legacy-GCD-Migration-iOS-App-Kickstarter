@testable import Kickstarter_iOS
@testable import KsApi


import Prelude
import XCTest

@MainActor
final class OnboardingUseCaseTests: TestCase {
  override var requiresSnapshotReferenceSimulator: Bool { false }
  var useCase: OnboardingUseCase!


  override func setUp() async throws {
    try await super.setUp()

    self.useCase = OnboardingUseCase(for: Bundle.main)


  }

  func testUseCase_onboardingItems_EmitsAListOfAll5OboardingItemTypes_Once() {
    XCTAssertEqual(self.useCase.uiOutputs.onboardingItems.count, 5)
  }

}
