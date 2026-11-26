import Foundation

import Observation

/// Owns direct-link presentation and its task; the Feature owns request decisions.
@MainActor @Observable
internal final class RichTextExampleProjectsViewModel {
  typealias ProjectItem = DeveloperExamplesFeature.ProjectItem
  private let developerExamplesFeature: DeveloperExamplesFeature
  private let route = UUID()
  @ObservationIgnored private var lookupTask: Task<Void, Never>?
  @ObservationIgnored private var submittedInput: String?
  @ObservationIgnored private var lookupID: UUID?
  private(set) var slugError = false
  var projects: [ProjectItem] { self.developerExamplesFeature.richTextSnapshot(route: self.route).projects }
  var isLoading: Bool { self.developerExamplesFeature.richTextSnapshot(route: self.route).isLoading }
  var errorMessage: String? { self.developerExamplesFeature.richTextSnapshot(route: self.route).errorMessage }

  init(developerExamplesFeature: DeveloperExamplesFeature = AppModel.shared.developerExamplesFeature) {
    self.developerExamplesFeature = developerExamplesFeature
  }
  deinit {
    self.lookupTask?.cancel()
    let developerExamplesFeature = self.developerExamplesFeature, route = self.route
    Task { @MainActor in developerExamplesFeature.release(route: route) }
  }

  func loadProjects() async { await self.developerExamplesFeature.loadRichTextProjects(route: self.route) }

  @discardableResult
  func submit(input: String, onSelect: @escaping (ProjectItem) -> Void) -> Task<Void, Never> {
    if self.submittedInput == input, let task = self.lookupTask { return task }
    self.clearLookup()
    let id = UUID()
    let developerExamplesFeature = self.developerExamplesFeature
    let route = self.route
    self.lookupID = id
    self.submittedInput = input
    let task = Task { [weak self] in
      defer {
        if self?.lookupID == id {
          self?.lookupTask = nil
          self?.submittedInput = nil
        }
      }
      do {
        let project = try await developerExamplesFeature.lookupRichTextExampleProject(input: input, route: route)
        try Task.checkCancellation()
        guard let self, self.lookupID == id else { return }
        if let project { onSelect(project) } else { self.slugError = true }
      } catch {
        guard !Task.isCancelled, !(error is CancellationError), self?.lookupID == id else { return }
        self?.slugError = true
      }
    }
    self.lookupTask = task
    return task
  }
  func clearLookup() {
    self.lookupTask?.cancel()
    self.lookupTask = nil
    self.lookupID = nil
    self.submittedInput = nil
    self.slugError = false
    self.developerExamplesFeature.cancelRichTextProjectLookup(route: self.route)
  }
  func suspend() {
    self.clearLookup()
    self.developerExamplesFeature.cancelExampleLoads(route: self.route)
  }
}
