@testable import Kickstarter_iOS
@testable import KsApi
import Foundation

import XCTest

@MainActor
final class SessionFeatureTests: XCTestCase {
  func testDeviceTokensDebounceAndRegisterTheLatestHexValue() async throws {
    let provider = ControlledSessionProvider()
    defer { provider.releaseAll() }
    let feature = SessionFeature(
      makeProvider: { provider }, deviceRegistrationDebounce: {}, currentUser: { .template }
    )
    var delivered: [String] = []

    feature.receiveDeviceToken(Data([0x01, 0xff])) { delivered.append($0) }
    feature.receiveDeviceToken(Data([0x00, 0x0a, 0xbe])) { delivered.append($0) }
    XCTAssertTrue(provider.registeredTokens.isEmpty)
    await provider.registrations.waitFor(1)
    XCTAssertEqual(provider.registeredTokens, ["000abe"])
    try provider.registrations.finish(0, .success(()))
    await feature.waitForDeviceRegistration()
    XCTAssertEqual(delivered, ["000abe"])
  }

  func testSessionChangePreventsDebouncedDeviceRegistration() async throws {
    let provider = ControlledSessionProvider()
    let debounce = AccountRequestGate<Void>()
    defer { provider.releaseAll(); debounce.releaseAll() }
    let feature = SessionFeature(
      makeProvider: { provider }, deviceRegistrationDebounce: { try await debounce.request() },
      currentUser: { .template }
    )

    feature.receiveDeviceToken(Data([0x01])) { _ in XCTFail("Obsolete registration delivered") }
    await debounce.waitFor(1)
    feature.sessionChanged()
    try debounce.finish(0, .success(()))
    await feature.waitForDeviceRegistration()
    XCTAssertTrue(provider.registeredTokens.isEmpty)
  }

  func testDuplicateDeviceTokensShareAndChangedTokensExecuteInOrderAfterFailure() async throws {
    let provider = ControlledSessionProvider()
    defer { provider.releaseAll() }
    let feature = SessionFeature(makeProvider: { provider }, currentUser: { .template })
    let first = feature.requestDeviceRegistration(token: "synthetic-a")
    let duplicate = feature.requestDeviceRegistration(token: "synthetic-a")
    let second = feature.requestDeviceRegistration(token: "synthetic-b")
    await provider.registrations.waitFor(1)
    XCTAssertEqual(provider.registeredTokens, ["synthetic-a"])
    try provider.registrations.finish(0, .failure(ErrorEnvelope.couldNotParseJSON))
    await provider.registrations.waitFor(2)
    try provider.registrations.finish(1, .success(()))
    for request in [first, duplicate] {
      do { _ = try await request.value; XCTFail("Registration failure was swallowed") }
      catch { XCTAssertTrue(error is ErrorEnvelope) }
    }
    let registered = try await second.value
    XCTAssertEqual(registered, "synthetic-b")
    XCTAssertEqual(provider.registeredTokens, ["synthetic-a", "synthetic-b"])
  }

  func testEquivalentDeviceRegistrationsShareSuccessfulCompletion() async throws {
    let provider = ControlledSessionProvider()
    defer { provider.releaseAll() }
    let feature = SessionFeature(makeProvider: { provider }, currentUser: { .template })
    let first = feature.requestDeviceRegistration(token: "synthetic-a")
    let duplicate = feature.requestDeviceRegistration(token: "synthetic-a")
    await provider.registrations.waitFor(1)
    try provider.registrations.finish(0, .success(()))
    for request in [first, duplicate] {
      let registered = try await request.value
      XCTAssertEqual(registered, "synthetic-a")
    }
    XCTAssertEqual(provider.registeredTokens, ["synthetic-a"])
  }

  func testSameUserSessionReplacementPreventsDeviceRequestAdmission() async {
    let provider = ControlledSessionProvider()
    defer { provider.releaseAll() }
    let feature = SessionFeature(makeProvider: { provider }, currentUser: { .template })
    let obsolete = feature.requestDeviceRegistration(token: "synthetic-a")
    feature.sessionChanged()
    guard case .failure(is CancellationError) = await obsolete.result else {
      return XCTFail("A previous session's device registration was admitted")
    }
    XCTAssertTrue(provider.registeredTokens.isEmpty)
  }

  func testSessionReplacementFinishesAdmittedDeviceWriteBeforeNewSessionAndSkipsOldQueue() async throws {
    let provider = ControlledSessionProvider()
    defer { provider.releaseAll() }
    let feature = SessionFeature(makeProvider: { provider }, currentUser: { .template })
    let admitted = feature.requestDeviceRegistration(token: "synthetic-a")
    await provider.registrations.waitFor(1)
    let queued = feature.requestDeviceRegistration(token: "synthetic-b")
    feature.sessionChanged()
    let current = feature.requestDeviceRegistration(token: "synthetic-c")
    XCTAssertEqual(provider.registeredTokens, ["synthetic-a"])

    try provider.registrations.finish(0, .success(()))
    for request in [admitted, queued] {
      guard case .failure(is CancellationError) = await request.result else {
        return XCTFail("An obsolete device registration published success")
      }
    }
    await provider.registrations.waitFor(2)
    XCTAssertEqual(provider.registeredTokens, ["synthetic-a", "synthetic-c"])
    XCTAssertEqual(provider.registrationWasCancelled, [false])
    try provider.registrations.finish(1, .success(()))
    let registered = try await current.value
    XCTAssertEqual(registered, "synthetic-c")
  }

  func testFailedDeviceRegistrationCanRetryTheSameToken() async throws {
    let provider = ControlledSessionProvider()
    defer { provider.releaseAll() }
    let feature = SessionFeature(makeProvider: { provider }, currentUser: { .template })
    let failed = feature.requestDeviceRegistration(token: "synthetic-a")
    await provider.registrations.waitFor(1)
    try provider.registrations.finish(0, .failure(ErrorEnvelope.couldNotParseJSON))
    do { _ = try await failed.value; XCTFail("Expected registration failure") }
    catch { XCTAssertTrue(error is ErrorEnvelope) }

    let retry = feature.requestDeviceRegistration(token: "synthetic-a")
    await provider.registrations.waitFor(2)
    try provider.registrations.finish(1, .success(()))
    let registered = try await retry.value
    XCTAssertEqual(registered, "synthetic-a")
    XCTAssertEqual(provider.registeredTokens, ["synthetic-a", "synthetic-a"])
  }

  func testReplacingDeviceDeliveryKeepsAdmittedWriteAndOnlyDeliversTheLatestToken() async throws {
    let provider = ControlledSessionProvider()
    defer { provider.releaseAll() }
    let secondAdmitted = expectation(description: "Replacement registration admitted")
    var admissions = 0
    let feature = SessionFeature(
      makeProvider: {
        admissions += 1
        if admissions == 2 { secondAdmitted.fulfill() }
        return provider
      },
      deviceRegistrationDebounce: {}, currentUser: { .template }
    )
    var delivered: [String] = []
    feature.receiveDeviceToken(Data([0x01])) { delivered.append($0) }
    await provider.registrations.waitFor(1)
    feature.receiveDeviceToken(Data([0x02])) { delivered.append($0) }
    await fulfillment(of: [secondAdmitted], timeout: 2)

    try provider.registrations.finish(0, .success(()))
    await provider.registrations.waitFor(2)
    XCTAssertEqual(provider.registeredTokens, ["01", "02"])
    XCTAssertEqual(provider.registrationWasCancelled, [false])
    XCTAssertTrue(delivered.isEmpty)
    try provider.registrations.finish(1, .success(()))
    await feature.waitForDeviceRegistration()
    XCTAssertEqual(delivered, ["02"])
  }

  func testRestoringTheUserDuringDeviceDebouncePreservesRegistrationAndDelivery() async throws {
    let provider = ControlledSessionProvider()
    let debounce = AccountRequestGate<Void>()
    defer { provider.releaseAll(); debounce.releaseAll() }
    var user: User?
    let feature = SessionFeature(
      makeProvider: { provider }, deviceRegistrationDebounce: { try await debounce.request() },
      currentUser: { user }, updateUser: { user = $0 }
    )
    let generation = feature.generation
    var delivered: [String] = []
    feature.receiveDeviceToken(Data([0x01])) { delivered.append($0) }
    await debounce.waitFor(1)

    feature.commitRefreshedUser(.template, userID: nil, generation: generation, allowSessionRestore: true)
    XCTAssertEqual(user?.id, User.template.id)
    XCTAssertEqual(feature.generation, generation)
    try debounce.finish(0, .success(()))
    await provider.registrations.waitFor(1)
    try provider.registrations.finish(0, .success(()))
    await feature.waitForDeviceRegistration()
    XCTAssertEqual(provider.registeredTokens, ["01"])
    XCTAssertEqual(delivered, ["01"])
  }

  func testRestoringTheUserDuringDeviceTransportKeepsSharingAndDelivery() async throws {
    let provider = ControlledSessionProvider()
    defer { provider.releaseAll() }
    var user: User?
    let feature = SessionFeature(
      makeProvider: { provider }, deviceRegistrationDebounce: {},
      currentUser: { user }, updateUser: { user = $0 }
    )
    let generation = feature.generation
    var delivered: [String] = []
    feature.receiveDeviceToken(Data([0x01])) { delivered.append($0) }
    await provider.registrations.waitFor(1)

    feature.commitRefreshedUser(.template, userID: nil, generation: generation, allowSessionRestore: true)
    XCTAssertEqual(user?.id, User.template.id)
    XCTAssertEqual(feature.generation, generation)
    let duplicate = feature.requestDeviceRegistration(token: "01")
    let duplicateFinished = expectation(description: "Restored session shares device registration")
    var duplicateResult: Result<String, Error>?
    let observer = Task {
      duplicateResult = await duplicate.result
      duplicateFinished.fulfill()
    }
    try provider.registrations.finish(0, .success(()))
    await fulfillment(of: [duplicateFinished], timeout: 2)
    // Release an unexpected extra transport too, so a broken sharing policy cannot hang the suite.
    provider.releaseAll()
    await observer.value
    await feature.waitForDeviceRegistration()
    guard case let .success(token)? = duplicateResult else {
      return XCTFail("Restoring account metadata invalidated the shared registration")
    }
    XCTAssertEqual(token, "01")
    XCTAssertEqual(provider.registeredTokens, ["01"])
    XCTAssertEqual(delivered, ["01"])
  }

  func testObsoleteDeviceTransportFailureIsReportedAsCancellation() async throws {
    let provider = ControlledSessionProvider()
    defer { provider.releaseAll() }
    let feature = SessionFeature(makeProvider: { provider }, currentUser: { .template })
    let obsolete = feature.requestDeviceRegistration(token: "synthetic-a")
    await provider.registrations.waitFor(1)
    feature.sessionChanged()
    try provider.registrations.finish(0, .failure(ErrorEnvelope.couldNotParseJSON))
    guard case .failure(is CancellationError) = await obsolete.result else {
      return XCTFail("An old session's transport error escaped the registration boundary")
    }
    XCTAssertEqual(provider.registrationWasCancelled, [false])
  }

  func testSessionBoundRejectsCancelledObserverAfterAdmittedWorkCompletes() async throws {
    let gate = AccountRequestGate<Void>()
    defer { gate.releaseAll() }
    let feature = SessionFeature(makeProvider: { ControlledSessionProvider() })
    let operation = feature.sessionBound { try await gate.request() }
    let observer = Task { try await operation() }
    await gate.waitFor(1)
    observer.cancel()
    try gate.finish(0, .success(()))
    if case .failure(is CancellationError) = await observer.result {
    } else {
      XCTFail("Cancelled observation published an admitted result")
    }
  }

  func testSharedBadgeCommandCommitsOnceAndKeepsLatestPreferences() async throws {
    let provider = ControlledSessionProvider()
    defer { provider.releaseAll() }
    var user: User? = .template
    var commits = 0
    let feature = SessionFeature(
      makeProvider: { provider }, currentUser: { user },
      updateUser: { user = $0; commits += 1 }
    )
    let first = feature.request(.clearActivity)
    let duplicate = feature.request(.clearActivity)
    await provider.badges.waitFor(1)
    user?.chosenCurrency = "GBP"
    let readRevision = feature.readGeneration
    try provider.badges.finish(0, .success(0))
    _ = try await first.value
    _ = try await duplicate.value
    XCTAssertEqual(provider.badges.count, 1)
    XCTAssertEqual(commits, 1)
    XCTAssertEqual(user?.chosenCurrency, "GBP")
    XCTAssertEqual(user?.unseenActivityCount, 0)
    XCTAssertGreaterThan(feature.readGeneration, readRevision)
  }

  func testFailedBadgeCommandPreservesUserAndCanRetry() async throws {
    let provider = ControlledSessionProvider()
    defer { provider.releaseAll() }
    var user: User? = .template
    user?.unseenActivityCount = 7
    var commits = 0
    let feature = SessionFeature(
      makeProvider: { provider }, currentUser: { user },
      updateUser: { user = $0; commits += 1 }
    )
    let failed = feature.request(.clearActivity)
    await provider.badges.waitFor(1)
    try provider.badges.finish(0, .failure(ErrorEnvelope.couldNotParseJSON))
    do { _ = try await failed.value; XCTFail("Expected failure") }
    catch { XCTAssertTrue(error is ErrorEnvelope) }
    XCTAssertEqual(user?.unseenActivityCount, 7)
    XCTAssertEqual(commits, 0)
    let retry = feature.request(.clearActivity)
    await provider.badges.waitFor(2)
    try provider.badges.finish(1, .success(0))
    _ = try await retry.value
    XCTAssertEqual(user?.unseenActivityCount, 0)
    XCTAssertEqual(commits, 1)
  }

  func testCompletedBadgeCommandInvalidatesOlderWholeUserRefresh() async throws {
    let provider = ControlledSessionProvider()
    defer { provider.releaseAll() }
    var user: User? = .template
    let feature = SessionFeature(
      makeProvider: { provider }, currentUser: { user }, updateUser: { user = $0 }
    )
    let read = feature.request()
    await provider.users.waitFor(1)
    let write = feature.request(.clearActivity)
    await provider.badges.waitFor(1)
    try provider.badges.finish(0, .success(0))
    _ = try await write.value
    var obsolete = User.template
    obsolete.unseenActivityCount = 9
    try provider.users.finish(0, .success(obsolete))
    do { _ = try await read.value; XCTFail("Old badge count escaped") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(user?.unseenActivityCount, 0)
  }

  func testBadgeCommitDoesNotCancelIndependentAccountSetup() async throws {
    let provider = ControlledSessionProvider()
    defer { provider.releaseAll() }
    var user: User? = .template
    var setupCommits = 0
    let feature = SessionFeature(
      makeProvider: { provider }, currentUser: { user },
      updateUser: { user = $0 }, updateSetup: { _ in setupCommits += 1 }
    )
    let setup = Task { try await feature.refreshSetup() }
    await provider.setups.waitFor(1)
    let badge = feature.request(.clearActivity)
    await provider.badges.waitFor(1)
    try provider.badges.finish(0, .success(0))
    _ = try await badge.value
    let metadata = GraphUserSetup(
      email: "fixture@example.invalid", enabledFeatures: [], ppoHasAction: true, backingActionCount: 2
    )
    try provider.setups.finish(0, .success(metadata))
    let result = try await setup.value
    XCTAssertEqual(result, metadata)
    XCTAssertEqual(setupCommits, 1)
    XCTAssertEqual(user?.unseenActivityCount, 0)
  }

  func testEquivalentSetupReadsShareAndCommitOnce() async throws {
    let provider = ControlledSessionProvider()
    defer { provider.releaseAll() }
    var commits: [GraphUserSetup] = []
    let feature = SessionFeature(
      makeProvider: { provider }, deviceRegistrationDebounce: {},
      storage: .init(
        currentUser: { .template },
        currentUserEmail: { commits.last?.email },
        currentUserPPOSettings: { nil },
        updateUser: { _ in XCTFail("Setup updated the user record") },
        login: { _ in XCTFail("Setup established a session") },
        updateSetup: { commits.append($0) }
      )
    )
    let first = Task { try await feature.refreshSetup() }
    let second = Task { try await feature.refreshSetup() }
    await provider.setups.waitFor(1)
    let setup = GraphUserSetup(
      email: "fixture@example.invalid",
      enabledFeatures: [],
      ppoHasAction: true,
      backingActionCount: 3
    )
    try provider.setups.finish(0, .success(setup))
    _ = try await first.value
    _ = try await second.value
    XCTAssertEqual(provider.setups.count, 1)
    XCTAssertEqual(commits, [setup])
    XCTAssertEqual(feature.currentUserEmail, setup.email)
  }

  func testObsoleteSetupSuccessAndFailureCannotPublishAndCurrentRetryCan() async throws {
    let provider = ControlledSessionProvider()
    defer { provider.releaseAll() }
    var commits = 0
    let feature = SessionFeature(
      makeProvider: { provider },
      currentUser: { .template },
      updateSetup: { _ in commits += 1 }
    )
    let setup = GraphUserSetup(
      email: "fixture@example.invalid",
      enabledFeatures: [],
      ppoHasAction: false,
      backingActionCount: 0
    )
    for (index, result) in [
      Result<GraphUserSetup, Error>.success(setup),
      .failure(ErrorEnvelope.couldNotParseJSON)
    ].enumerated() {
      let pending = Task { try await feature.refreshSetup() }
      await provider.setups.waitFor(index + 1)
      feature.sessionChanged()
      try provider.setups.finish(index, result)
      do { _ = try await pending.value; XCTFail("Obsolete setup escaped") }
      catch { XCTAssertTrue(error is CancellationError) }
    }
    XCTAssertEqual(commits, 0)
    let retry = Task { try await feature.refreshSetup() }
    await provider.setups.waitFor(3)
    try provider.setups.finish(2, .success(setup))
    _ = try await retry.value
    XCTAssertEqual(commits, 1)
  }

  func testAccountWriteInvalidationRejectsInFlightSetupWithoutChangingSession() async throws {
    let provider = ControlledSessionProvider()
    defer { provider.releaseAll() }
    var commits = 0
    let feature = SessionFeature(
      makeProvider: { provider },
      currentUser: { .template },
      updateSetup: { _ in commits += 1 }
    )
    let generation = feature.generation
    let pending = Task { try await feature.refreshSetup() }
    await provider.setups.waitFor(1)
    feature.invalidateReads()
    let setup = GraphUserSetup(
      email: "old@example.invalid",
      enabledFeatures: [],
      ppoHasAction: false,
      backingActionCount: 0
    )
    try provider.setups.finish(0, .success(setup))
    do { _ = try await pending.value; XCTFail("Stale setup committed") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(commits, 0)
    XCTAssertEqual(feature.generation, generation)
  }

  func testObsoleteUnauthorizedResponseCannotForceLogoutOfNewSession() async throws {
    let provider = ControlledSessionProvider()
    defer { provider.releaseAll() }
    let feature = SessionFeature(makeProvider: { provider }, currentUser: { .template })
    let old = feature.request()
    await provider.users.waitFor(1)
    feature.sessionChanged()
    let unauthorized = ErrorEnvelope(
      errorMessages: ["Expired fixture"],
      ksrCode: .AccessTokenInvalid,
      httpCode: 401,
      exception: nil
    )
    try provider.users.finish(0, .failure(unauthorized))
    do { _ = try await old.value; XCTFail("Old error escaped") }
    catch { XCTAssertTrue(error is CancellationError) }
    let current = feature.request()
    await provider.users.waitFor(2)
    try provider.users.finish(1, .failure(unauthorized))
    do { _ = try await current.value; XCTFail("Current error was swallowed") }
    catch { XCTAssertEqual((error as? ErrorEnvelope)?.ksrCode, .AccessTokenInvalid) }
  }

  func testLegacyTokenRestoreRequiresExplicitPermissionAndCurrentGeneration() {
    var user: User?
    let feature = SessionFeature(
      makeProvider: { ControlledSessionProvider() },
      currentUser: { user },
      updateUser: { user = $0 }
    )
    let generation = feature.generation
    feature.commitRefreshedUser(.template, userID: nil, generation: generation, allowSessionRestore: false)
    XCTAssertNil(user)
    feature.sessionChanged()
    feature.commitRefreshedUser(.template, userID: nil, generation: generation, allowSessionRestore: true)
    XCTAssertNil(user)
    feature.commitRefreshedUser(
      .template,
      userID: nil,
      generation: feature.generation,
      allowSessionRestore: true
    )
    XCTAssertEqual(user?.id, User.template.id)
  }

  func testEquivalentReadsShareAndFailureAllowsRetry() async throws {
    let provider = ControlledSessionProvider()
    defer { provider.releaseAll() }
    let feature = SessionFeature(makeProvider: { provider }, currentUser: { .template })
    let first = feature.request()
    let duplicate = feature.request()
    await provider.users.waitFor(1)
    try provider.users.finish(0, .failure(ErrorEnvelope.couldNotParseJSON))
    for task in [first, duplicate] {
      do { _ = try await task.value; XCTFail("Expected error") } catch {}
    }
    XCTAssertEqual(provider.users.count, 1)
    let retry = feature.request()
    await provider.users.waitFor(2)
    try provider.users.finish(1, .success(.template))
    let user = try await retry.value
    XCTAssertEqual(user.id, User.template.id)
  }

  func testSessionRoundTripRejectsOldReadEvenWithSameUserID() async throws {
    let provider = ControlledSessionProvider()
    defer { provider.releaseAll() }
    let feature = SessionFeature(makeProvider: { provider }, currentUser: { .template })
    let old = feature.request()
    await provider.users.waitFor(1)
    feature.sessionChanged()
    let new = feature.request()
    await provider.users.waitFor(2)
    try provider.users.finish(0, .success(.template))
    do { _ = try await old.value; XCTFail("Obsolete read published") } catch is CancellationError {} catch {
      XCTFail("\(error)")
    }
    try provider.users.finish(1, .success(.template))
    _ = try await new.value
  }

  func testBadgeWriteContinuesButCannotUpdateNewAccount() async throws {
    let provider = ControlledSessionProvider()
    defer { provider.releaseAll() }
    var user: User? = .template
    let feature = SessionFeature(makeProvider: { provider }, currentUser: { user })
    let first = feature.request(.clearActivity)
    let duplicate = feature.request(.clearActivity)
    await provider.badges.waitFor(1)
    user = nil
    feature.sessionChanged()
    try provider.badges.finish(0, .success(0))
    for task in [first, duplicate] {
      do { _ = try await task.value; XCTFail("Obsolete badge result") } catch is CancellationError {} catch {
        XCTFail("\(error)")
      }
    }
    let denied = feature.request(.clearActivity)
    do { _ = try await denied.value; XCTFail("Logged-out mutation") } catch {}
    XCTAssertEqual(provider.badges.count, 1)
  }

  func testIndependentReadKindsAndCancelledWaiterDoNotCancelSharedWork() async throws {
    let provider = ControlledSessionProvider()
    defer { provider.releaseAll() }
    let feature = SessionFeature(makeProvider: { provider }, currentUser: { .template })
    let shared = feature.request()
    let joined = XCTestExpectation(description: "Waiter enters shared read")
    let waiter = Task {
      joined.fulfill()
      return try await feature.refresh()
    }
    let graph = feature.request(.graphUser)
    await provider.users.waitFor(1)
    await provider.graphs.waitFor(1)
    await fulfillment(of: [joined], timeout: 2)
    waiter.cancel()
    try provider.users.finish(0, .success(.template))
    try provider.graphs.finish(0, .success(.template))
    _ = try await shared.value
    _ = try await graph.value
    do { _ = try await waiter.value; XCTFail("Cancelled waiter succeeded")
    } catch is CancellationError {} catch { XCTFail("\(error)") }
    XCTAssertEqual(provider.users.count, 1)
  }
}

@MainActor
private final class ControlledSessionProvider: SessionProvider {
  let setups = AccountRequestGate<GraphUserSetup>()
  func setup() async throws -> GraphUserSetup { try await self.setups.request() }
  let users = AccountRequestGate<User>()
  let graphs = AccountRequestGate<User>()
  let badges = AccountRequestGate<Int>()
  let registrations = AccountRequestGate<Void>()
  private(set) var registeredTokens: [String] = []
  private(set) var registrationWasCancelled: [Bool] = []
  func registerDeviceToken(_ token: String) async throws {
    self.registeredTokens.append(token)
    defer { self.registrationWasCancelled.append(Task.isCancelled) }
    try await self.registrations.request()
  }
  func user() async throws -> User { try await self.users.request() }
  func graphUser() async throws -> User { try await self.graphs.request() }
  func clearActivityIndicator() async throws -> Int { try await self.badges.request() }
  func releaseAll() {
    self.users.releaseAll(); self.graphs.releaseAll(); self.badges.releaseAll(); self.setups.releaseAll()
    self.registrations.releaseAll()
  }
}
