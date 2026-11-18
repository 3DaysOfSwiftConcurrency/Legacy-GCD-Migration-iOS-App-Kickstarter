import KsApi
import SwiftUI

/// Presentation of the reporting options owned by ProjectReportingFeature.
@MainActor
public final class ReportProjectInfoViewModel: ObservableObject {
  @Published public var listItems: [ReportProjectInfoListItem] = []
  @Published public var isLoading = false
  private let projectReportingFeature: ProjectReportingFeature
  private var loadTask: Task<Void, Never>?
  private var loadID: UUID?

  public init(projectReportingFeature: ProjectReportingFeature = AppModel.shared.projectReportingFeature) {
    self.projectReportingFeature = projectReportingFeature
  }

  deinit { self.loadTask?.cancel() }

  @discardableResult
  public func viewDidLoad() -> Task<Void, Never> {
    if let task = self.loadTask { return task }
    let projectReportingFeature = self.projectReportingFeature
    let context = projectReportingFeature.context
    let id = UUID()
    self.loadID = id
    self.isLoading = true
    let task = Task { [weak self] in
      defer {
        if self?.loadID == id {
          self?.loadTask = nil
          self?.isLoading = false
        }
      }
      do {
        let items = try await projectReportingFeature.fetchReportOptions(context: context)
        try projectReportingFeature.ensureReportingSessionIsCurrent(context)
        guard self?.loadID == id else { return }
        self?.listItems = items
      } catch {
        // The existing screen keeps its options empty on failure.
      }
    }
    self.loadTask = task
    return task
  }

  public func stop() {
    self.loadID = nil
    self.loadTask?.cancel()
    self.loadTask = nil
    self.isLoading = false
  }
}
