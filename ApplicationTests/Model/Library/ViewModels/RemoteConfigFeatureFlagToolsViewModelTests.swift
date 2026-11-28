@testable import Kickstarter_iOS
@testable import KsApi
import Experimentation
import Foundation
import XCTest

@MainActor
final class RemoteConfigFlagToolsViewModelTests: XCTestCase {
  func testLoadsRemoteValuesAndPersistsOverride() async throws {
    let key = RemoteConfigFeature.floatingTabBar
    let fixture = RemoteFlagToolsFixture()
    fixture.remote.features[key.rawValue] = false
    let vm = RemoteConfigFeatureFlagToolsViewModel(settingsFeature: fixture.feature)
    vm.viewDidLoad()
    let index = try XCTUnwrap(vm.remoteConfigFeatures.firstIndex(where: { $0.0 == key }))
    XCTAssertFalse(vm.remoteConfigFeatures[index].1)

    vm.setFeatureAtIndexEnabled(index: index, isEnabled: true)
    await vm.waitForReload()
    let stored = fixture.store.dictionary(
      forKey: "com.kickstarter.KeyValueStoreType.remoteConfigFeatureFlags"
    ) as? [String: Bool]
    XCTAssertEqual(stored?[key.rawValue], true)
    XCTAssertEqual(fixture.remote.features[key.rawValue], false)
    XCTAssertTrue(vm.remoteConfigFeatures[index].1)
  }

  func testStatsigToggleWritesOverride() async throws {
    let fixture = RemoteFlagToolsFixture()
    let vm = RemoteConfigFeatureFlagToolsViewModel(settingsFeature: fixture.feature)
    vm.viewDidLoad()
    let key = try XCTUnwrap(vm.statsigFeatures.first?.0)
    vm.setStatsigFeatureAtIndexEnabled(index: 0, isEnabled: true)
    await vm.waitForReload()
    XCTAssertEqual(fixture.store.statsigFeatureFlags[key.rawValue], true)
    XCTAssertTrue(vm.statsigFeatures[0].1)
  }

  func testOutOfRangeIndicesDoNotWriteOverrides() {
    let fixture = RemoteFlagToolsFixture()
    let vm = RemoteConfigFeatureFlagToolsViewModel(settingsFeature: fixture.feature)
    vm.viewDidLoad()
    vm.setFeatureAtIndexEnabled(index: -1, isEnabled: true)
    vm.setFeatureAtIndexEnabled(index: vm.remoteConfigFeatures.count, isEnabled: true)
    vm.setStatsigFeatureAtIndexEnabled(index: -1, isEnabled: true)
    vm.setStatsigFeatureAtIndexEnabled(index: vm.statsigFeatures.count, isEnabled: true)
    XCTAssertTrue(fixture.store.remoteConfigFeatureFlags.isEmpty)
    XCTAssertTrue(fixture.store.statsigFeatureFlags.isEmpty)
  }
}

@MainActor
private final class RemoteFlagToolsFixture {
  let store = MockKeyValueStore()
  let remote = MockRemoteConfigClient()
  private let center = NotificationCenter()

  lazy var feature = SettingsFeature(
    sessionFeature: SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) }, currentUser: { nil }),
    applicationSettings: SettingsFeature.ApplicationSettings(
      configuration: ApplicationConfigurationService(load: {
        XCTFail("Flag tools must not fetch configuration")
        throw CancellationError()
      }),
      remoteConfiguration: RemoteConfigurationService(notificationCenter: self.center),
      readConfiguration: { nil },
      currentCountryCode: { nil },
      saveConfigurationOverride: { _ in XCTFail("Remote tools must not change REST configuration") },
      userDefaults: { [store = self.store] in store },
      remoteClient: { [remote = self.remote] in remote },
      notificationCenter: self.center
    ),
    makeProvider: { AsyncAccountPreferencesProvider(service: MockService()) }
  )
}
