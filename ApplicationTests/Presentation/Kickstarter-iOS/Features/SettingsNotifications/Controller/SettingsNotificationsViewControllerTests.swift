@testable import Kickstarter_iOS

@testable import KsApi


import Prelude
import SnapshotTesting
import UIKit

final class SettingsNotificationsViewControllerTests: TestCase {
  private let sessionFeature = SessionFeature(
    makeProvider: { AsyncSessionProvider(service: AppEnvironment.current.apiService) }
  )
  private lazy var settingsFeature = SettingsFeature(
    sessionFeature: self.sessionFeature,
    responseDeliverySleep: { _ in },
    makeProvider: { AsyncAccountPreferencesProvider(service: AppEnvironment.current.apiService) }
  )
  private lazy var composition = SettingsNotificationsComposition(
    settingsFeature: self.settingsFeature,
    sessionFeature: self.sessionFeature,
    isVoiceOverRunning: { AppEnvironment.current.isVoiceOverRunning() }
  )

  override func setUp() async throws {
    try await super.setUp()
    UIView.setAnimationsEnabled(false)
  }

  override func tearDown() async throws {
    UIView.setAnimationsEnabled(true)
    try await super.tearDown()
  }

  func testSettingsNotificationsViewController() {
    let currentUser = .template
      |> UserAttribute.notification(.friendActivity).keyPath .~ true
      |> UserAttribute.notification(.mobileFollower).keyPath .~ true
      |> \.stats.backedProjectsCount .~ 1_234
      |> \.stats.memberProjectsCount .~ 2

    let mockService = MockService(fetchUserSelfResponse: currentUser)

    combos(Language.allLanguages, [Device.phone4_7inch, Device.phone5_8inch, Device.pad]).forEach {
      language, device in

      withEnvironment(
        apiService: mockService,
        currentUser: currentUser,
        language: language
      ) {
        let controller = SettingsNotificationsViewController.instantiate(
          composition: self.composition
        )
        let (parent, _) = traitControllers(device: device, orientation: .portrait, child: controller)


        assertSnapshot(matching: parent.view, as: .image, named: "lang_\(language)_device_\(device)")
      }
    }
  }

  func testSettingsNotificationsViewController_isCreator() {
    let currentUser = .template
      |> UserAttribute.notification(.pledgeActivity).keyPath .~ true
      |> UserAttribute.notification(.creatorTips).keyPath .~ true
      |> \.stats.backedProjectsCount .~ 5
      |> \.stats.memberProjectsCount .~ 2
      |> \.stats.createdProjectsCount .~ 4

    let mockService = MockService(fetchUserSelfResponse: currentUser)

    combos(Language.allLanguages, [Device.phone4_7inch, Device.phone5_8inch, Device.pad]).forEach {
      language, device in

      withEnvironment(
        apiService: mockService,
        currentUser: currentUser,
        language: language
      ) {
        let controller = SettingsNotificationsViewController.instantiate(
          composition: self.composition
        )
        let (parent, _) = traitControllers(device: device, orientation: .portrait, child: controller)


        assertSnapshot(matching: parent.view, as: .image, named: "lang_\(language)_device_\(device)")
      }
    }
  }
}
