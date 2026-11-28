@testable import Kickstarter_iOS
@testable import KsApi
import Experimentation
import Foundation

import XCTest

@MainActor
final class SettingsFeatureTests: XCTestCase {
  func testApplicationFlagsExposeOnlySupportedSortedKeysAndPreserveUnknownValues() throws {
    var configuration = Config.template
    configuration.features = Dictionary(uniqueKeysWithValues: Feature.allCases.map { ($0.rawValue, true) })
    configuration.features["unknown_server_flag"] = false
    let fixture = ApplicationSettingsFixture(configuration: configuration)
    let flags = try XCTUnwrap(fixture.feature.configurationFlags)
    XCTAssertEqual(flags.map { $0.feature.rawValue }, Feature.allCases.map(\.rawValue).sorted())
    XCTAssertTrue(flags.allSatisfy { $0.isEnabled })

    XCTAssertTrue(fixture.feature.setConfigurationFlag(.segment, enabled: false))
    XCTAssertEqual(fixture.configuration?.features[Feature.segment.rawValue], false)
    XCTAssertEqual(fixture.configuration?.features["unknown_server_flag"], false)
    XCTAssertEqual(fixture.savedOverrides.count, 1)
  }

  func testApplicationFlagNoOpMissingKeyAndMissingConfigurationDoNotSave() {
    var configuration = Config.template
    configuration.features = [Feature.segment.rawValue: true]
    let fixture = ApplicationSettingsFixture(configuration: configuration)
    XCTAssertFalse(fixture.feature.setConfigurationFlag(.segment, enabled: true))
    fixture.configuration?.features = ["unknown_server_flag": true]
    XCTAssertEqual(fixture.feature.configurationFlags?.count, 0)
    XCTAssertFalse(fixture.feature.setConfigurationFlag(.segment, enabled: false))
    fixture.configuration = nil
    XCTAssertNil(fixture.feature.configurationFlags)
    XCTAssertFalse(fixture.feature.setConfigurationFlag(.segment, enabled: true))
    XCTAssertTrue(fixture.savedOverrides.isEmpty)
  }

  func testConsecutiveApplicationFlagEditsMergeIntoTheLatestConfiguration() {
    var configuration = Config.template
    configuration.features = [Feature.segment.rawValue: true, "unknown_server_flag": false]
    let fixture = ApplicationSettingsFixture(configuration: configuration)
    XCTAssertTrue(fixture.feature.setConfigurationFlag(.segment, enabled: false))
    fixture.configuration?.countryCode = "CA"
    fixture.configuration?.features["new_server_flag"] = true
    XCTAssertTrue(fixture.feature.setConfigurationFlag(.segment, enabled: true))

    XCTAssertEqual(fixture.configuration?.countryCode, "CA")
    XCTAssertEqual(fixture.configuration?.features, [
      Feature.segment.rawValue: true, "unknown_server_flag": false, "new_server_flag": true
    ])
    XCTAssertEqual(fixture.savedOverrides.count, 2)
  }

  func testRemoteAndStatsigFalseOverridesTakePrecedenceAndPreserveOtherKeys() throws {
    let fixture = ApplicationSettingsFixture()
    let remote = MockRemoteConfigClient()
    remote.features = Dictionary(uniqueKeysWithValues: RemoteConfigFeature.allCases.map { ($0.rawValue, true) })
    let statsig = MockStatsigWrapper()
    statsig.features = Dictionary(uniqueKeysWithValues: StatsigFeature.allCases.map { ($0, true) })
    fixture.remoteClient = remote
    fixture.statsigClient = statsig
    fixture.store.remoteConfigFeatureFlags = [RemoteConfigFeature.floatingTabBar.rawValue: false, "unknown_remote": true]
    fixture.store.statsigFeatureFlags = [StatsigFeature.videoFeed.rawValue: false, "unknown_statsig": true]

    let remoteValue = try XCTUnwrap(fixture.feature.remoteConfigurationFlags.first { $0.0 == .floatingTabBar })
    let statsigValue = try XCTUnwrap(fixture.feature.statsigFlags.first { $0.0 == .videoFeed })
    XCTAssertFalse(remoteValue.1)
    XCTAssertFalse(statsigValue.1)
    fixture.feature.setRemoteConfigurationOverride(.useKeychainForOAuthToken, enabled: false)
    fixture.feature.setStatsigOverride(.projectStoryRichText, enabled: false)
    XCTAssertEqual(fixture.store.remoteConfigFeatureFlags, [
      RemoteConfigFeature.floatingTabBar.rawValue: false,
      RemoteConfigFeature.useKeychainForOAuthToken.rawValue: false, "unknown_remote": true
    ])
    XCTAssertEqual(fixture.store.statsigFeatureFlags, [
      StatsigFeature.videoFeed.rawValue: false,
      StatsigFeature.projectStoryRichText.rawValue: false, "unknown_statsig": true
    ])
    XCTAssertEqual(remote.features[RemoteConfigFeature.useKeychainForOAuthToken.rawValue], true)
    XCTAssertEqual(statsig.features[.projectStoryRichText], true)
  }

  func testApplicationFlagsUseEachInjectedClientInsteadOfTheGlobalClient() throws {
    let globalRemote = MockRemoteConfigClient()
    let globalStatsig = MockStatsigWrapper()
    globalRemote.features[RemoteConfigFeature.floatingTabBar.rawValue] = false
    globalStatsig.features[.videoFeed] = false
    AppEnvironment.pushEnvironment(remoteConfigClient: globalRemote, statsigClient: globalStatsig)
    defer { AppEnvironment.popEnvironment() }
    let first = ApplicationSettingsFixture()
    let second = ApplicationSettingsFixture()
    let firstRemote = MockRemoteConfigClient()
    firstRemote.features[RemoteConfigFeature.floatingTabBar.rawValue] = true
    let firstStatsig = MockStatsigWrapper()
    firstStatsig.features[.videoFeed] = true
    first.remoteClient = firstRemote
    first.statsigClient = firstStatsig
    second.remoteClient = MockRemoteConfigClient()
    second.statsigClient = MockStatsigWrapper()

    XCTAssertTrue(try XCTUnwrap(first.feature.remoteConfigurationFlags.first { $0.0 == .floatingTabBar }).1)
    XCTAssertTrue(try XCTUnwrap(first.feature.statsigFlags.first { $0.0 == .videoFeed }).1)
    XCTAssertFalse(try XCTUnwrap(second.feature.remoteConfigurationFlags.first { $0.0 == .floatingTabBar }).1)
    XCTAssertFalse(try XCTUnwrap(second.feature.statsigFlags.first { $0.0 == .videoFeed }).1)
    first.remoteClient = nil
    first.statsigClient = nil
    XCTAssertTrue(first.feature.remoteConfigurationFlags.allSatisfy { !$0.1 })
    XCTAssertTrue(first.feature.statsigFlags.allSatisfy { !$0.1 })
  }

  func testAppStoreURLReadsTheCurrentConfigurationWithoutAnotherCache() {
    let fixture = ApplicationSettingsFixture(configuration: nil)
    XCTAssertNil(fixture.feature.appStoreURL)
    fixture.configuration = .template
    fixture.configuration?.iTunesLink = "https://example.invalid/store-a"
    XCTAssertEqual(fixture.feature.appStoreURL, "https://example.invalid/store-a")
    XCTAssertTrue(fixture.feature.canOfferAppStoreRating)
    fixture.configuration?.iTunesLink = "https://example.invalid/store-b"
    XCTAssertEqual(fixture.feature.appStoreURL, "https://example.invalid/store-b")
    fixture.configuration = nil
    XCTAssertFalse(fixture.feature.canOfferAppStoreRating)
  }

  func testNewsletterOptInPoliciesReadTheirInjectedCountriesIndependently() {
    var configuration = Config.template
    configuration.countryCode = "DE"
    let fixture = ApplicationSettingsFixture(configuration: configuration, currentCountryCode: "US")
    XCTAssertTrue(fixture.feature.requiresConfiguredCountryNewsletterOptIn)
    XCTAssertFalse(fixture.feature.requiresCurrentCountryNewsletterOptIn)

    fixture.configuration?.countryCode = "GB"
    fixture.currentCountryCode = "DE"
    XCTAssertFalse(fixture.feature.requiresConfiguredCountryNewsletterOptIn)
    XCTAssertTrue(fixture.feature.requiresCurrentCountryNewsletterOptIn)
  }

  func testApplicationRefreshSharesPrefetchAndRetainsAnOverrideMadeWhileLoading() async throws {
    var initial = Config.template
    initial.features = [Feature.segment.rawValue: true, "removed_server_flag": true]
    let fixture = ApplicationSettingsFixture(configuration: initial)
    defer { fixture.responses.releaseAll() }
    let prefetch = fixture.feature.startApplicationSettingsLoad()
    await fixture.responses.waitFor(1)
    let refresh = fixture.feature.startApplicationSettingsRefresh()
    XCTAssertTrue(fixture.appliedConfigurations.isEmpty)
    XCTAssertTrue(fixture.feature.setConfigurationFlag(.segment, enabled: false))
    var incoming = Config.template
    incoming.countryCode = "GB"
    incoming.features = [Feature.segment.rawValue: true, "new_server_flag": true]
    try fixture.responses.finish(0, .success(incoming))
    let prefetched = try await prefetch.value
    let refreshed = try await refresh.value

    XCTAssertEqual(prefetched, refreshed)
    XCTAssertEqual(refreshed.features, [Feature.segment.rawValue: false, "new_server_flag": true])
    XCTAssertEqual(fixture.configuration, refreshed)
    XCTAssertEqual(fixture.configuration?.countryCode, "GB")
    XCTAssertEqual(fixture.responses.count, 1)
    XCTAssertEqual(fixture.appliedConfigurations, [refreshed])
  }

  func testResetApplicationSettingsRejectsOldRefreshAndAllowsCurrentRefresh() async throws {
    let fixture = ApplicationSettingsFixture()
    defer { fixture.responses.releaseAll() }
    let old = fixture.feature.startApplicationSettingsRefresh()
    await fixture.responses.waitFor(1)
    fixture.feature.cancelPendingApplicationSettingsLoad()
    let current = fixture.feature.startApplicationSettingsRefresh()
    await fixture.responses.waitFor(2)
    var previous = Config.template
    previous.countryCode = "CA"
    var replacement = Config.template
    replacement.countryCode = "AU"
    try fixture.responses.finish(0, .success(previous))
    try fixture.responses.finish(1, .success(replacement))
    guard case .failure(is CancellationError) = await old.result else {
      return XCTFail("Obsolete application settings were applied")
    }
    let applied = try await current.value
    XCTAssertEqual(applied.countryCode, "AU")
    XCTAssertEqual(fixture.appliedConfigurations, [applied])
  }

  func testRemoteClientIsInstalledSynchronouslyBeforeActivationStarts() async throws {
    let fixture = ApplicationSettingsFixture()
    let client = SettingsActivationClient { fixture.activationEvents.append("activated") }
    let activation = fixture.feature.activateRemoteSettings(client: client)
    XCTAssertTrue(fixture.remoteClient === client)
    XCTAssertEqual(fixture.activationEvents, ["installed"])
    try await activation.value
    XCTAssertEqual(fixture.activationEvents, ["installed", "activated"])
  }

  func testScheduledRefreshCanBeCancelledBeforeItStarts() {
    let fixture = PreferencesFixture()
    let feature = SettingsFeature(
      sessionFeature: fixture.session,
      hasStoredCredentials: {
        XCTFail("An obsolete refresh consulted credentials")
        return false
      },
      makeProvider: { fixture.provider }
    )

    feature.scheduleAccountRefresh { _ in XCTFail("An obsolete refresh delivered a result") }
    feature.cancelScheduledAccountRefresh()
  }

  func testEveryNotificationURLFieldChangesOnlyItsOwnPreference() async throws {
    let parameters = [
      "notify_of_backings", "notify_of_comment_replies", "notify_of_comments",
      "notify_of_creator_digest", "notify_of_creator_edu", "notify_of_follower",
      "notify_of_friend_activity", "notify_of_messages", "notify_mobile_of_backings",
      "notify_mobile_of_comments", "notify_mobile_of_follower", "notify_mobile_of_friend_activity",
      "notify_mobile_of_marketing_update", "notify_mobile_of_messages", "notify_mobile_of_post_likes",
      "notify_mobile_of_updates", "notify_of_post_likes", "notify_of_updates"
    ]
    for parameter in parameters {
      let fixture = PreferencesFixture()
      defer { fixture.provider.gate.releaseAll() }
      for (index, enabled) in [true, false].enumerated() {
        let before = try XCTUnwrap(fixture.user)
        var expected = try XCTUnwrap(before.notifications.encode() as? [String: Bool])
        expected[parameter] = enabled
        let request = try XCTUnwrap(fixture.feature.startNotificationPreferenceSave(named: parameter, enabled: enabled))
        await fixture.provider.gate.waitFor(index + 1)
        let sent = try XCTUnwrap(fixture.provider.sent.last)
        XCTAssertEqual(sent.notifications.encode() as? [String: Bool], expected, parameter)
        XCTAssertEqual(sent.newsletters.games, before.newsletters.games, parameter)
        try fixture.provider.succeed(index)
        _ = try await request.value
        XCTAssertEqual(fixture.user?.notifications.encode() as? [String: Bool], expected, parameter)
      }
    }
  }

  func testNewsletterAndDeepLinkCommandsShareOrderedWrites() async throws {
    let fixture = PreferencesFixture()
    defer { fixture.provider.gate.releaseAll() }
    let user = try XCTUnwrap(fixture.user)
    let newsletter = fixture.feature.startPreferencesSave([.init(.newsletter(.games), true)], from: user)
    let notification = try XCTUnwrap(fixture.feature.startNotificationPreferenceSave(named: "notify_mobile_of_messages", enabled: true))
    let laterNewsletter = fixture.feature.startPreferencesSave([.init(.newsletter(.games), false)], from: user)
    await fixture.provider.gate.waitFor(1)
    try fixture.provider.succeed(0)
    await fixture.provider.gate.waitFor(2)
    XCTAssertEqual(fixture.provider.sent[1].newsletters.games, true)
    XCTAssertEqual(fixture.provider.sent[1].notifications.mobileMessages, true)
    try fixture.provider.succeed(1)
    await fixture.provider.gate.waitFor(3)
    XCTAssertEqual(fixture.provider.sent[2].newsletters.games, false)
    XCTAssertEqual(fixture.provider.sent[2].notifications.mobileMessages, true)
    try fixture.provider.succeed(2)
    _ = try await newsletter.value
    _ = try await notification.value
    _ = try await laterNewsletter.value
    XCTAssertEqual(fixture.commits, 3)
  }

  func testUnknownNotificationKeepsLegacyNoOpAndSignedOutLinkDoesNotSave() async throws {
    let fixture = PreferencesFixture()
    defer { fixture.provider.gate.releaseAll() }
    let original = try XCTUnwrap(fixture.user)
    let request = try XCTUnwrap(fixture.feature.startNotificationPreferenceSave(named: "unrecognized", enabled: true))
    await fixture.provider.gate.waitFor(1)
    XCTAssertEqual(fixture.provider.sent[0].notifications, original.notifications)
    try fixture.provider.succeed(0)
    _ = try await request.value
    fixture.user = nil
    let signedOut = fixture.feature.startNotificationPreferenceSave(named: "notify_of_messages", enabled: true)
    XCTAssertNil(signedOut)
    await fixture.feature.waitForSettingsOperations()
    XCTAssertEqual(fixture.provider.sent.count, 1)
  }

  func testSignedOutCommandDoesNotReachProvider() async throws {
    let fixture = PreferencesFixture()
    fixture.user = nil
    defer { fixture.provider.gate.releaseAll() }
    let request = fixture.feature.startPreferencesSave([.init(.newsletter(.arts), true)], from: .template)
    do { _ = try await request.value; XCTFail("Signed-out write must fail") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(fixture.provider.sent.count, 0)
    XCTAssertEqual(fixture.commits, 0)
  }

  func testDemoPreferencesCannotPretendToSave() async {
    let provider = AsyncAccountPreferencesProvider(service: MockService.publicDemo())
    do { _ = try await provider.saveAccountPreferences(.template); XCTFail("Demo unexpectedly saved account data") }
    catch { XCTAssertTrue(error is ErrorEnvelope) }
  }

  func testQueuedEditsMergeConfirmedPreferencesInsteadOfStaleCellSnapshots() async throws {
    let fixture = PreferencesFixture()
    defer { fixture.provider.gate.releaseAll() }
    let original = try XCTUnwrap(fixture.user)
    let first = fixture.feature.startPreferencesSave([.init(.newsletter(.arts), true)], from: original)
    let second = fixture.feature.startPreferencesSave([.init(.notification(.messages), true)], from: original)
    await fixture.provider.gate.waitFor(1)
    XCTAssertEqual(fixture.provider.sent.count, 1)
    try fixture.provider.succeed(0)
    await fixture.provider.gate.waitFor(2)
    XCTAssertEqual(fixture.provider.sent[1].newsletters.arts, true)
    XCTAssertEqual(fixture.provider.sent[1].notifications.messages, true)
    try fixture.provider.succeed(1)
    _ = try await first.value
    _ = try await second.value
    XCTAssertEqual(fixture.user?.newsletters.arts, true)
    XCTAssertEqual(fixture.user?.notifications.messages, true)
    XCTAssertEqual(fixture.commits, 2)
  }

  func testEquivalentTailSharesButOnOffOnRemainsOrdered() async throws {
    let fixture = PreferencesFixture()
    defer { fixture.provider.gate.releaseAll() }
    let user = try XCTUnwrap(fixture.user)
    let changes: [SettingsFeature.Change] = [.init(.newsletter(.arts), true)]
    let a = fixture.feature.startPreferencesSave(changes, from: user)
    let duplicate = fixture.feature.startPreferencesSave(changes, from: user)
    let b = fixture.feature.startPreferencesSave([.init(.newsletter(.arts), false)], from: user)
    let c = fixture.feature.startPreferencesSave(changes, from: user)
    for index in 0..<3 {
      await fixture.provider.gate.waitFor(index + 1)
      XCTAssertEqual(fixture.provider.sent[index].newsletters.arts, index != 1)
      try fixture.provider.succeed(index)
    }
    _ = try await a.value
    _ = try await duplicate.value
    _ = try await b.value
    _ = try await c.value
    XCTAssertEqual(fixture.provider.sent.count, 3)
    XCTAssertEqual(fixture.user?.newsletters.arts, true)
  }

  func testFailureDoesNotPoisonNextWriteAndRetryIsPossible() async throws {
    let fixture = PreferencesFixture()
    defer { fixture.provider.gate.releaseAll() }
    let user = try XCTUnwrap(fixture.user)
    let a = fixture.feature.startPreferencesSave([.init(.newsletter(.arts), true)], from: user)
    let b = fixture.feature.startPreferencesSave([.init(.notification(.messages), true)], from: user)
    await fixture.provider.gate.waitFor(1)
    try fixture.provider.gate.finish(0, .failure(ErrorEnvelope.couldNotParseJSON))
    await fixture.provider.gate.waitFor(2)
    XCTAssertEqual(fixture.provider.sent[1].newsletters.arts, user.newsletters.arts)
    do { _ = try await a.value; XCTFail("The failed write must report an error") } catch {}
    XCTAssertNotNil(fixture.feature.lastError)
    try fixture.provider.succeed(1)
    _ = try await b.value
    let retry = fixture.feature.startPreferencesSave([.init(.newsletter(.arts), true)], from: user)
    await fixture.provider.gate.waitFor(3)
    try fixture.provider.succeed(2)
    _ = try await retry.value
    XCTAssertNil(fixture.feature.lastError)
    XCTAssertEqual(fixture.user?.newsletters.arts, true)
    XCTAssertEqual(fixture.user?.notifications.messages, true)
  }

  func testCanceledPresentationDoesNotAbandonAdmittedWrite() async throws {
    let fixture = PreferencesFixture()
    defer { fixture.provider.gate.releaseAll() }
    let request = fixture.feature.startPreferencesSave(
      [.init(.privacy(.following), false)], from: try XCTUnwrap(fixture.user)
    )
    let waiter = Task {
      let user = try await request.value
      try Task.checkCancellation()
      return user
    }
    await fixture.provider.gate.waitFor(1)
    waiter.cancel()
    try fixture.provider.succeed(0)
    do { _ = try await waiter.value; XCTFail("Canceled waiter must not receive the result") }
    catch { XCTAssertTrue(error is CancellationError) }
    _ = try await request.value
    XCTAssertEqual(fixture.commits, 1)
    XCTAssertEqual(fixture.user?.social, false)
  }

  func testCancelledAsyncWaiterDoesNotCancelAdmittedMutation() async throws {
    let fixture = PreferencesFixture()
    defer { fixture.provider.gate.releaseAll() }
    let user = try XCTUnwrap(fixture.user)
    let task = Task { try await fixture.feature.savePreferences([.init(.privacy(.following), false)], from: user) }
    await fixture.provider.gate.waitFor(1)
    task.cancel()
    try fixture.provider.succeed(0)
    do { _ = try await task.value; XCTFail("Cancelled waiter returned success") }
    catch is CancellationError {} catch { XCTFail("\(error)") }
    XCTAssertEqual(fixture.commits, 1)
  }

  func testLogoutRejectsOldSuccessAndDoesNotDispatchQueuedAccountWrite() async throws {
    let fixture = PreferencesFixture()
    defer { fixture.provider.gate.releaseAll() }
    let user = try XCTUnwrap(fixture.user)
    let a = fixture.feature.startPreferencesSave([.init(.newsletter(.arts), true)], from: user)
    let b = fixture.feature.startPreferencesSave([.init(.notification(.messages), true)], from: user)
    await fixture.provider.gate.waitFor(1)
    fixture.user = nil
    fixture.session.sessionChanged()
    try fixture.provider.succeed(0)
    do { _ = try await a.value; XCTFail("Old write must not return a user") }
    catch { XCTAssertTrue(error is CancellationError) }
    do { _ = try await b.value; XCTFail("Queued old write must not return a user") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(fixture.provider.sent.count, 1)
    XCTAssertEqual(fixture.commits, 0)
    XCTAssertNil(fixture.user)
  }

  func testSameAccountNewSessionRejectsOldErrorAndCanSaveIndependently() async throws {
    let fixture = PreferencesFixture()
    defer { fixture.provider.gate.releaseAll() }
    let user = try XCTUnwrap(fixture.user)
    let old = fixture.feature.startPreferencesSave([.init(.newsletter(.arts), true)], from: user)
    await fixture.provider.gate.waitFor(1)
    fixture.session.sessionChanged()
    let new = fixture.feature.startPreferencesSave([.init(.notification(.messages), true)], from: user)
    await fixture.provider.gate.waitFor(2)
    try fixture.provider.succeed(1)
    try fixture.provider.gate.finish(0, .failure(ErrorEnvelope.couldNotParseJSON))
    _ = try await new.value
    do { _ = try await old.value; XCTFail("Old-session error must not be delivered") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(fixture.commits, 1)
    XCTAssertNil(fixture.feature.lastError)
  }

  func testAllNewslettersCommandPreservesOtherPreferences() async throws {
    let fixture = PreferencesFixture()
    defer { fixture.provider.gate.releaseAll() }
    let user = try XCTUnwrap(fixture.user)
    let request = fixture.feature.startPreferencesSave(SettingsFeature.Change.allNewsletters(true), from: user)
    await fixture.provider.gate.waitFor(1)
    let sent = try XCTUnwrap(fixture.provider.sent.first)
    for newsletter in Newsletter.allCases {
      XCTAssertEqual(sent[keyPath: UserAttribute.newsletter(newsletter).keyPath], true)
    }
    XCTAssertEqual(sent.notifications.messages, user.notifications.messages)
    XCTAssertEqual(sent.social, user.social)
    try fixture.provider.succeed(0)
    _ = try await request.value
  }

  func testOlderReadCannotOverwriteCompletedPreferenceWrite() async throws {
    let fixture = PreferencesFixture()
    let users = ControlledPreferencesReadProvider()
    let session = SessionFeature(
      makeProvider: { users },
      currentUser: { fixture.user },
      updateUser: { fixture.user = $0 }
    )
    let feature = SettingsFeature(sessionFeature: session, makeProvider: { fixture.provider })
    defer { fixture.provider.gate.releaseAll(); users.gate.releaseAll() }
    let user = try XCTUnwrap(fixture.user)
    let read = Task { try await feature.refreshAccount() }
    await users.gate.waitFor(1)
    let write = feature.startPreferencesSave([.init(.newsletter(.arts), true)], from: user)
    defer { read.cancel() }
    await fixture.provider.gate.waitFor(1)
    try fixture.provider.succeed(0)
    try users.gate.finish(0, .success(user))
    do {
      _ = try await read.value
      XCTFail("A stale refresh must not return after a preference write")
    } catch is CancellationError {
      // Expected.
    }
    _ = try await write.value
    XCTAssertEqual(fixture.user?.newsletters.arts, true)
  }

  func testWrongAccountSnapshotCannotWrite() async throws {
    let fixture = PreferencesFixture()
    var source = try XCTUnwrap(fixture.user)
    source.id += 1
    defer { fixture.provider.gate.releaseAll() }
    let request = fixture.feature.startPreferencesSave([.init(.newsletter(.arts), true)], from: source)
    do { _ = try await request.value; XCTFail("Wrong-account write must fail") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(fixture.provider.sent.count, 0)
    XCTAssertEqual(fixture.commits, 0)
  }

  func testWrongAccountSnapshotCannotResetAnExistingQueue() async throws {
    let fixture = PreferencesFixture()
    defer { fixture.provider.gate.releaseAll() }
    let user = try XCTUnwrap(fixture.user)
    let first = fixture.feature.startPreferencesSave([.init(.newsletter(.arts), true)], from: user)
    await fixture.provider.gate.waitFor(1)
    var wrong = user
    wrong.id += 1
    let rejected = fixture.feature.startPreferencesSave([.init(.newsletter(.weekly), true)], from: wrong)
    let next = fixture.feature.startPreferencesSave([.init(.notification(.messages), true)], from: user)
    try fixture.provider.succeed(0)
    await fixture.provider.gate.waitFor(2)
    XCTAssertEqual(fixture.provider.sent[1].newsletters.arts, true)
    XCTAssertEqual(fixture.provider.sent[1].newsletters.weekly, user.newsletters.weekly)
    try fixture.provider.succeed(1)
    _ = try await first.value
    _ = try await next.value
    do { _ = try await rejected.value; XCTFail("Wrong-account write must fail") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(fixture.provider.sent.count, 2)
    XCTAssertEqual(fixture.commits, 2)
  }
}

@MainActor
private final class PreferencesFixture {
  var user: User? = {
    var user = User.template
    user.newsletters.arts = false
    user.notifications.messages = false
    return user
  }()

  var commits = 0
  let provider = ControlledPreferencesProvider()
  lazy var session = SessionFeature(
    makeProvider: { AsyncSessionProvider(service: MockService()) },
    currentUser: { [weak self] in self?.user },
    updateUser: { [weak self] in self?.user = $0; self?.commits += 1 }
  )
  lazy var feature = SettingsFeature(sessionFeature: self.session, makeProvider: { self.provider })
}

@MainActor
extension SettingsFeatureTests {
  func testEmailLookupRejectsResultAfterSessionReplacement() async throws {
    let fixture = AccountWritesFixture()
    defer { fixture.provider.emails.releaseAll() }
    let read = Task { try await fixture.feature.loadEmailUser() }
    await fixture.provider.emails.waitFor(1)
    fixture.session.sessionChanged()
    try fixture.provider.emails.finish(0, .success(.template))
    do {
      _ = try await read.value
      XCTFail("A result from a replaced session must not be returned")
    } catch is CancellationError {
      // Expected.
    }
  }

  func testDisposedAccountFieldsReadCannotPublishLateValue() async throws {
    let fixture = AccountWritesFixture()
    defer { fixture.provider.emails.releaseAll() }
    let read = Task { try await fixture.feature.loadAccountFields() }
    await fixture.provider.emails.waitFor(1)
    read.cancel()
    try fixture.provider.emails.finish(0, .success(.template))
    do {
      _ = try await read.value
      XCTFail("A cancelled read must not publish its late value")
    } catch is CancellationError {
      // Expected.
    }
  }

  func testEmailLookupSharesAndAccountEditRejectsLateResult() async throws {
    let fixture = AccountWritesFixture()
    defer { fixture.provider.emails.releaseAll(); fixture.provider.gate.releaseAll() }
    let first = Task { try await fixture.feature.loadEmailUser() }
    let second = Task { try await fixture.feature.loadEmailUser() }
    await fixture.provider.emails.waitFor(1)
    _ = try fixture.feature.startAccountUpdate(.email(.init(
      email: "new@example.invalid",
      currentPassword: "fixture"
    )))
    await fixture.provider.gate.waitFor(1)
    try fixture.provider.gate.finish(0, .success(nil))
    try fixture.provider.emails.finish(0, .success(.template))
    for task in [first, second] {
      do { _ = try await task.value; XCTFail("Stale email appeared") }
      catch { XCTAssertTrue(error is CancellationError) }
    }
    XCTAssertEqual(fixture.provider.emails.count, 1)
  }

  func testEmailVerificationSharesAndDistinctLinksQueueWithoutLoggingIn() async throws {
    let fixture = AccountWritesFixture()
    fixture.user = nil // A deep link carries its own token.
    defer { fixture.provider.verifications.releaseAll() }
    let first = Task { try await fixture.feature.verifyEmail(token: "first-fixture") }
    let duplicate = Task { try await fixture.feature.verifyEmail(token: "first-fixture") }
    await fixture.provider.verifications.waitFor(1)
    let next = Task { try await fixture.feature.verifyEmail(token: "next-fixture") }
    try fixture.provider.verifications.finish(0, .success(.init(message: "Confirmed")))
    let firstResult = try await first.value
    let duplicateResult = try await duplicate.value
    XCTAssertEqual(firstResult.message, "Confirmed")
    XCTAssertEqual(duplicateResult.message, "Confirmed")
    await fixture.provider.verifications.waitFor(2)
    try fixture.provider.verifications.finish(1, .success(.init(message: "Next confirmed")))
    let nextResult = try await next.value
    XCTAssertEqual(nextResult.message, "Next confirmed")
    XCTAssertNil(fixture.user)
    XCTAssertEqual(fixture.commits, 0)
  }

  func testVerificationFailureAllowsRetryAndSessionChangeSuppressesLateSuccess() async throws {
    let fixture = AccountWritesFixture()
    defer { fixture.provider.verifications.releaseAll() }
    let first = Task { try await fixture.feature.verifyEmail(token: "fixture") }
    await fixture.provider.verifications.waitFor(1)
    try fixture.provider.verifications.finish(0, .failure(ErrorEnvelope.couldNotParseJSON))
    do { _ = try await first.value; XCTFail("Expected failure") }
    catch { XCTAssertTrue(error is ErrorEnvelope) }
    let retry = Task { try await fixture.feature.verifyEmail(token: "fixture") }
    await fixture.provider.verifications.waitFor(2)
    fixture.session.sessionChanged()
    try fixture.provider.verifications.finish(1, .success(.init(message: "Confirmed")))
    do { _ = try await retry.value; XCTFail("Old session completion escaped") }
    catch { XCTAssertTrue(error is CancellationError) }
  }

  func testEquivalentAccountWritesShareAndDistinctCommandsRemainOrdered() async throws {
    let fixture = AccountWritesFixture()
    defer { fixture.provider.gate.releaseAll() }
    let first = try fixture.feature.startAccountUpdate(.currency("GBP"))
    let duplicate = try fixture.feature.startAccountUpdate(.currency("GBP"))
    let next = try fixture.feature.startAccountUpdate(.currency("EUR"))
    await fixture.provider.gate.waitFor(1)
    XCTAssertEqual(fixture.provider.commands, [.currency("GBP")])
    try fixture.provider.gate.finish(0, .success(nil))
    await fixture.provider.gate.waitFor(2)
    XCTAssertEqual(fixture.user?.chosenCurrency, "GBP")
    try fixture.provider.gate.finish(1, .success(nil))
    await fixture.feature.waitForSettingsOperations()
    XCTAssertEqual(fixture.user?.chosenCurrency, "EUR")
    XCTAssertEqual(fixture.commits, 2)
    let firstUser = try await first.value
    let duplicateUser = try await duplicate.value
    let nextUser = try await next.value
    XCTAssertEqual(firstUser.chosenCurrency, "GBP")
    XCTAssertEqual(duplicateUser.chosenCurrency, "GBP")
    XCTAssertEqual(nextUser.chosenCurrency, "EUR")
  }

  func testConfirmedCurrencyWriteEmitsOneApplicationEvent() async throws {
    let fixture = AccountWritesFixture()
    defer { fixture.provider.gate.releaseAll() }
    let save = try fixture.feature.startAccountUpdate(.currency("GBP"))
    await fixture.provider.gate.waitFor(1)
    try fixture.provider.gate.finish(0, .success(nil))
    _ = try await save.value
    XCTAssertEqual(fixture.localePreferenceChanges, 1)
  }

  func testAccountAndPreferenceWritesUseOneQueue() async throws {
    let fixture = AccountWritesFixture()
    defer { fixture.provider.gate.releaseAll() }
    let source = try XCTUnwrap(fixture.user)
    _ = try fixture.feature.startAccountUpdate(.currency("GBP"))
    let preference = fixture.feature.startPreferencesSave([.init(.newsletter(.arts), true)], from: source)
    await fixture.provider.gate.waitFor(1)
    XCTAssertEqual(fixture.provider.preferences.count, 0)
    try fixture.provider.gate.finish(0, .success(nil))
    _ = try await preference.value
    XCTAssertEqual(fixture.provider.preferences.first?.chosenCurrency, "GBP")
    XCTAssertEqual(fixture.user?.newsletters.arts, true)
    XCTAssertEqual(fixture.user?.chosenCurrency, "GBP")
  }

  func testFailedAccountWriteDoesNotStrandNextCommandAndRetryIsExplicit() async throws {
    let fixture = AccountWritesFixture()
    defer { fixture.provider.gate.releaseAll() }
    let original = fixture.user?.chosenCurrency
    let failure = try fixture.feature.startAccountUpdate(.currency("GBP"))
    let next = try fixture.feature.startAccountUpdate(.currency("EUR"))
    await fixture.provider.gate.waitFor(1)
    try fixture.provider.gate.finish(0, .failure(ErrorEnvelope.couldNotParseJSON))
    await fixture.provider.gate.waitFor(2)
    XCTAssertEqual(fixture.user?.chosenCurrency, original)
    try fixture.provider.gate.finish(1, .success(nil))
    await fixture.feature.waitForSettingsOperations()
    do { _ = try await failure.value; XCTFail("Expected account write failure") }
    catch { XCTAssertTrue(error is ErrorEnvelope) }
    let nextUser = try await next.value
    XCTAssertEqual(nextUser.chosenCurrency, "EUR")
    let retry = Task { try await fixture.feature.updateAccount(.currency("GBP")) }
    await fixture.provider.gate.waitFor(3)
    try fixture.provider.gate.finish(2, .success(nil))
    _ = try await retry.value
    XCTAssertEqual(fixture.user?.chosenCurrency, "GBP")
    XCTAssertEqual(fixture.commits, 2)
  }

  func testDisposedObserverDoesNotAbandonAdmittedAccountWrite() async throws {
    let fixture = AccountWritesFixture()
    defer { fixture.provider.gate.releaseAll() }
    let admitted = try fixture.feature.startAccountUpdate(.currency("GBP"))
    let waiter = Task { _ = try await admitted.value; try Task.checkCancellation() }
    await fixture.provider.gate.waitFor(1)
    waiter.cancel()
    try fixture.provider.gate.finish(0, .success(nil))
    await fixture.feature.waitForSettingsOperations()
    XCTAssertEqual(fixture.user?.chosenCurrency, "GBP")
    do { _ = try await waiter.value; XCTFail("Cancelled waiter returned a value") }
    catch { XCTAssertTrue(error is CancellationError) }
  }

  func testReplacedSessionSuppressesAcceptedWriteAndDoesNotDispatchQueuedWrite() async throws {
    let fixture = AccountWritesFixture()
    defer { fixture.provider.gate.releaseAll() }
    let first = try fixture.feature.startAccountUpdate(.currency("GBP"))
    let queued = try fixture.feature.startAccountUpdate(.currency("EUR"))
    await fixture.provider.gate.waitFor(1)
    fixture.session.sessionChanged() // Even re-login as the same account is a new identity.
    try fixture.provider.gate.finish(0, .success(nil))
    await fixture.feature.waitForSettingsOperations()
    XCTAssertEqual(fixture.provider.commands.count, 1)
    XCTAssertEqual(fixture.commits, 0)
    for task in [first, queued] {
      do { _ = try await task.value; XCTFail("Stale account write completed") }
      catch { XCTAssertTrue(error is CancellationError) }
    }
  }

  func testSignedOutAccountWriteNeverReachesTransport() async {
    let fixture = AccountWritesFixture()
    fixture.user = nil
    do {
      _ = try await fixture.feature.updateAccount(.sendVerification)
      XCTFail("Signed-out command succeeded")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(fixture.provider.commands.count, 0)
  }

  func testFacebookConnectMergesOnlyAccountFieldsIntoLatestUser() async throws {
    let fixture = AccountWritesFixture()
    defer { fixture.provider.gate.releaseAll() }
    let request = Task { try await fixture.feature.updateAccount(.facebook("fixture-token")) }
    await fixture.provider.gate.waitFor(1)
    var response = try XCTUnwrap(fixture.user)
    response.facebookConnected = true
    response.needsFreshFacebookToken = false
    response.newsletters.arts = false
    fixture.user?.newsletters.arts = true
    try fixture.provider.gate.finish(0, .success(response))
    _ = try await request.value
    XCTAssertEqual(fixture.user?.facebookConnected, true)
    XCTAssertEqual(fixture.user?.newsletters.arts, true)
  }

  func testRefreshWaitsForAccountWriteBeforeFetchingAndCommitting() async throws {
    let fixture = AccountWritesFixture()
    defer { fixture.provider.gate.releaseAll(); fixture.readProvider.gate.releaseAll() }
    _ = try fixture.feature.startAccountUpdate(.currency("GBP"))
    let refresh = fixture.feature.startAccountRefresh()
    defer { refresh.cancel() }
    await fixture.provider.gate.waitFor(1)
    XCTAssertEqual(fixture.readProvider.gate.count, 0)
    try fixture.provider.gate.finish(0, .success(nil))
    await fixture.readProvider.gate.waitFor(1)
    var response = try XCTUnwrap(fixture.user)
    response.name = "Fresh account"
    try fixture.readProvider.gate.finish(0, .success(response))
    _ = try await refresh.value
    XCTAssertEqual(fixture.user?.chosenCurrency, "GBP")
    XCTAssertEqual(fixture.user?.name, "Fresh account")
  }

  func testRefreshStartedBeforeAccountEditCannotOverwriteConfirmedWrite() async throws {
    let fixture = AccountWritesFixture()
    defer { fixture.provider.gate.releaseAll(); fixture.readProvider.gate.releaseAll() }
    let stale = try XCTUnwrap(fixture.user)
    let refresh = fixture.feature.startAccountRefresh()
    await fixture.readProvider.gate.waitFor(1)
    _ = try fixture.feature.startAccountUpdate(.currency("GBP"))
    defer { refresh.cancel() }
    await fixture.provider.gate.waitFor(1)
    try fixture.provider.gate.finish(0, .success(nil))
    try fixture.readProvider.gate.finish(0, .success(stale)) // Transport ignores cancellation.
    do { _ = try await refresh.value; XCTFail("Stale refresh must not return") }
    catch { XCTAssertTrue(error is CancellationError) }
    await fixture.feature.waitForSettingsOperations()
    XCTAssertEqual(fixture.user?.chosenCurrency, "GBP")
    XCTAssertEqual(fixture.commits, 1)
  }
}

@MainActor
private final class AccountWritesFixture {
  var user: User? = .template
  var commits = 0
  var localePreferenceChanges = 0
  let provider = ControlledAccountWritesProvider()
  let readProvider = ControlledPreferencesReadProvider()
  lazy var session = SessionFeature(
    makeProvider: { self.readProvider },
    currentUser: { [weak self] in self?.user },
    updateUser: { [weak self] in self?.user = $0; self?.commits += 1 }
  )
  lazy var feature = SettingsFeature(
    sessionFeature: self.session,
    events: .init(localePreferencesChanged: { [weak self] in self?.localePreferenceChanges += 1 }),
    makeProvider: { self.provider }
  )
}

@MainActor
private final class ControlledAccountWritesProvider: AccountPreferencesProvider {
  func fetchProjectNotifications() async throws -> [ProjectNotification] { throw CancellationError() }
  func saveProjectNotification(_: ProjectNotification) async throws -> ProjectNotification { throw CancellationError() }
  let verifications = AccountRequestGate<EmailVerificationResponseEnvelope>()
  let emails = AccountRequestGate<GraphUser>()
  func verifyEmail(token _: String) async throws -> EmailVerificationResponseEnvelope {
    try await self.verifications.request()
  }

  let gate = AccountRequestGate<User?>()
  var commands: [SettingsFeature.AccountChange] = []
  var preferences: [User] = []
  func updateAccount(_ change: SettingsFeature.AccountChange) async throws -> User? {
    self.commands.append(change)
    return try await self.gate.request()
  }

  func saveAccountPreferences(_ user: User) async throws -> User { self.preferences.append(user); return user }
  func fetchEmailUser() async throws -> GraphUser { try await self.emails.request() }
}

@MainActor
private final class ControlledPreferencesProvider: AccountPreferencesProvider {
  func fetchProjectNotifications() async throws -> [ProjectNotification] { throw CancellationError() }
  func saveProjectNotification(_: ProjectNotification) async throws -> ProjectNotification { throw CancellationError() }
  func verifyEmail(token _: String) async throws
    -> EmailVerificationResponseEnvelope { throw CancellationError() }
  func updateAccount(_: SettingsFeature.AccountChange) async throws -> User? { throw CancellationError() }
  func fetchEmailUser() async throws -> GraphUser { throw CancellationError() }
  let gate = AccountRequestGate<User>()
  var sent: [User] = []
  func saveAccountPreferences(_ user: User) async throws -> User {
    self.sent.append(user)
    return try await self.gate.request()
  }

  func succeed(_ index: Int) throws {
    guard self.sent.indices.contains(index) else { XCTFail("Missing save"); return }
    try self.gate.finish(index, .success(self.sent[index]))
  }
}

@MainActor
private final class ControlledPreferencesReadProvider: SessionProvider {
  func registerDeviceToken(_: String) async throws {
    XCTFail("Unexpected device registration")
    throw CancellationError()
  }
  func fetchGraphUserSetup() async throws -> GraphUserSetup { throw CancellationError() }
  let gate = AccountRequestGate<User>()
  func fetchCurrentUser() async throws -> User { try await self.gate.request() }
  func fetchGraphUser() async throws -> User { throw CancellationError() }
  func clearActivityIndicator() async throws -> Int { throw CancellationError() }
}

@MainActor
private final class ApplicationSettingsFixture {
  var configuration: Config?
  var currentCountryCode: String?
  let store = MockKeyValueStore()
  let center = NotificationCenter()
  let responses = AccountRequestGate<Config>()
  var remoteClient: (any RemoteConfigClientType)?
  var statsigClient: (any StatsigClientType)?
  var savedOverrides: [Config] = []
  var appliedConfigurations: [Config] = []
  var activationEvents: [String] = []

  init(configuration: Config? = .template, currentCountryCode: String? = nil) {
    self.configuration = configuration
    self.currentCountryCode = currentCountryCode
  }

  private lazy var configurationService = ApplicationConfigurationService(
    load: { [weak self] in
      guard let self else { throw CancellationError() }
      return try await self.responses.request()
    },
    debugFeatureFlags: { [weak self] in self?.configuration?.features ?? [:] },
    applyConfiguration: { [weak self] configuration in
      self?.configuration = configuration
      self?.appliedConfigurations.append(configuration)
    }
  )

  lazy var feature = SettingsFeature(
    sessionFeature: SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) }),
    applicationSettings: SettingsFeature.ApplicationSettings(
      configuration: self.configurationService,
      remoteConfiguration: RemoteConfigurationService(notificationCenter: self.center),
      readConfiguration: { [weak self] in self?.configuration },
      currentCountryCode: { [weak self] in self?.currentCountryCode },
      saveConfigurationOverride: { [weak self] configuration in
        self?.configuration = configuration
        self?.savedOverrides.append(configuration)
      },
      userDefaults: { [store = self.store] in store },
      remoteClient: { [weak self] in self?.remoteClient },
      statsigClient: { [weak self] in self?.statsigClient },
      installRemoteClient: { [weak self] client in
        self?.remoteClient = client
        self?.activationEvents.append("installed")
      },
      notificationCenter: self.center
    ),
    makeProvider: { AsyncAccountPreferencesProvider(service: MockService()) }
  )
}

private final class SettingsActivationClient: MockRemoteConfigClient {
  private let performActivation: @MainActor () async throws -> Void

  init(activate: @escaping @MainActor () async throws -> Void) {
    self.performActivation = activate
    super.init()
  }

  override func fetchAndActivateAsync() async throws { try await self.performActivation() }
}
