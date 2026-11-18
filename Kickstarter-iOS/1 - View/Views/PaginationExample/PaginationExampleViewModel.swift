import Foundation
import KsApi

import Observation

extension Project: Identifiable {}

/// Owns the pagination example's screen lifetime and presentation projection.
@MainActor @Observable
internal final class PaginationExampleViewModel {
  typealias ProjectData = DeveloperExamplesFeature.ProjectData
  private let developerExamplesFeature: DeveloperExamplesFeature
  private let route = UUID()
  var projects: [ProjectData] { self.developerExamplesFeature.pageSnapshot(route: self.route).projects }
  var showProgressView: Bool { self.developerExamplesFeature.pageSnapshot(route: self.route).showProgressView }
  var statusText: String { self.developerExamplesFeature.pageSnapshot(route: self.route).statusText }

  init(developerExamplesFeature: DeveloperExamplesFeature = AppModel.shared.developerExamplesFeature) {
    self.developerExamplesFeature = developerExamplesFeature
  }
  deinit {
    let developerExamplesFeature = self.developerExamplesFeature, route = self.route
    Task { @MainActor in developerExamplesFeature.release(route: route) }
  }
  func load() async { await self.developerExamplesFeature.loadFirstPage(route: self.route) }
  func refresh() async { await self.developerExamplesFeature.loadFirstPage(route: self.route, refreshing: true) }
  func loadNextPage() async { await self.developerExamplesFeature.loadNextPage(route: self.route) }
  func suspend() { self.developerExamplesFeature.suspend(route: self.route) }
}
