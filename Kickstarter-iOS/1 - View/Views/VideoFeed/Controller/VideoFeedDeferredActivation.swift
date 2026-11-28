import Foundation

/// One pending UI activation. New layout/appearance requests replace old ones;
/// disappearance/backgrounding cancels them. The caller rechecks visible UI state.
@MainActor
final class VideoFeedDeferredActivation {
  private var generation = UUID()
  private(set) var task: Task<Void, Never>?

  init() {}

  func schedule(_ activate: @escaping @MainActor () -> Void) {
    self.cancel()
    let generation = self.generation
    self.task = Task { [weak self] in
      await Task.yield()
      guard !Task.isCancelled, let self, self.generation == generation else { return }
      self.task = nil
      activate()
    }
  }

  func cancel() {
    self.generation = UUID()
    self.task?.cancel()
    self.task = nil
  }

  deinit { self.task?.cancel() }
}
