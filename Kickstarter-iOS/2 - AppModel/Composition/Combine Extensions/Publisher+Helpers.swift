import Combine

extension Publisher {
  /// Transforms the publisher's output into `Void`, discarding the original values
  /// while preserving the timing and completion/error events.
  ///
  /// - Returns: A publisher that emits `Void` for each value from the upstream publisher.
  public func mapOutputToVoid() -> Publishers.Map<Self, Void> {
    map { _ in () }
  }
}
