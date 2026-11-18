import UIKit
@testable import Kickstarter_iOS

@testable import KsApi

import Prelude
import XCTest

@MainActor
final class DiscoveryProjectsDataSourceTests: XCTestCase {
  let dataSource = DiscoveryProjectsDataSource(
    projectMediaFeature: AppModel.shared.projectMediaFeature,
    cardPresentation: AppModel.shared.discoveryComposition.cardPresentation
  )
  let tableView = UITableView()

  func testOnboarding() {
    let section = DiscoveryProjectsDataSource.Section.onboarding.rawValue

    self.dataSource.show(onboarding: true)

    XCTAssertEqual(section + 1, self.dataSource.numberOfSections(in: self.tableView))
    XCTAssertEqual(1, self.dataSource.tableView(self.tableView, numberOfRowsInSection: section))

    self.dataSource.show(onboarding: false)

    XCTAssertEqual(section + 1, self.dataSource.numberOfSections(in: self.tableView))
    XCTAssertEqual(0, self.dataSource.tableView(self.tableView, numberOfRowsInSection: section))
  }

  func testPersonalization() {
    let section = DiscoveryProjectsDataSource.Section.personalization.rawValue

    self.dataSource.showPersonalization(true)

    XCTAssertEqual(3, self.dataSource.numberOfSections(in: self.tableView))
    XCTAssertEqual(1, self.dataSource.tableView(self.tableView, numberOfRowsInSection: section))

    self.dataSource.showPersonalization(false)

    XCTAssertEqual(3, self.dataSource.numberOfSections(in: self.tableView))
    XCTAssertEqual(0, self.dataSource.tableView(self.tableView, numberOfRowsInSection: section))
  }

  func testVideoFeedBanner() {
    let section = DiscoveryProjectsDataSource.Section.videoFeedBanner.rawValue

    self.dataSource.showVideoFeedBanner(true)

    XCTAssertEqual(1, self.dataSource.numberOfSections(in: self.tableView))
    XCTAssertEqual(1, self.dataSource.tableView(self.tableView, numberOfRowsInSection: section))

    self.dataSource.showVideoFeedBanner(false)

    XCTAssertEqual(1, self.dataSource.numberOfSections(in: self.tableView))
    XCTAssertEqual(0, self.dataSource.tableView(self.tableView, numberOfRowsInSection: section))
  }

  func testActivitySample() {
    let section = DiscoveryProjectsDataSource.Section.activitySample.rawValue

    self.dataSource.load(activities: [.template])

    XCTAssertEqual(section + 1, self.dataSource.numberOfSections(in: self.tableView))
    XCTAssertEqual(1, self.dataSource.tableView(self.tableView, numberOfRowsInSection: section))

    self.dataSource.load(activities: [])

    XCTAssertEqual(section + 1, self.dataSource.numberOfSections(in: self.tableView))
    XCTAssertEqual(0, self.dataSource.tableView(self.tableView, numberOfRowsInSection: section))
  }

  func testProjects() {
    let section = DiscoveryProjectsDataSource.Section.projects.rawValue

    self.dataSource.load(projects: [.template, .template, .template])

    XCTAssertEqual(section + 1, self.dataSource.numberOfSections(in: self.tableView))
    XCTAssertEqual(3, self.dataSource.tableView(self.tableView, numberOfRowsInSection: section))

    self.dataSource.load(projects: [])

    XCTAssertEqual(section + 1, self.dataSource.numberOfSections(in: self.tableView))
    XCTAssertEqual(0, self.dataSource.tableView(self.tableView, numberOfRowsInSection: section))
  }

  func testProjects_ExperimentVariant() {
    let section = DiscoveryProjectsDataSource.Section.projects.rawValue

    self.dataSource.load(
      projects: [.template, .template, .template],
      params: DiscoveryParams.defaults
    )

    XCTAssertEqual(section + 1, self.dataSource.numberOfSections(in: self.tableView))
    XCTAssertEqual(3, self.dataSource.tableView(self.tableView, numberOfRowsInSection: section))
  }

  func testProjectCellsReceiveComposedProjectMediaFeature() {
    let value = DiscoveryProjectCellRowValue(
      project: .template,
      category: nil,
      params: .defaults
    )
    self.tableView.register(nib: Nib.DiscoveryPostcardCell)
    self.tableView.dataSource = self.dataSource
    self.dataSource.load(projects: [value.project], params: value.params)

    let indexPath = self.dataSource.indexPath(forProjectRow: 0)
    XCTAssertTrue(self.dataSource.tableView(self.tableView, cellForRowAt: indexPath) is DiscoveryPostcardCell)

    let card = DiscoveryProjectCardCell(style: .default, reuseIdentifier: nil)
    card.configure(
      projectMediaFeature: AppModel.shared.projectMediaFeature,
      cardPresentation: environmentDiscoveryCardPresentation()
    )
    card.configureWith(value: value)
  }
}
