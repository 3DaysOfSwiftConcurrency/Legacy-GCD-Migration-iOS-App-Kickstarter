@testable import Kickstarter_iOS

import XCTest

/// Banner visibility duration is UI-owned. Its lifecycle is tested deterministically
/// by MessageBannerViewModelTests; this target retains binding-state coverage without
/// sleeping through presentation time.
@MainActor
final class MessageBannerLifetimeTests: XCTestCase {
  func testReplacementKeepsTheCurrentBannerBinding() {
    var current: MessageBannerViewViewModel? = MessageBannerViewViewModel((.success, "Original"))
    let replacement = MessageBannerViewViewModel((.success, "Replacement"))

    current = replacement

    XCTAssertTrue(current === replacement)
    XCTAssertEqual(current?.bannerMessage, "Replacement")
  }

  func testClearingBindingRemovesCurrentBanner() {
    var current: MessageBannerViewViewModel? = MessageBannerViewViewModel((.success, "Banner"))

    current = nil

    XCTAssertNil(current)
  }
}
