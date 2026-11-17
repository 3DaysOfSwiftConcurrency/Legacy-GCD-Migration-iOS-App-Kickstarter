@testable import Kickstarter_iOS
@testable import KsApi


import XCTest

@MainActor
class PushNotificationDialogTests: XCTestCase {
  let userDefaults = MockKeyValueStore()

  func testIncomingDialogContextMustBePresentAndEligible() {
    let notification = Notification(
      name: .ksr_showNotificationsDialog,
      userInfo: [UserInfoKeys.context: PushNotificationDialog.Context.login]
    )
    withEnvironment(userDefaults: self.userDefaults) {
      PushNotificationDialog.didDenyAccess(for: .message)
      XCTAssertEqual(PushNotificationDialog.eligibleContext(for: notification), .login)
      PushNotificationDialog.didDenyAccess(for: .login)
      XCTAssertNil(PushNotificationDialog.eligibleContext(for: notification))
      XCTAssertNil(PushNotificationDialog.eligibleContext(for: Notification(name: .ksr_showNotificationsDialog)))
    }
  }

  func testTitleForDismissalIs_NotNow_WhenUserDeniedLessThanTwoTimes() {
    withEnvironment(userDefaults: self.userDefaults) {
      PushNotificationDialog.didDenyAccess(for: .save)

      XCTAssertEqual(PushNotificationDialog.titleForDismissal, "Not Now")
    }
  }

  func testTitleForDismissalIs_Never_WhenUserDeniedTwoTimes() {
    withEnvironment(userDefaults: self.userDefaults) {
      PushNotificationDialog.didDenyAccess(for: .login)
      PushNotificationDialog.didDenyAccess(for: .save)

      XCTAssertEqual(PushNotificationDialog.titleForDismissal, "Never")
    }
  }

  func testCanShowDialogIf_UserHasNeverDeniedForContext() {
    withEnvironment(userDefaults: self.userDefaults) {
      PushNotificationDialog.didDenyAccess(for: .save)

      XCTAssertTrue(PushNotificationDialog.canShowDialog(for: .message))
    }
  }

  func testCanNotShowDialogIf_UserDeniedForContext() {
    withEnvironment(userDefaults: self.userDefaults) {
      PushNotificationDialog.didDenyAccess(for: .save)

      XCTAssertFalse(PushNotificationDialog.canShowDialog(for: .save))
    }
  }

  func testCanShowDialogIf_UserDeniedLessThanThreeTimes() {
    withEnvironment(userDefaults: self.userDefaults) {
      PushNotificationDialog.didDenyAccess(for: .save)
      PushNotificationDialog.didDenyAccess(for: .message)

      XCTAssertTrue(PushNotificationDialog.canShowDialog(for: .pledge))
    }
  }

  func testCanNotShowDialogIf_UserDeniedThreeTimes() {
    withEnvironment(userDefaults: self.userDefaults) {
      PushNotificationDialog.didDenyAccess(for: .save)
      PushNotificationDialog.didDenyAccess(for: .message)
      PushNotificationDialog.didDenyAccess(for: .login)

      XCTAssertFalse(PushNotificationDialog.canShowDialog(for: .pledge))
    }
  }

  func testContextIsAddedToUserDefaults_AfterDenial() {
    withEnvironment(userDefaults: self.userDefaults) {
      PushNotificationDialog.didDenyAccess(for: .login)
      XCTAssertEqual(["login"], self.userDefaults.deniedNotificationContexts)

      PushNotificationDialog.didDenyAccess(for: .save)
      XCTAssertEqual(["login", "save"], self.userDefaults.deniedNotificationContexts)
    }
  }

  func testContextsReset_AfterLogout() {
    withEnvironment(userDefaults: self.userDefaults) {
      PushNotificationDialog.didDenyAccess(for: .login)
      PushNotificationDialog.didDenyAccess(for: .save)
      PushNotificationDialog.didDenyAccess(for: .message)
      PushNotificationDialog.didDenyAccess(for: .pledge)

      XCTAssertEqual(["login", "save", "message", "pledge"], self.userDefaults.deniedNotificationContexts)

      PushNotificationDialog.resetAllContexts()
      XCTAssertEqual([], self.userDefaults.deniedNotificationContexts)
    }
  }
}
