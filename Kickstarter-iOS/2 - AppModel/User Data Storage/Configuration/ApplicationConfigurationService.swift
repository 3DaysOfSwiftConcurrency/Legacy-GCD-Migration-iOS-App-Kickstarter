// Application settings transport support by Matthew Thomas.
import Foundation
import KsApi
import Prelude

/// Owns the application-configuration read triggered by launch and foreground signals.
///
/// Configuration is shared application infrastructure: it is not a screen concern and
/// it is not a product feature. A session reset replaces any in-flight read.
@MainActor
public final class ApplicationConfigurationService {
  private let load: @MainActor () async throws -> Config
  private let installVisitorCookies: @MainActor () -> Void
  private let debugFeatureFlags: @MainActor () -> [String: Bool]
  private let applyConfiguration: @MainActor (Config) -> Void
  private var request: (id: UUID, task: Task<Config, Error>, appliesResult: Bool)?

  public init(
    load: @escaping @MainActor () async throws -> Config,
    installVisitorCookies: @escaping @MainActor () -> Void = {},
    debugFeatureFlags: @escaping @MainActor () -> [String: Bool] = { [:] },
    applyConfiguration: @escaping @MainActor (Config) -> Void = { _ in }
  ) {
    self.load = load
    self.installVisitorCookies = installVisitorCookies
    self.debugFeatureFlags = debugFeatureFlags
    self.applyConfiguration = applyConfiguration
  }

  @discardableResult func refresh() -> Task<Config, Error> {
    self.installVisitorCookies()
    return self.requestConfiguration(applyResult: true)
  }

  public func configuration() async throws -> Config {
    try Task.checkCancellation()
    let value = try await self.requestConfiguration().value
    try Task.checkCancellation()
    return value
  }

  @discardableResult public func requestConfiguration() -> Task<Config, Error> {
    self.requestConfiguration(applyResult: false)
  }

  private func requestConfiguration(applyResult: Bool) -> Task<Config, Error> {
    if let request = self.request {
      if applyResult { self.request?.appliesResult = true }
      return request.task
    }
    let id = UUID()
    let load = self.load
    let task = Task { [self] in
      defer { if self.request?.id == id { self.request = nil } }
      try Task.checkCancellation()
      let value = try await load()
      try Task.checkCancellation()
      guard let request = self.request, request.id == id else { throw CancellationError() }
      let config = self.retainingDebugFeatureFlags(value)
      if request.appliesResult { self.applyConfiguration(config) }
      return config
    }
    self.request = (id, task, applyResult)
    return task
  }

  public func reset() {
    self.request?.task.cancel()
    self.request = nil
  }

  private func retainingDebugFeatureFlags(_ config: Config) -> Config {
    let stored = self.debugFeatureFlags().filter { config.features[$0.key] != nil }
    return config |> Config.lens.features .~ config.features.withAllValuesFrom(stored)
  }
}
