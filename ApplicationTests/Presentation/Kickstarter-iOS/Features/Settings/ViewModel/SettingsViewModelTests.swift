@testable import Kickstarter_iOS
@testable import KsApi

import Prelude
import UIKit
import XCTest

@MainActor
final class SettingsViewModelTests: TestCase {
  override var requiresSnapshotReferenceSimulator: Bool { false }
  private let feature = SettingsFeature(
    sessionFeature: SessionFeature(makeProvider: { AsyncSessionProvider(service: AppEnvironment.current.apiService) }),
    makeProvider: { AsyncAccountPreferencesProvider(service: AppEnvironment.current.apiService) }
  )
  private lazy var vm = SettingsViewModel({ type in type == .notifications ? UIViewController() : nil },
                                           settingsFeature: self.feature)

  func testRatingUsesTheInjectedSettingsDestinationAndPreservesMissingDestinationFallback() {
    let destination = "https://example.test/application"
    var config: Config? = Config.template |> \.iTunesLink .~ destination
    let store = MockKeyValueStore()
    let center = NotificationCenter()
    let settings = SettingsFeature(
      sessionFeature: SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) }),
      applicationSettings: SettingsFeature.ApplicationSettings(
        configuration: ApplicationConfigurationService(load: {
          XCTFail("Choosing a settings destination must not fetch configuration")
          throw CancellationError()
        }),
        remoteConfiguration: RemoteConfigurationService(notificationCenter: center),
        readConfiguration: { config },
        currentCountryCode: { config?.countryCode },
        saveConfigurationOverride: { _ in XCTFail("Choosing a destination must not write configuration") },
        userDefaults: { store },
        notificationCenter: center
      ),
      makeProvider: { AsyncAccountPreferencesProvider(service: MockService()) }
    )
    let vm = SettingsViewModel({ _ in nil }, settingsFeature: settings)
    var destinations: [String] = []
    vm.onRate = { destinations.append($0) }

    vm.settingsCellTapped(cellType: .rateInAppStore)
    config = nil
    vm.settingsCellTapped(cellType: .rateInAppStore)

    XCTAssertEqual(destinations, [destination, ""])
  }

  func testCachedAndRefreshedUserUpdatesFollowingAvailability() async {
    let stored = User.template |> \.social .~ false
    let refreshed = User.template |> \.social .~ true
    await withEnvironment(apiService: MockService(fetchUserSelfResponse: refreshed), currentUser: stored) {
      var states: [Bool] = []
      self.vm.onReload = { _ in states.append(self.vm.findFriendsDisabled) }
      self.vm.viewDidLoad()
      await self.vm.waitForLoads()
      XCTAssertEqual(states, [true, false])
      XCTAssertTrue(self.vm.shouldSelectRow(for: .findFriends))
    }
  }

  func testNavigationLogoutAndRatingActions() {
    var promptCount = 0
    var logoutCount = 0
    var rateCount = 0
    var navigationCount = 0
    self.vm.onLogoutPrompt = { message, cancel, confirm in
      XCTAssertEqual(message, "Are you sure you want to log out?")
      XCTAssertEqual(cancel, "Cancel")
      XCTAssertEqual(confirm, "Yes")
      promptCount += 1
    }
    self.vm.onLogout = { _ in logoutCount += 1 }
    self.vm.onRate = { _ in rateCount += 1 }
    self.vm.onNavigate = { _ in navigationCount += 1 }
    self.vm.settingsCellTapped(cellType: .logout)
    self.vm.logoutConfirmed()
    self.vm.settingsCellTapped(cellType: .rateInAppStore)
    self.vm.settingsCellTapped(cellType: .notifications)
    XCTAssertEqual(promptCount, 1)
    XCTAssertEqual(logoutCount, 1)
    XCTAssertEqual(rateCount, 1)
    XCTAssertEqual(navigationCount, 1)
    XCTAssertTrue(self.vm.shouldSelectRow(for: .newsletters))
  }
}
