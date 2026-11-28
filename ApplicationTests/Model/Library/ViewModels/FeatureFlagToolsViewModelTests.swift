@testable import Kickstarter_iOS
@testable import KsApi
import Foundation
import Prelude
import XCTest

@MainActor
final class FeatureFlagToolsViewModelTests: XCTestCase {
  func testSortedRecognizedFeaturesAndUpdates() async {
    let keys = Feature.allCases.map(\.rawValue).sorted()
    let original = keys.reduce(into: [String: Bool]()) { $0[$1] = true }
    let config = Config.template |> \.features .~ original.merging(["unknown_feature": false]) { old, _ in old }
    let fixture = ConfigurationFlagToolsFixture(config: config)
    let vm = FeatureFlagToolsViewModel(settingsFeature: fixture.feature)
    var notifications = 0
    let observation = MainActorNotificationObservation(center: fixture.center, name: .ksr_configUpdated) { _ in
      notifications += 1
    }
    defer { observation.cancel() }

    vm.viewDidLoad()
    XCTAssertEqual(vm.reloadWithData, keys.map { [$0: true] })
    vm.setFeatureAtIndexEnabled(index: 0, isEnabled: true)
    vm.setFeatureAtIndexEnabled(index: -1, isEnabled: false)
    XCTAssertTrue(fixture.saved.isEmpty)
    vm.setFeatureAtIndexEnabled(index: 0, isEnabled: false)
    XCTAssertEqual(fixture.config?.features[keys[0]], false)
    XCTAssertEqual(fixture.config?.features["unknown_feature"], false)
    XCTAssertEqual(notifications, 1)
    await vm.waitForReload()
    XCTAssertEqual(vm.reloadWithData.first, [keys[0]: false])
  }

  func testRapidToggleBackUsesCurrentSettingsBeforeReload() async {
    let feature = Feature.segment
    let fixture = ConfigurationFlagToolsFixture(config: Config.template |> \.features .~ [feature.rawValue: true])
    let vm = FeatureFlagToolsViewModel(settingsFeature: fixture.feature)
    vm.viewDidLoad()

    vm.setFeatureAtIndexEnabled(index: 0, isEnabled: false)
    vm.setFeatureAtIndexEnabled(index: 0, isEnabled: true)
    XCTAssertEqual(fixture.saved.map { $0.features[feature.rawValue] }, [false, true])
    await vm.waitForReload()
    XCTAssertEqual(vm.reloadWithData, [[feature.rawValue: true]])
  }

  func testMissingConfigurationKeepsTheLastPresentationAndRejectsUpdates() {
    let fixture = ConfigurationFlagToolsFixture(config: nil)
    let vm = FeatureFlagToolsViewModel(settingsFeature: fixture.feature)
    vm.viewDidLoad()
    XCTAssertTrue(vm.reloadWithData.isEmpty)
    fixture.config = Config.template |> \.features .~ [Feature.segment.rawValue: true]
    vm.viewDidLoad()
    let previous = vm.reloadWithData
    fixture.config = nil
    vm.viewDidLoad()
    vm.setFeatureAtIndexEnabled(index: 0, isEnabled: false)
    XCTAssertEqual(vm.reloadWithData, previous)
    XCTAssertTrue(fixture.saved.isEmpty)
  }

  func testUnknownFeaturesAreIgnored() {
    XCTAssertTrue(featureEnabledFromDictionaries([["some_unknown_feature": false]]).isEmpty)
    let known = Feature.allCases[0].rawValue
    XCTAssertFalse(featureEnabledFromDictionaries([[known: false]]).isEmpty)
  }
}

@MainActor
private final class ConfigurationFlagToolsFixture {
  var config: Config?
  private(set) var saved: [Config] = []
  let center = NotificationCenter()
  private let store = MockKeyValueStore()

  init(config: Config?) { self.config = config }

  lazy var feature = SettingsFeature(
    sessionFeature: SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) }, currentUser: { nil }),
    applicationSettings: SettingsFeature.ApplicationSettings(
      configuration: ApplicationConfigurationService(load: {
        XCTFail("Flag tools must not fetch configuration")
        throw CancellationError()
      }),
      remoteConfiguration: RemoteConfigurationService(notificationCenter: self.center),
      readConfiguration: { [weak self] in self?.config },
      currentCountryCode: { [weak self] in self?.config?.countryCode },
      saveConfigurationOverride: { [weak self] config in
        self?.config = config
        self?.saved.append(config)
      },
      userDefaults: { [store = self.store] in store },
      notificationCenter: self.center
    ),
    makeProvider: { AsyncAccountPreferencesProvider(service: MockService()) }
  )
}
