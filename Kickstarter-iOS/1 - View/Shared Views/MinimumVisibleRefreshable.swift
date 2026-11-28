import SwiftUI

public extension View {
  /// Adds refresh behavior whose indicator remains visible for at least the
  /// requested duration. The action still begins and completes immediately.
  func minimumVisibleRefreshable(
    minimumVisibleDuration: Duration = .milliseconds(300),
    action: @escaping @Sendable () async -> Void
  ) -> some View {
    refreshable {
      let clock = ContinuousClock()
      let startedAt = clock.now
      await action()
      let remaining = minimumVisibleDuration - startedAt.duration(to: clock.now)
      if remaining > .zero {
        try? await Task.sleep(for: remaining)
      }
    }
  }
}
