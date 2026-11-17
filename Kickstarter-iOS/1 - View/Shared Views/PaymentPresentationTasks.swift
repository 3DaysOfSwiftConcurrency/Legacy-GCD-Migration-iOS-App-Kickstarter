import Foundation

/// Owns the screen's observation of payment work. PaymentsFeature owns admitted mutations.
@MainActor
final class PaymentPresentationTasks {
  enum Operation: Hashable, Sendable {
    case cards, delete, setup, store
  }

  private var tasks: [Operation: (id: UUID, task: Task<Void, Never>)] = [:]
  var isIdle: Bool { self.tasks.isEmpty }

  @discardableResult
  func replace(
    _ operation: Operation, perform: @escaping @MainActor () async -> Void
  ) -> Task<Void, Never> {
    self.cancel(operation)
    let id = UUID()
    let task = Task { [weak self] in
      defer {
        if self?.tasks[operation]?.id == id { self?.tasks[operation] = nil }
      }
      guard !Task.isCancelled else { return }
      await perform()
    }
    self.tasks[operation] = (id, task)
    return task
  }

  func cancel(_ operation: Operation) {
    self.tasks.removeValue(forKey: operation)?.task.cancel()
  }

  func waitForPending() async {
    while !self.isIdle {
      for entry in Array(self.tasks.values) { await entry.task.value }
    }
  }

  deinit {
    for entry in self.tasks.values { entry.task.cancel() }
  }
}
