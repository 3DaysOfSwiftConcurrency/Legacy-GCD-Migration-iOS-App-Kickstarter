@testable import Kickstarter_iOS
@testable import KsApi

import Prelude
import XCTest

@MainActor
final class CreatorDraftsFeatureTests: XCTestCase {
  private var provider: ControlledCreatorDraftsProvider!
  private var feature: CreatorDraftsFeature!
  private let route = UUID()

  override func setUp() async throws {
    try await super.setUp()
    let provider = ControlledCreatorDraftsProvider()
    self.provider = provider
    self.feature = CreatorDraftsFeature(
      sessionFeature: SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) }),
      makeProvider: { provider }, sleep: { _ in }
    )
    await self.feature.loadDraft(project: .template, route: self.route)
  }
  override func tearDown() async throws {
    self.feature.resetForSessionChange()
    self.provider.loads.releaseAll()
    self.provider.saves.releaseAll()
    self.provider.adds.releaseAll()
    self.provider.removes.releaseAll()
    await self.feature.waitForDraftOperations()
    try await super.tearDown()
  }
  private func save(_ title: String) -> Task<UpdateDraft, Error> {
    Task { try await self.feature.saveDraft(route: self.route, title: title, body: "Body", isPublic: false) }
  }

  func testReadsAndWritesUseComposedResponseDelay() async throws {
    let provider = ControlledCreatorDraftsProvider()
    defer {
      provider.loads.releaseAll()
      provider.saves.releaseAll()
    }
    var sleeps: [TimeInterval] = []
    let feature = CreatorDraftsFeature(
      sessionFeature: SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) }),
      makeProvider: { provider },
      responseDelaySeconds: { 7 },
      sleep: { sleeps.append($0) }
    )
    let route = UUID()

    await feature.loadDraft(project: .template, route: route)
    let save = Task {
      try await feature.saveDraft(route: route, title: "Delayed", body: "Body", isPublic: false)
    }
    await provider.saves.waitFor(1)
    try provider.saves.finish(0, .success(.template))
    _ = try await save.value

    XCTAssertEqual(sleeps, [7, 7])
  }

  func testEquivalentSavesShareAndDifferentFieldsExecuteInOrder() async throws {
    let first = self.save("First")
    let duplicate = self.save("First")
    let second = self.save("Second")
    await self.provider.saves.waitFor(1)
    XCTAssertEqual(self.provider.titles, ["First"])
    try self.provider.saves.finish(0, .success(.template |> UpdateDraft.lens.update.title .~ "First"))
    await self.provider.saves.waitFor(2)
    XCTAssertEqual(self.provider.titles, ["First", "Second"])
    XCTAssertEqual(self.provider.savedDrafts[1].update.title, "First")
    try self.provider.saves.finish(1, .success(.template |> UpdateDraft.lens.update.title .~ "Second"))
    _ = try await first.value
    _ = try await duplicate.value
    _ = try await second.value
  }

  func testUploadSettlesBeforeSaveAndSaveUsesCurrentImages() async throws {
    let upload = Task { try await self.feature.uploadDraftImage(file: URL(fileURLWithPath: "/tmp/test.png"), route: self.route) }
    await self.provider.adds.waitFor(1)
    let save = self.save("After upload")
    XCTAssertEqual(self.provider.saves.count, 0)
    try self.provider.adds.finish(0, .success(.template))
    await self.provider.saves.waitFor(1)
    XCTAssertEqual(self.provider.savedDrafts.first?.images.map(\.id), [UpdateDraft.Image.template.id])
    try self.provider.saves.finish(0, .success(self.provider.savedDrafts[0]))
    _ = try await upload.value
    _ = try await save.value
  }

  func testFailureDoesNotBlockFollowingEditAndRetryIsExplicit() async throws {
    let first = self.save("First")
    let second = self.save("Second")
    await self.provider.saves.waitFor(1)
    try self.provider.saves.finish(0, .failure(ErrorEnvelope.couldNotParseJSON))
    await self.provider.saves.waitFor(2)
    try self.provider.saves.finish(1, .success(.template))
    do { _ = try await first.value; XCTFail("Expected failure") } catch { XCTAssertTrue(error is ErrorEnvelope) }
    _ = try await second.value
    XCTAssertEqual(self.provider.saves.count, 2)
  }

  func testScreenReleaseSuppressesDeliveryButAdmittedSaveSettles() async throws {
    let save = self.save("First")
    await self.provider.saves.waitFor(1)
    self.feature.release(route: self.route)
    try self.provider.saves.finish(0, .success(.template))
    do { _ = try await save.value; XCTFail("Released screen received result") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(self.provider.saves.count, 1)
  }

  func testSessionChangeSuppressesOutcomeAndQueuedMutation() async throws {
    let first = self.save("First")
    let second = self.save("Second")
    await self.provider.saves.waitFor(1)
    self.feature.sessionFeature.sessionChanged()
    try self.provider.saves.finish(0, .success(.template))
    for task in [first, second] {
      do { _ = try await task.value; XCTFail("Old session received result") }
      catch { XCTAssertTrue(error is CancellationError) }
    }
    XCTAssertEqual(self.provider.saves.count, 1)
  }

  func testReplacedReadRejectsLateSuccess() async throws {
    self.provider.pauseLoad = true
    var loaded: [String] = []
    self.feature.observe(route: self.route) { event in
      if case let .load(.success(draft)) = event { loaded.append(draft.update.title) }
    }
    let first = self.feature.startDraftLoad(project: .template, route: self.route)
    await self.provider.loads.waitFor(1)
    let second = self.feature.startDraftLoad(project: .template |> Project.lens.id .~ 2, route: self.route)
    await self.provider.loads.waitFor(2)
    try self.provider.loads.finish(1, .success(.template |> UpdateDraft.lens.update.title .~ "Current"))
    await second.value
    try self.provider.loads.finish(0, .success(.template |> UpdateDraft.lens.update.title .~ "Obsolete"))
    await first.value
    XCTAssertEqual(loaded, ["Current"])
  }

  func testResetKeepsOpenRouteListenerForNextLoad() async {
    var loadCount = 0
    self.feature.observe(route: self.route) { event in
      if case .load(.success) = event { loadCount += 1 }
    }
    self.feature.resetForSessionChange()
    await self.feature.loadDraft(project: .template, route: self.route)
    XCTAssertEqual(loadCount, 1)
  }

  func testUnchangedDraftDoesNotSendWrite() async throws {
    let draft = UpdateDraft.template
    let saved = try await self.feature.saveDraft(route: self.route, title: draft.update.title,
      body: draft.update.body ?? "", isPublic: draft.update.isPublic)
    XCTAssertEqual(saved.update.title, draft.update.title)
    XCTAssertEqual(self.provider.saves.count, 0)
  }

  func testUnsupportedVideoRemovalUsesFailureOutput() async {
    let vm = UpdateDraftViewModel(creatorDraftsFeature: self.feature)
    var failed = false
    vm.onEvent = { if case .showRemoveAttachmentFailure = $0 { failed = true } }
    vm.configureWith(project: .template)
    vm.viewDidLoad()
    await vm.waitForPending()
    vm.remove(attachment: .video(.template))
    XCTAssertTrue(failed)
    XCTAssertEqual(self.provider.removes.count, 0)
  }

  func testNewUploadDoesNotRestorePreviouslyDeletedImage() async throws {
    var lists: [[Int]] = []
    self.feature.observe(route: self.route) { event in
      if case let .attachments(attachments) = event { lists.append(attachments.map(\.id)) }
    }
    let first = Task { try await self.feature.uploadDraftImage(file: URL(fileURLWithPath: "/tmp/one.png"), route: self.route) }
    await self.provider.adds.waitFor(1)
    try self.provider.adds.finish(0, .success(.template))
    _ = try await first.value
    let removal = Task { try await self.feature.removeDraftImage(imageID: UpdateDraft.Image.template.id, route: self.route) }
    await self.provider.removes.waitFor(1)
    try self.provider.removes.finish(0, .success(.template))
    _ = try await removal.value
    let second = Task { try await self.feature.uploadDraftImage(file: URL(fileURLWithPath: "/tmp/two.png"), route: self.route) }
    await self.provider.adds.waitFor(2)
    try self.provider.adds.finish(1, .success(.template |> UpdateDraft.Image.lens.id .~ 2))
    _ = try await second.value
    XCTAssertEqual(lists, [[1], [], [2]])
  }

  func testPreviewThenCloseDoesNotNavigateWithEarlierSaveResponse() async throws {
    let vm = UpdateDraftViewModel(creatorDraftsFeature: self.feature)
    var previews = 0
    var dismissals = 0
    vm.onEvent = { event in
      switch event {
      case .goToPreview: previews += 1
      case .notifyPresenterViewControllerWantsDismissal: dismissals += 1
      default: break
      }
    }
    vm.configureWith(project: .template)
    vm.viewDidLoad()
    await vm.waitForPending()
    vm.titleTextChanged(to: "Preview version")
    vm.previewButtonTapped()
    await self.provider.saves.waitFor(1)
    vm.titleTextChanged(to: "Close version")
    vm.closeButtonTapped()
    try self.provider.saves.finish(0, .success(.template |> UpdateDraft.lens.update.title .~ "Preview version"))
    await self.provider.saves.waitFor(2)
    XCTAssertEqual(previews, 0)
    XCTAssertEqual(dismissals, 0)
    try self.provider.saves.finish(1, .success(.template |> UpdateDraft.lens.update.title .~ "Close version"))
    await vm.waitForPending()
    XCTAssertEqual(previews, 0)
    XCTAssertEqual(dismissals, 1)
  }

}

@MainActor
private final class ControlledCreatorDraftsProvider: CreatorDraftsProvider {
  var pauseLoad = false
  let loads = AccountRequestGate<UpdateDraft>()
  let saves = AccountRequestGate<UpdateDraft>()
  let adds = AccountRequestGate<UpdateDraft.Image>()
  let removes = AccountRequestGate<UpdateDraft.Image>()
  var titles: [String] = []
  var savedDrafts: [UpdateDraft] = []
  func fetchDraft(project: Project) async throws -> UpdateDraft {
    if self.pauseLoad { return try await self.loads.request() }
    return .template
  }
  func saveDraft(draft: UpdateDraft, title: String, body: String, isPublic: Bool) async throws -> UpdateDraft {
    self.titles.append(title)
    self.savedDrafts.append(draft)
    return try await self.saves.request()
  }
  func uploadDraftImage(file: URL, draft: UpdateDraft) async throws -> UpdateDraft.Image { try await self.adds.request() }
  func removeDraftImage(image: UpdateDraft.Image, draft: UpdateDraft) async throws -> UpdateDraft.Image { try await self.removes.request() }
}
