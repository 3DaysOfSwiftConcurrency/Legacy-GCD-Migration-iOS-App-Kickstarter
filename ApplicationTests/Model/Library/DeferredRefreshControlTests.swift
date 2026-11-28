@testable import Kickstarter_iOS

import UIKit
import XCTest

@MainActor
final class MinimumVisibleRefreshControlTests: XCTestCase {
  func testEndBeforeLayoutYieldCancelsPendingStart() async {
    let control = MinimumVisibleRefreshControl(frame: .zero, minimumVisibleDuration: .zero)
    let request = control.beginRefreshingAfterLayout()
    control.endRefreshing()
    await request.value
    XCTAssertFalse(control.isRefreshing)
  }

  func testRepeatedStartSharesPendingLifecycle() async {
    let control = MinimumVisibleRefreshControl(frame: .zero, minimumVisibleDuration: .zero)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let host = UIViewController()
    window.rootViewController = host
    let scroll = UIScrollView(frame: window.bounds)
    scroll.contentSize = CGSize(width: 390, height: 1200)
    scroll.refreshControl = control
    host.view.addSubview(scroll)
    window.makeKeyAndVisible()
    host.view.layoutIfNeeded()
    defer { window.isHidden = true }
    let old = control.beginRefreshingAfterLayout()
    let shared = control.beginRefreshingAfterLayout()
    await old.value; await shared.value
    XCTAssertTrue(control.isRefreshing)
    control.endRefreshing()
  }

  func testRemovalCancelsPendingStart() async throws {
    let scroll = UIScrollView()
    let control = MinimumVisibleRefreshControl(frame: .zero, minimumVisibleDuration: .zero)
    scroll.addSubview(try XCTUnwrap(control))
    let removed = control.beginRefreshingAfterLayout()
    control.removeFromSuperview()
    await removed.value
    XCTAssertFalse(control.isRefreshing)
  }

  func testEndRefreshingCompletesImmediatelyWhenMinimumDurationIsZero() {
    let control = MinimumVisibleRefreshControl(frame: .zero, minimumVisibleDuration: .zero)
    control.beginRefreshing()
    control.endRefreshing()
    XCTAssertFalse(control.isRefreshing)
  }
}
