import Foundation
import GraphAPI
import KsApi

@MainActor
public protocol ProjectReportingProvider {
  func fetchReportOptions() async throws -> [ReportProjectInfoListItem]
  func fetchReportingEmail() async throws -> String?
  func submitProjectReport(_ draft: ProjectReportingFeature.Draft) async throws
}

@MainActor
public struct AsyncProjectReportingProvider: ProjectReportingProvider {
  private let service: any ServiceType
  public init(service: any ServiceType) { self.service = service }
  public func fetchReportOptions() async throws -> [ReportProjectInfoListItem] {
    try await self.service.fetchProjectFlaggingOptions()
  }
  public func fetchReportingEmail() async throws -> String? { try await self.service.reportingEmail() }
  public func submitProjectReport(_ draft: ProjectReportingFeature.Draft) async throws {
    try await self.service.submitProjectReport(input: CreateFlaggingInput(
      contentId: draft.projectID, kind: draft.kind, details: draft.details, clientMutationId: nil
    ))
  }
}

/// Reporting reads follow the screen task's lifetime. Admitted submissions belong
/// to this Feature: dismissing a form cannot undo a report accepted by the server.
@MainActor
public final class ProjectReportingFeature {
  public struct Context: Hashable {
    fileprivate let userID: Int?
    fileprivate let generation: Int
  }
  public struct Draft: Equatable {
    public let projectID: String
    public let kind: GraphAPI.NonDeprecatedFlaggingKind
    public let details: String
    public init(projectID: String, kind: GraphAPI.NonDeprecatedFlaggingKind, details: String) {
      self.projectID = projectID
      self.kind = kind
      self.details = details
    }
  }
  private struct Pending {
    let id: UUID
    let draft: Draft
    let task: Task<Void, Error>
  }
  public let sessionFeature: SessionFeature
  private let makeProvider: () -> any ProjectReportingProvider
  private var latestQueuedReportBySession: [Context: Pending] = [:]
  private var reportSubmissionTasks: [UUID: Task<Void, Error>] = [:]

  public init(sessionFeature: SessionFeature, makeProvider: @escaping () -> any ProjectReportingProvider) {
    self.sessionFeature = sessionFeature
    self.makeProvider = makeProvider
  }

  public var currentReportingContext: Context {
    Context(userID: self.sessionFeature.currentUser?.id, generation: self.sessionFeature.generation)
  }
  public func ensureReportingSessionIsCurrent(_ context: Context) throws {
    try Task.checkCancellation()
    guard self.currentReportingContext == context else { throw CancellationError() }
  }
  public func fetchReportOptions(context: Context) async throws -> [ReportProjectInfoListItem] {
    try self.ensureReportingSessionIsCurrent(context)
    do {
      let reportOptions = try await self.makeProvider().fetchReportOptions()
      try self.ensureReportingSessionIsCurrent(context)
      return reportOptions
    } catch {
      try self.ensureReportingSessionIsCurrent(context)
      throw error
    }
  }
  public func fetchReportingEmail(context: Context) async throws -> String? {
    try self.ensureReportingSessionIsCurrent(context)
    do {
      let reportingEmail = try await self.makeProvider().fetchReportingEmail()
      try self.ensureReportingSessionIsCurrent(context)
      return reportingEmail
    } catch {
      try self.ensureReportingSessionIsCurrent(context)
      throw error
    }
  }

  /// Equivalent pending submissions share; changed reports execute in account
  /// order. Failures are surfaced for an explicit retry, never retried silently.
  public func submitProjectReport(_ draft: Draft, context: Context) throws -> Task<Void, Error> {
    try self.ensureReportingSessionIsCurrent(context)
    guard !draft.projectID.isEmpty, !draft.details.isEmpty else { throw ErrorEnvelope.couldNotParseJSON }
    let previous = self.latestQueuedReportBySession[context]
    if let previous, previous.draft == draft { return previous.task }
    let id = UUID()
    let provider = self.makeProvider()
    let task = Task { [self] in
      defer {
        self.reportSubmissionTasks[id] = nil
        if self.latestQueuedReportBySession[context]?.id == id { self.latestQueuedReportBySession[context] = nil }
      }
      if let previous { _ = await previous.task.result }
      try self.ensureReportingSessionIsCurrent(context)
      do {
        try await provider.submitProjectReport(draft)
        try self.ensureReportingSessionIsCurrent(context)
      } catch {
        try self.ensureReportingSessionIsCurrent(context)
        throw error
      }
    }
    self.latestQueuedReportBySession[context] = Pending(id: id, draft: draft, task: task)
    self.reportSubmissionTasks[id] = task
    return task
  }

  public func waitForReportSubmissions() async {
    while !self.reportSubmissionTasks.isEmpty {
      for task in Array(self.reportSubmissionTasks.values) { _ = await task.result }
    }
  }
}
