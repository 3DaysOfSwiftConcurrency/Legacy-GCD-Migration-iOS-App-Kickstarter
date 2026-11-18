import UIKit
@testable import Kickstarter_iOS

@testable import KsApi


import Prelude
import SnapshotTesting
import XCTest

internal final class DiscoveryNavigationHeaderViewControllerTests: TestCase {
  private func makeController() -> DiscoveryNavigationHeaderViewController {
    DiscoveryNavigationHeaderViewController.instantiate(
      discoveryFeature: DiscoveryFeature(
        provider: EnvironmentDiscoveryProvider(),
        localStore: { AppEnvironment.current.userDefaults },
        cloudStore: { AppEnvironment.current.ubiquitousStore },
        serverEnvironment: { AppEnvironment.current.apiService.serverConfig.environment },
        isDebugBuild: {
          let bundle = AppEnvironment.current.mainBundle
          return bundle.isAlpha || bundle.isBeta || bundle.isDebug
        },
        sessionFeature: SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) })
      )
    )
  }

  let initialParams = .defaults
    |> DiscoveryParams.lens.includePOTD .~ true

  let cultureParams = .defaults |> DiscoveryParams.lens.category .~ .art
  let storyParams = .defaults |> DiscoveryParams.lens.category .~ .filmAndVideo
  let entertainmentParams = .defaults |> DiscoveryParams.lens.category .~ .games
  let cultureSubParams = .defaults |> DiscoveryParams.lens.category .~ .illustration
  let storySubParams = .defaults |> DiscoveryParams.lens.category .~ .documentary
  let entertainmentSubParams = .defaults |> DiscoveryParams.lens.category .~ .tabletopGames

  override func setUp() async throws {
    try await super.setUp()
    UIView.setAnimationsEnabled(false)
  }

  override func tearDown() async throws {
    UIView.setAnimationsEnabled(true)
    try await super.tearDown()
  }

  func testDiscoveryNavigationHeaderView() {
    Language.allLanguages.forEach { language in
      withEnvironment(language: language) {
        let controller = self.makeController()
        let (parent, _) = traitControllers(device: .phone4_7inch, orientation: .portrait, child: controller)
        parent.view.frame.size.height = 65

        controller.viewDidLoad()
        controller.configureWith(params: self.initialParams)

        assertSnapshot(matching: parent.view, as: .image, named: "lang_\(language)")
      }
    }
  }

  func testDiscoveryNavigationHeaderView_Art_All() {
    Language.allLanguages.forEach { language in
      withEnvironment(language: language) {
        let controller = self.makeController()
        let (parent, _) = traitControllers(device: .phone4_7inch, orientation: .portrait, child: controller)
        parent.view.frame.size.height = 65

        controller.viewDidLoad()
        controller.configureWith(params: self.cultureParams)

        assertSnapshot(matching: parent.view, as: .image, named: "lang_\(language)")
      }
    }
  }

  func testDiscoveryNavigationHeaderView_Art_Subcategory() {
    Language.allLanguages.forEach { language in
      withEnvironment(language: language) {
        let controller = self.makeController()
        let (parent, _) = traitControllers(device: .phone4_7inch, orientation: .portrait, child: controller)
        parent.view.frame.size.height = 65

        controller.viewDidLoad()
        controller.configureWith(params: self.cultureSubParams)

        assertSnapshot(matching: parent.view, as: .image, named: "lang_\(language)")
      }
    }
  }

  func testDiscoveryNavigationHeaderView_iPad() {
    Language.allLanguages.forEach { language in
      withEnvironment(language: language) {
        let controller = self.makeController()
        let (parent, _) = traitControllers(device: .pad, orientation: .portrait, child: controller)
        parent.view.frame.size.height = 65

        controller.viewDidLoad()
        controller.configureWith(params: self.initialParams)

        assertSnapshot(matching: parent.view, as: .image, named: "lang_\(language)")
      }
    }
  }

  func testDiscoveryNavigationHeaderView_Art_All_iPad() {
    Language.allLanguages.forEach { language in
      withEnvironment(language: language) {
        let controller = self.makeController()
        let (parent, _) = traitControllers(device: .pad, orientation: .portrait, child: controller)
        parent.view.frame.size.height = 65

        controller.viewDidLoad()
        controller.configureWith(params: self.cultureParams)

        assertSnapshot(matching: parent.view, as: .image, named: "lang_\(language)")
      }
    }
  }

  func testDiscoveryNavigationHeaderView_Art_Subcategory_iPad() {
    Language.allLanguages.forEach { language in
      withEnvironment(language: language) {
        let controller = self.makeController()
        let (parent, _) = traitControllers(device: .pad, orientation: .portrait, child: controller)
        parent.view.frame.size.height = 65

        controller.viewDidLoad()
        controller.configureWith(params: self.cultureSubParams)

        assertSnapshot(matching: parent.view, as: .image, named: "lang_\(language)")
      }
    }
  }
}

@MainActor
internal final class DiscoveryHeaderCompositionTests: TestCase {
  override var requiresSnapshotReferenceSimulator: Bool { false }

  func testDiscoveryParentSuppliesHeaderFeatureBeforeViewLoads() {
    let controller = DiscoveryViewController.instantiate(
      composition: AppModel.shared.discoveryComposition
    )

    controller.loadViewIfNeeded()

    XCTAssertTrue(controller.children.contains { $0 is DiscoveryNavigationHeaderViewController })
  }
}
