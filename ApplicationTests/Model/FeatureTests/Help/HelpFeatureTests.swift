@testable import Kickstarter_iOS
import XCTest

@MainActor
final class HelpFeatureTests: XCTestCase {
  func testRequestBuildsPreparedRequestForWebHelp() {
    let baseURL = URL(string: "https://www.example.com")!
    var preparedURL: URL?
    let feature = HelpFeature(
      webBaseURL: { baseURL },
      prepareRequest: { url in
        preparedURL = url
        var request = URLRequest(url: url)
        request.setValue("test-token", forHTTPHeaderField: "Authorization")
        return request
      }
    )

    let request = feature.makeWebRequest(for: .helpCenter)

    XCTAssertEqual(preparedURL, URL(string: "https://www.example.com/help"))
    XCTAssertEqual(request?.url, preparedURL)
    XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "test-token")
  }

  func testContactDoesNotBuildAWebRequest() {
    var preparedRequestCount = 0
    let feature = HelpFeature(
      webBaseURL: { URL(string: "https://www.example.com")! },
      prepareRequest: { url in
        preparedRequestCount += 1
        return URLRequest(url: url)
      }
    )

    XCTAssertNil(feature.makeWebRequest(for: .contact))
    XCTAssertEqual(preparedRequestCount, 0)
  }
}
