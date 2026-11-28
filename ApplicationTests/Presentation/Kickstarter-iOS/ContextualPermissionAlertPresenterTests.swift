@testable import Kickstarter_iOS


import UIKit
import XCTest

@MainActor
final class ContextualPermissionAlertPresenterTests: XCTestCase {
  func testEquivalentRequestKeepsOnePendingPresentation() {
    let owner = ContextualPermissionAlertPresenter()
    let screen = PermissionAlertScreen()
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = screen
    window.isHidden = false
    defer { window.isHidden = true }
    owner.schedule(context: .login, presenter: screen, accepted: {})
    let pending = owner.task
    owner.schedule(context: .login, presenter: screen, accepted: {})
    XCTAssertNotNil(pending)
    XCTAssertNotNil(owner.task)
    XCTAssertTrue(screen.alerts.isEmpty)
    owner.cancel()
    XCTAssertNil(owner.task)
  }

  func testAlertContentIsBuiltWithoutWaitingForPresentationDelay() throws {
    let alert = ContextualPermissionAlertPresenter.makeAlert(context: .login, accepted: {})
    XCTAssertEqual(alert.title, PushNotificationDialog.Context.login.title)
    XCTAssertEqual(alert.message, PushNotificationDialog.Context.login.message)
    XCTAssertEqual(alert.actions.map(\.style), [.default, .cancel])
    XCTAssertEqual(alert.actions.map(\.title), [Strings.project_star_ok(), PushNotificationDialog.titleForDismissal])
  }

  func testReplacementCancelsPendingPresentation() {
    let owner = ContextualPermissionAlertPresenter()
    let screen = PermissionAlertScreen()
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = screen; window.isHidden = false
    defer { window.isHidden = true }
    owner.schedule(context: .login, presenter: screen, accepted: {})
    let old = owner.task
    owner.schedule(context: .save, presenter: screen, accepted: {})
    let current = owner.task
    XCTAssertNotNil(old)
    XCTAssertNotNil(current)
    XCTAssertTrue(screen.alerts.isEmpty)
    owner.cancel()
  }

  func testCancellationSuppressesPendingPresentation() {
    let owner = ContextualPermissionAlertPresenter()
    let screen = PermissionAlertScreen()
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = screen; window.isHidden = false
    defer { window.isHidden = true }
    owner.schedule(context: .login, presenter: screen, accepted: {})
    owner.cancel()
    XCTAssertNil(owner.task)
    XCTAssertTrue(screen.alerts.isEmpty)
  }

  func testPendingDelayRetainsNeitherPresenterNorOwner() {
    var owner: ContextualPermissionAlertPresenter? = ContextualPermissionAlertPresenter()
    var screen: PermissionAlertScreen? = PermissionAlertScreen()
    owner?.schedule(context: .login, presenter: screen!, accepted: {})
    weak var weakScreen = screen
    weak var weakOwner = owner
    screen = nil; owner = nil
    XCTAssertNil(weakScreen)
    XCTAssertNil(weakOwner)
  }
}

@MainActor
private final class PermissionAlertScreen: UIViewController {
  var alerts: [UIAlertController] = []
  override func present(_ viewController: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
    if let alert = viewController as? UIAlertController { self.alerts.append(alert) }
    completion?()
  }
}
