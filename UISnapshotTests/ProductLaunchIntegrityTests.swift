//
//  ProductLaunchIntegrityTests.swift
//  UISnapshotTests
//
//  Created by Matthew Thomas on 27/11/2026.
//  Copyright © 2026 Kickstarter. All rights reserved.
//

import XCTest

final class ProductLaunchIntegrityTests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testNormalProductRootIsVisible() {
    let app = XCUIApplication()
    app.launch()

    XCTAssertTrue(
      app.staticTexts["Explore"].waitForExistence(timeout: 10),
      "The normal product root must present the Explore control."
    )
  }
}
