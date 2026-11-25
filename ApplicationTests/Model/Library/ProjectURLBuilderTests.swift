@testable import Kickstarter_iOS
@testable import KsApi

import XCTest

@MainActor
class ProjectURLBuilderTests: XCTestCase {
  func testGetProjectBackingDetailsURL() throws {
    let baseURL = try XCTUnwrap(URL(string: "https://backing.example.invalid"))
    let backingDetailsURL = projectBackingDetailsURL(for: Project.template, webBaseURL: baseURL)
    let url = "https://backing.example.invalid/projects/1/a-fun-project/backing/details"

    XCTAssertNotNil(backingDetailsURL)
    XCTAssertEqual(backingDetailsURL?.absoluteString, url)
  }
}
