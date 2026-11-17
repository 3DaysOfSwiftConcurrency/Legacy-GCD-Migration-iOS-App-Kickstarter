import Foundation
import GraphAPI
import KsApi

@MainActor
public protocol PledgeProvider {
  func projectForUpdate(_ param: Param) async throws -> Project
  func projectUpdate(_ id: Int, param: Param) async throws -> Update
  func confirmAddress(backingID: String, addressID: String) async throws -> Bool
  func receipt(backingID: String, received: Bool) async throws -> Bool
  func paymentPlan(slug: String, amount: String) async throws -> PledgePaymentPlan?
  func openCheckout(_ input: KsApi.CreateCheckoutInput) async throws -> CreateCheckoutEnvelope
  func validateCheckout(checkoutID: String, sourceID: String, secret: String) async throws
    -> ValidateCheckoutEnvelope
  func completeCheckout(_ input: GraphAPI.CompleteOnSessionCheckoutInput) async throws
  func project(_ param: Param) async throws -> Project
  func backing(_ id: Int) async throws -> Backing

  func create(_ input: KsApi.CreateBackingInput) async throws -> CreateBackingEnvelope
  func update(_ input: KsApi.UpdateBackingInput) async throws -> UpdateBackingEnvelope
  func cancel(_ input: KsApi.CancelBackingInput) async throws
  func received(projectID: Int, userID: Int, received: Bool) async throws -> Backing
}

@MainActor
public struct AsyncPledgeProvider: PledgeProvider {
  private let service: any ServiceType
  public init(service: any ServiceType) { self.service = service }
  public func projectForUpdate(_ param: Param) async throws -> Project {
    try await self.service.discussionProject(param: param)
  }
  public func projectUpdate(_ id: Int, param: Param) async throws -> Update {
    try await self.service.projectUpdate(id: id, project: param)
  }
  public func confirmAddress(backingID: String, addressID: String) async throws -> Bool {
    try await self.service.confirmPledgeAddress(backingID: backingID, addressID: addressID)
  }
  public func receipt(backingID: String, received: Bool) async throws -> Bool {
    try await self.service.setPledgeReceipt(backingID: backingID, received: received)
  }
  public func paymentPlan(slug: String, amount: String) async throws
    -> PledgePaymentPlan?
  {
    try await self.service.pledgePaymentPlan(slug: slug, amount: amount)
  }
  public func openCheckout(_ input: KsApi.CreateCheckoutInput) async throws
    -> CreateCheckoutEnvelope
  {
    try await self.service.openPledgeCheckout(input)
  }
  public func validateCheckout(checkoutID: String, sourceID: String, secret: String) async throws
    -> ValidateCheckoutEnvelope
  {
    try await self.service.checkPledgeCheckout(
      checkoutID: checkoutID, sourceID: sourceID, secret: secret)
  }
  public func completeCheckout(_ input: GraphAPI.CompleteOnSessionCheckoutInput) async throws
  {
    try await self.service.finishPledgeCheckout(input)
  }
  public func backing(_ id: Int) async throws -> Backing {
    try await self.service.managedPledgeBacking(id: id)
  }
  public func project(_ param: Param) async throws -> Project {
    var project = try await self.service.discussionProject(param: param)
    try Task.checkCancellation()
    let extras = try await self.service.managedPledgeRewards(projectID: project.id)
    // Retain the existing first reward (the no-reward choice), then the GraphQL rewards.
    project.rewardData.rewards = Array(project.rewardData.rewards.prefix(1)) + extras.rewards
    project.isPledgeOverTimeAllowed = extras.isPledgeOverTimeAllowed
    project.pledgeOverTimeCollectionPlanChargeExplanation =
      extras.pledgeOverTimeCollectionPlanChargeExplanation
    project.pledgeOverTimeCollectionPlanChargedAsNPayments =
      extras.pledgeOverTimeCollectionPlanChargedAsNPayments
    project.pledgeOverTimeCollectionPlanShortPitch = extras.pledgeOverTimeCollectionPlanShortPitch
    project.pledgeOverTimeMinimumExplanation = extras.pledgeOverTimeMinimumExplanation
    return project
  }
  public func create(_ input: KsApi.CreateBackingInput) async throws -> CreateBackingEnvelope {
    try await self.service.submitPledge(input)
  }
  public func update(_ input: KsApi.UpdateBackingInput) async throws -> UpdateBackingEnvelope {
    try await self.service.revisePledge(input)
  }
  public func cancel(_ input: KsApi.CancelBackingInput) async throws {
    try await self.service.cancelPledge(input)
  }
  public func received(projectID: Int, userID: Int, received: Bool) async throws -> Backing {
    try await self.service.markPledgeReceived(
      projectID: projectID, userID: userID, received: received)
  }
}

/// Owns admitted pledge mutations independently of screen observation.
/// One account's distinct commands execute in admission order, including across
/// create/update/cancel screens. There is no automatic retry of a financial write.
@MainActor
public final class PledgeFeature {
  public struct Platform {
    let serverConfig: @MainActor () -> any ServerConfigType
    let prepareWebRequest: @MainActor (URLRequest) -> URLRequest
    let isPreparedWebRequest: @MainActor (URLRequest) -> Bool
    let responseDelaySeconds: @MainActor () -> TimeInterval
    let sleep: @MainActor (TimeInterval) async throws -> Void

    public init(
      serverConfig: @escaping @MainActor () -> any ServerConfigType,
      prepareWebRequest: @escaping @MainActor (URLRequest) -> URLRequest,
      isPreparedWebRequest: @escaping @MainActor (URLRequest) -> Bool,
      responseDelaySeconds: @escaping @MainActor () -> TimeInterval,
      sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { delay in
        if delay.isInfinite { try await Task.sleep(nanoseconds: UInt64.max) }
        else if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
      }
    ) {
      self.serverConfig = serverConfig
      self.prepareWebRequest = prepareWebRequest
      self.isPreparedWebRequest = isPreparedWebRequest
      self.responseDelaySeconds = responseDelaySeconds
      self.sleep = sleep
    }
  }

  private let sessionFeature: SessionFeature
  private let settingsFeature: SettingsFeature
  private let makeProvider: () -> any PledgeProvider
  private let platform: Platform
  private let trackRewardReceivedToggle: @MainActor (Bool, Project) -> Void

  public init(
    platform: Platform,
    sessionFeature: SessionFeature,
    settingsFeature: SettingsFeature,
    makeProvider: @escaping () -> any PledgeProvider,
    trackRewardReceivedToggle: @escaping @MainActor (Bool, Project) -> Void = { _, _ in }
  ) {
    self.sessionFeature = sessionFeature
    self.settingsFeature = settingsFeature
    self.makeProvider = makeProvider
    self.platform = platform
    self.trackRewardReceivedToggle = trackRewardReceivedToggle
  }

  public func preparedWebRequest(from request: URLRequest) -> URLRequest { self.platform.prepareWebRequest(request) }
  public func isPreparedWebRequest(_ request: URLRequest) -> Bool { self.platform.isPreparedWebRequest(request) }
  public func isKickstarterWebRequest(_ request: URLRequest) -> Bool {
    request.url?.host() == self.platform.serverConfig().webBaseUrl.host()
  }
  public func navigationMatch(_ request: URLRequest) -> Navigation? {
    let config = self.platform.serverConfig()
    return request.url.flatMap { Navigation.match($0, apiBaseURL: config.apiBaseUrl, webBaseURL: config.webBaseUrl) }
  }
  public func helpType(for url: URL) -> HelpType? {
    HelpType.helpType(from: url, baseURL: self.platform.serverConfig().webBaseUrl)
  }
  public func helpURL(_ type: HelpType) -> String? {
    type.url(withBaseUrl: self.platform.serverConfig().webBaseUrl)?.absoluteString
  }

  struct SessionIdentity: Hashable, Sendable {
    let userID: Int?
    let generation: Int
  }
  var sessionIdentity: SessionIdentity {
    SessionIdentity(userID: self.sessionFeature.currentUser?.id, generation: self.sessionFeature.generation)
  }
  var requiresPledgeManagerSignIn: Bool { self.sessionFeature.currentUser == nil }
  var allowsUnrecognizedPledgeManagerNavigation: Bool {
    self.settingsFeature.isRemoteConfigurationEnabled(.bypassPledgeManagerDecisionPolicy)
  }

  func viewerIsCreator(of project: Project) -> Bool {
    currentUserIsCreator(of: project, currentUser: self.sessionFeature.currentUser)
  }

  enum SummaryViewer {
    case guest
    case other
    case backer(name: String, avatarURL: URL?)
  }

  func summaryViewer(backerID: Int) -> SummaryViewer {
    guard let user = self.sessionFeature.currentUser else { return .guest }
    guard user.id == backerID else { return .other }
    return .backer(name: user.name, avatarURL: URL(string: user.avatar.small))
  }

  private func requireCurrent(_ session: SessionIdentity) throws {
    try Task.checkCancellation()
    guard self.sessionIdentity == session else { throw CancellationError() }
  }

  private enum Command: Equatable {
    case confirmAddress(String, String)
    case receipt(String, Bool)
    case openCheckout(KsApi.CreateCheckoutInput)
    case validateCheckout(checkoutID: String, sourceID: String, secret: String)
    case completeCheckout(GraphAPI.CompleteOnSessionCheckoutInput)
    case create(KsApi.CreateBackingInput)
    case update(KsApi.UpdateBackingInput)
    case cancel(KsApi.CancelBackingInput)
    case received(projectID: Int, userID: Int, received: Bool)
  }
  private enum Value {
    case acknowledged(Bool)
    case checkout(CreateCheckoutEnvelope)
    case validated(ValidateCheckoutEnvelope)
    case completed
    case created(CreateBackingEnvelope)
    case updated(UpdateBackingEnvelope)
    case canceled
    case received(Backing)
  }
  private struct Pending {
    let id: UUID
    let command: Command
    let task: Task<Value, Error>
  }
  private var writeVersion: [SessionIdentity: Int] = [:]
  private var tails: [SessionIdentity: Pending] = [:]
  private var commands: [UUID: Task<Value, Error>] = [:]

  private func request(_ command: Command) -> Task<Value, Error> {
    let session = self.sessionIdentity
    let previous = self.tails[session]
    if let previous, previous.command == command { return previous.task }
    self.writeVersion[session, default: 0] += 1
    let id = UUID()
    let provider = self.makeProvider()
    let task = Task { [self] in
      defer {
        self.commands[id] = nil
        if self.tails[session]?.id == id { self.tails[session] = nil }
      }
      if let previous { _ = await previous.task.result }
      try self.requireCurrent(session)
      do {
        let value: Value
        switch command {
        case .confirmAddress(let backingID, let addressID):
          value = .acknowledged(
            try await provider.confirmAddress(backingID: backingID, addressID: addressID))
        case .receipt(let backingID, let received):
          value = .acknowledged(
            try await provider.receipt(backingID: backingID, received: received))
        case .openCheckout(let input): value = .checkout(try await provider.openCheckout(input))
        case .validateCheckout(let checkoutID, let sourceID, let secret):
          value = .validated(
            try await provider.validateCheckout(
              checkoutID: checkoutID, sourceID: sourceID, secret: secret))
        case .completeCheckout(let input):
          try await provider.completeCheckout(input)
          value = .completed
        case .create(let input): value = .created(try await provider.create(input))
        case .update(let input): value = .updated(try await provider.update(input))
        case .cancel(let input):
          try await provider.cancel(input)
          value = .canceled
        case .received(let projectID, let userID, let received):
          value = .received(
            try await provider.received(projectID: projectID, userID: userID, received: received))
        }
        try self.requireCurrent(session)
        return value
      } catch {
        try self.requireCurrent(session)
        throw error
      }
    }
    self.tails[session] = Pending(id: id, command: command, task: task)
    self.commands[id] = task
    return task
  }

  private func awaitAdmitted(_ command: Task<Value, Error>, session: SessionIdentity) async throws -> Value {
    do {
      let value = try await command.value
      try self.requireCurrent(session)
      return value
    } catch {
      try self.requireCurrent(session)
      throw error
    }
  }

  private func execute(_ command: Command) async throws -> Value {
    try Task.checkCancellation()
    let session = self.sessionIdentity
    do {
      let value = try await self.request(command).value
      try self.requireCurrent(session)
      return value
    } catch {
      try self.requireCurrent(session)
      throw error
    }
  }

  public func confirmAddress(backingID: String, addressID: String) async throws -> Bool {
    try Self.acknowledged(await self.execute(.confirmAddress(backingID, addressID)))
  }
  public func receipt(backingID: String, received: Bool) async throws -> Bool {
    try Self.acknowledged(await self.execute(.receipt(backingID, received)))
  }
  private static func acknowledged(_ value: Value) throws -> Bool {
    guard case .acknowledged(let success) = value else { throw ErrorEnvelope.couldNotParseJSON }
    return success
  }

  public func create(_ input: KsApi.CreateBackingInput) async throws -> CreateBackingEnvelope {
    try Self.created(await self.execute(.create(input)))
  }
  func startCreate(_ data: CreateBackingData, isApplePay: Bool) -> Task<CreateBackingEnvelope, Error> {
    self.startCreate(CreateBackingInput.input(from: data, isApplePay: isApplePay))
  }

  func startCreate(_ input: KsApi.CreateBackingInput) -> Task<CreateBackingEnvelope, Error> {
    let session = self.sessionIdentity
    let command = self.request(.create(input))
    return Task {
      try Self.created(await self.awaitAdmitted(command, session: session))
    }
  }

  public func update(_ input: KsApi.UpdateBackingInput) async throws -> UpdateBackingEnvelope {
    try Self.updated(await self.execute(.update(input)))
  }
  func startUpdate(_ data: UpdateBackingData, isApplePay: Bool) -> Task<UpdateBackingEnvelope, Error> {
    self.startUpdate(UpdateBackingInput.input(from: data, isApplePay: isApplePay))
  }

  func startUpdate(_ input: KsApi.UpdateBackingInput) -> Task<UpdateBackingEnvelope, Error> {
    let session = self.sessionIdentity
    let command = self.request(.update(input))
    return Task {
      try Self.updated(await self.awaitAdmitted(command, session: session))
    }
  }

  public func cancel(_ input: KsApi.CancelBackingInput) async throws {
    _ = try await self.execute(.cancel(input))
  }
  /// Keep the existing presentation delay and suppress results from a replaced session.
  func cancelWithPresentationDelay(_ input: KsApi.CancelBackingInput) async throws {
    let session = self.sessionIdentity
    let delay = self.platform.responseDelaySeconds()
    let result: Result<Void, Error>
    do { try await self.cancel(input); result = .success(()) }
    catch { result = .failure(error) }
    try await self.platform.sleep(delay)
    try self.requireCurrent(session)
    try result.get()
  }
  public func received(projectID: Int, userID: Int, received: Bool) async throws -> Backing {
    try Self.received(
      await self.execute(.received(projectID: projectID, userID: userID, received: received)))
  }

  /// Admit writes synchronously so rapid toggle changes keep their order even if
  /// their presentation tasks are cancelled.
  func startReceivedForCurrentUser(project: Project, received: Bool) -> Task<Backing, Error>? {
    guard let userID = self.sessionFeature.currentUser?.id else { return nil }
    self.trackRewardReceivedToggle(received, project)
    let session = self.sessionIdentity
    let delay = self.platform.responseDelaySeconds()
    let command = self.startReceived(projectID: project.id, userID: userID, received: received)
    return Task {
      let backing = try await command.value
      try await self.platform.sleep(delay)
      try self.requireCurrent(session)
      return backing
    }
  }

  func startReceived(projectID: Int, userID: Int, received: Bool) -> Task<Backing, Error> {
    let session = self.sessionIdentity
    let command = self.request(.received(projectID: projectID, userID: userID, received: received))
    return Task { try Self.received(await self.awaitAdmitted(command, session: session)) }
  }


  public func openCheckout(_ input: KsApi.CreateCheckoutInput) async throws
    -> CreateCheckoutEnvelope
  {
    try Self.checkout(await self.execute(.openCheckout(input)))
  }
  func startOpenCheckout(_ data: PledgeViewData) -> Task<CreateCheckoutEnvelope, Error> {
    let rewardIDs = data.rewards.first?.isNoReward == true ? [] : data.rewards.flatMap { reward in
      [String](repeating: reward.graphID, count: data.selectedQuantities[reward.id] ?? 0)
    }
    return self.startOpenCheckout(KsApi.CreateCheckoutInput(
      projectId: data.project.graphID,
      amount: String(format: "%.2f", PostCampaignAmounts(data).total),
      locationId: data.selectedShippingRule.map { String($0.location.id) },
      rewardIds: rewardIDs,
      refParam: data.refTag?.stringTag
    ))
  }

  static func checkoutID(from value: String) -> String {
    guard let decoded = decodeBase64(value), let range = decoded.range(of: "Checkout-") else { return value }
    return String(decoded[range.upperBound...])
  }

  func startOpenCheckout(_ input: KsApi.CreateCheckoutInput) -> Task<CreateCheckoutEnvelope, Error> {
    let session = self.sessionIdentity
    let command = self.request(.openCheckout(input))
    return Task {
      try Self.checkout(await self.awaitAdmitted(command, session: session))
    }
  }

  public func validateCheckout(checkoutID: String, sourceID: String, secret: String) async throws
    -> ValidateCheckoutEnvelope
  {
    try Self.validated(
      await self.execute(
        .validateCheckout(checkoutID: checkoutID, sourceID: sourceID, secret: secret)))
  }
  func startValidateCheckout(checkoutID: String, sourceID: String, secret: String)
    -> Task<ValidateCheckoutEnvelope, Error>
  {
    let session = self.sessionIdentity
    let command = self.request(.validateCheckout(checkoutID: checkoutID, sourceID: sourceID, secret: secret))
    return Task {
      try Self.validated(await self.awaitAdmitted(command, session: session))
    }
  }

  struct CheckoutCompletion {
    enum Payment {
      case applePay
      case card(savedID: String?)
    }

    let checkoutID: String
    let clientSecret: String
    let payment: Payment
  }

  func startCompleteCheckout(_ completion: CheckoutCompletion) -> Task<Void, Error> {
    let sourceID: GraphQLNullable<String>
    let reusable: Bool
    switch completion.payment {
    case .applePay:
      sourceID = nil
      reusable = false
    case let .card(savedID):
      sourceID = GraphQLNullable.someOrNil(savedID)
      reusable = true
    }

    return self.startCompleteCheckout(GraphAPI.CompleteOnSessionCheckoutInput(
      checkoutId: encodeToBase64("Checkout-\(completion.checkoutID)"),
      paymentIntentClientSecret: completion.clientSecret,
      paymentSourceId: sourceID,
      paymentSourceReusable: .some(reusable),
      applePay: nil
    ))
  }

  func startCompleteCheckout(_ input: GraphAPI.CompleteOnSessionCheckoutInput) -> Task<Void, Error> {
    let session = self.sessionIdentity
    let command = self.request(.completeCheckout(input))
    return Task {
      try Self.completed(await self.awaitAdmitted(command, session: session))
    }
  }

  public func completeCheckout(_ input: GraphAPI.CompleteOnSessionCheckoutInput) async throws
  {
    try Self.completed(await self.execute(.completeCheckout(input)))
  }
  private static func checkout(_ value: Value) throws -> CreateCheckoutEnvelope {
    guard case .checkout(let envelope) = value else { throw ErrorEnvelope.couldNotParseJSON }
    return envelope
  }
  private static func validated(_ value: Value) throws -> ValidateCheckoutEnvelope {
    guard case .validated(let envelope) = value else { throw ErrorEnvelope.couldNotParseJSON }
    return envelope
  }
  private static func completed(_ value: Value) throws
  {
    guard case .completed = value else { throw ErrorEnvelope.couldNotParseJSON }
  }

  private static func created(_ value: Value) throws -> CreateBackingEnvelope {
    guard case .created(let envelope) = value else { throw ErrorEnvelope.couldNotParseJSON }
    return envelope
  }
  private static func updated(_ value: Value) throws -> UpdateBackingEnvelope {
    guard case .updated(let envelope) = value else { throw ErrorEnvelope.couldNotParseJSON }
    return envelope
  }
  private static func received(_ value: Value) throws -> Backing {
    guard case .received(let backing) = value else { throw ErrorEnvelope.couldNotParseJSON }
    return backing
  }

  private enum Read: Equatable {
    case updateContext(Param, Int)
    case plan(String, String)
    case project(Param)
    case backing(Int)
  }
  private enum ReadValue {
    case updateContext(Project, Update)
    case plan(PledgePaymentPlan?)
    case project(Project)
    case backing(Backing)
  }
  // Mixed project/update values remain on MainActor. The task transports only
  // completion; shared waiters inspect this actor-owned result after it finishes.
  @MainActor private final class ReadOutcome {
    var result: Result<ReadValue, Error>?
  }
  @MainActor private struct PendingRead {
    let id: UUID
    let input: Read
    let version: Int
    let session: SessionIdentity
    let task: Task<Void, Never>
    let outcome: ReadOutcome

    func value() async throws -> ReadValue {
      await self.task.value
      guard let result = self.outcome.result else { throw ErrorEnvelope.couldNotParseJSON }
      return try result.get()
    }
  }
  private var reads: [UUID: PendingRead] = [:]
  private var readVersions: [UUID: UUID] = [:]
  private var readTasks: [UUID: Task<Void, Never>] = [:]

  private func requestRead(route: UUID, input: Read) -> PendingRead {
    let session = self.sessionIdentity
    let version = self.writeVersion[session, default: 0]
    if let pending = self.reads[route], pending.input == input, pending.session == session,
      pending.version == version
    {
      return pending
    }
    self.reads[route]?.task.cancel()
    let id = UUID()
    let provider = self.makeProvider()
    let precedingWrite = self.tails[session]?.task
    let outcome = ReadOutcome()
    let task = Task { [self] in
      defer {
        self.readTasks[id] = nil
        if self.reads[route]?.id == id { self.reads[route] = nil }
      }
      do {
        // A refresh must not overtake a write that the screen has already admitted.
        if let precedingWrite { _ = await precedingWrite.result }
        try self.requireCurrent(session)
        let value: ReadValue
        switch input {
        case .updateContext(let param, let updateID):
          let project = try await provider.projectForUpdate(param)
          try self.requireCurrent(session)
          let update = try await provider.projectUpdate(updateID, param: param)
          value = .updateContext(project, update)
        case .plan(let slug, let amount):
          value = .plan(try await provider.paymentPlan(slug: slug, amount: amount))
        case .project(let param): value = .project(try await provider.project(param))
        case .backing(let id): value = .backing(try await provider.backing(id))
        }
        try self.requireCurrent(session)
        outcome.result = .success(value)
      } catch {
        outcome.result = .failure(
          Task.isCancelled || self.sessionIdentity != session ? CancellationError() : error)
      }
    }
    let pending = PendingRead(
      id: id, input: input, version: version, session: session, task: task, outcome: outcome)
    self.readVersions[route] = id
    self.reads[route] = pending
    self.readTasks[id] = task
    return pending
  }

  /// A web-to-native update destination is one coherent read. Replacing or
  /// closing the route invalidates both stages, including a late project result.
  public func updateContext(route: UUID, param: Param, updateID: Int) async throws -> (
    Project, Update
  ) {
    try Task.checkCancellation()
    let session = self.sessionIdentity
    do {
      let request = self.requestRead(route: route, input: .updateContext(param, updateID))
      let version = self.readVersions[route]
      let value = try await request.value()
      try self.requireCurrent(session)
      guard self.readVersions[route] == version else { throw CancellationError() }
      return try Self.updateContext(value)
    } catch {
      try self.requireCurrent(session)
      throw error
    }
  }
  private static func updateContext(_ value: ReadValue) throws -> (Project, Update) {
    guard case .updateContext(let project, let update) = value else {
      throw ErrorEnvelope.couldNotParseJSON
    }
    return (project, update)
  }

  func requestPaymentPlan(route: UUID, slug: String, amount: String) -> Task<PledgePaymentPlan?, Error> {
    let session = self.sessionIdentity
    let request = self.requestRead(route: route, input: .plan(slug, amount))
    let version = self.readVersions[route]
    return Task {
      do {
        let value = try await request.value()
        try self.requireCurrent(session)
        guard self.readVersions[route] == version else { throw CancellationError() }
        return try Self.plan(value)
      } catch {
        try self.requireCurrent(session)
        throw error
      }
    }
  }

  public func paymentPlan(route: UUID, slug: String, amount: String) async throws -> PledgePaymentPlan? {
    try Task.checkCancellation()
    let command = self.requestPaymentPlan(route: route, slug: slug, amount: amount)
    let result = try await command.value
    try Task.checkCancellation()
    return result
  }
  private static func plan(_ value: ReadValue) throws -> PledgePaymentPlan? {
    guard case .plan(let data) = value else { throw ErrorEnvelope.couldNotParseJSON }
    return data
  }
  public func project(route: UUID, param: Param) async throws -> Project {
    try Task.checkCancellation()
    let session = self.sessionIdentity
    do {
      let request = self.requestRead(route: route, input: .project(param))
      let version = self.readVersions[route]
      let value = try await request.value()
      try self.requireCurrent(session)
      guard self.readVersions[route] == version else { throw CancellationError() }
      return try Self.project(value)
    } catch {
      try self.requireCurrent(session)
      throw error
    }
  }
  public func backing(route: UUID, id: Int) async throws -> Backing {
    try Task.checkCancellation()
    let session = self.sessionIdentity
    do {
      let request = self.requestRead(route: route, input: .backing(id))
      let version = self.readVersions[route]
      let value = try await request.value()
      try self.requireCurrent(session)
      guard self.readVersions[route] == version else { throw CancellationError() }
      return try Self.backing(value)
    } catch {
      try self.requireCurrent(session)
      throw error
    }
  }
  private static func project(_ value: ReadValue) throws -> Project {
    guard case .project(let project) = value else { throw ErrorEnvelope.couldNotParseJSON }
    return project
  }
  private static func backing(_ value: ReadValue) throws -> Backing {
    guard case .backing(let backing) = value else { throw ErrorEnvelope.couldNotParseJSON }
    return backing
  }
  public func releaseRead(route: UUID) {
    self.readVersions[route] = nil
    self.reads.removeValue(forKey: route)?.task.cancel()
  }

  public func reset() {
    for pending in self.reads.values { pending.task.cancel() }
    self.reads.removeAll()
    self.readVersions.removeAll()
    self.writeVersion.removeAll()
    // In-flight writes settle. Old queued writes fail their generation check
    // before provider admission; a new account has its own queue.
  }
  public func waitForOperations() async {
    while !self.commands.isEmpty || !self.readTasks.isEmpty {
      for task in Array(self.readTasks.values) { await task.value }
      for task in Array(self.commands.values) { _ = await task.result }
    }
  }
}
