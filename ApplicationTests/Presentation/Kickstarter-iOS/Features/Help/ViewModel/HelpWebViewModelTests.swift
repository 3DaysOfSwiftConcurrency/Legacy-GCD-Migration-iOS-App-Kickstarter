@testable import Kickstarter_iOS
@testable import KsApi
import XCTest

@MainActor
internal final class HelpWebViewModelTests: TestCase {
  override var requiresSnapshotReferenceSimulator: Bool { false }

  func testWebRequestURLString() {
    let vm = HelpWebViewModel(
      webBaseURL: { ServerConfig.production.webBaseUrl },
      prepareRequest: { URLRequest(url: $0) }
    )
    XCTAssertNil(vm.requestForViewDidLoad())
    let cases: [(HelpType, String)] = [
      (.cookie, "/cookies"), (.helpCenter, "/help"), (.howItWorks, "/about"),
      (.privacy, "/privacy"), (.terms, "/terms-of-use")
    ]
    for (type, path) in cases {
      vm.configureWith(helpType: type)
      XCTAssertEqual(vm.requestForViewDidLoad()?.url?.relativePath, path)
    }
  }
}
