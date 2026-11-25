# Kickstarter code readability ledger

Maintained by Matthew Thomas.

This is a separate, behaviour-preserving readability programme. It does not
reopen or replace the completed CFA migration ledger.

## Scope

- AppModel and its composition, navigation and supporting extensions.
- Each named AppModel Feature and its directly related Views, ViewModels,
  workers and focused tests.
- Preserve product behaviour, public routes, stored values, analytics,
  accessibility identifiers and target membership.

## Baseline

- Revision: `d9259e262` — verified CFA migration completion.
- AppModel Feature folders: Activity, Authentication, CreatorDrafts,
  DeveloperExamples, Discovery, Discussion, Friends, Help,
  Messaging, Onboarding, Payments, Pledge, PledgedProjects, Profile,
  ProjectDetails, ProjectMedia, ProjectReporting, Recommendations,
  RemoteConfiguration, Rewards, Search, Session and Settings.

## Completed slices

- AppModel deep-link resolution: renamed destination-producing APIs and the
  stale-session guard to explain their action and result. Updated every known
  caller and deep-link test. A generic iOS Simulator `Library-iOS` build passed
  with `CODE_SIGNING_ALLOWED=NO`; its existing extension-version and
  Crashlytics-script warnings remain. Focused runtime tests are pending because
  this Mac's CoreSimulator service remains unavailable after routine recovery.
- AppModel account refresh: renamed the emitted update, delivery label, setup
  check and notification method so the account-refresh sequence reads in order.
  Updated AppDelegate and presentation-test callers. The same generic
  `Library-iOS` build passed with the existing project warnings; focused runtime
  tests remain pending on the unavailable CoreSimulator service.
- AppModel lifecycle coordination: renamed the active-state signal, ubiquitous
  preference synchronisation and session-change reset API to name their actual
  effects. Updated AppDelegate and AppModel-test callers. The generic
  `Library-iOS` build passed with the same existing project warnings; focused
  runtime tests remain pending on the unavailable CoreSimulator service.
- Activity Feature: renamed public feed and survey operations, retained task
  handles, pagination state and related presentation callers so every name says
  which Activity data it coordinates. Updated focused feature tests. The
  generic `Library-iOS` build passed with the same existing project warnings;
  focused runtime tests remain pending on the unavailable CoreSimulator service.

- AppLifecycle verification: AppModel and AppDelegate handle lifecycle work.
  The migrated project has no AppLifecycle Feature to review.
- Authentication Feature (baseline `b68a2f377`): clarified the operations that
  resolve or cancel an email redirect, request a password reset, and request a
  new two-factor code. Named the authentication attempt and verification
  request state. Updated AppModel, the password-reset and two-factor ViewModels,
  and focused Authentication tests. Swift parsing, caller scans and
  `git diff --check` passed. Xcode could not resolve Swift package manifests
  under the session sandbox, so the signing-disabled generic `Library-iOS`
  build did not reach compilation. CoreSimulator refused connections after
  routine recovery, so focused runtime tests did not run.
- AppModel final pass: named the once-only launch work guard and the synchronous
  notification and tracking permission preparation. Checked AppDelegate and AppModel
  test callers. Swift parsing and git diff --check passed. The signing-disabled generic
  Library-iOS simulator build was blocked during Swift package resolution.
  AppModelTests could not run because CoreSimulator refused connections.
- CreatorDrafts: loadDraft, saveDraft, uploadDraftImage and removeDraftImage
  distinguish the edit outcomes. Named the queue tail, session guard and preview
  availability. Updated the Update Draft ViewModel and CreatorDrafts tests. Swift
  parsing and git diff --check passed. The signing-disabled generic Library-iOS
  simulator build was blocked during Swift package resolution.
  CreatorDraftsFeatureTests and UpdateDraftViewModelTests could not run because
  CoreSimulator refused connections.
- DeveloperExamples: named the pagination and rich-text snapshots, pending requests,
  and project lookup by slug or URL. Updated the example ViewModel and focused lookup
  tests. Swift parsing and git diff --check passed. The signing-disabled generic
  Library-iOS simulator build was blocked during Swift package resolution.
  DeveloperExamplesFeatureTests and the pagination and rich-text ViewModel tests could
  not run because CoreSimulator refused connections.
- Discovery: distinguished the recommendation availability fetch from its delivery task
  and named the activity sample's last-seen update. Updated the Discovery page
  ViewModel. Reviewed availability, session replacement and pagination tests. Swift
  parsing and git diff --check passed. The signing-disabled generic Library-iOS
  simulator build was blocked during Swift package resolution. DiscoveryFeatureTests
  and Discovery page ViewModel tests could not run because CoreSimulator refused
  connections.
- Discussion: named the occupied post request slots and queued continuations.
  Distinguished comment-posting tasks from author-blocking tasks. Checked comment
  presentation callers and the five-request limit tests. Swift parsing and git diff
  --check passed. The signing-disabled generic Library-iOS simulator build was blocked
  during Swift package resolution. DiscussionFeatureTests and comment ViewModel tests
  could not run because CoreSimulator refused connections.
- Friends: userWithCachedFollowingStatus explains the returned user. Named the cached
  values and the newest queued follow write per session. Updated Find Friends, Activity
  follow cells, and focused tests. Swift parsing and git diff --check passed. The
  signing-disabled generic Library-iOS simulator build was blocked during Swift package
  resolution. FriendsFeatureTests and follow cell ViewModel tests could not run because
  CoreSimulator refused connections.
- Help: makeWebRequest identifies the URL request constructed for a help destination.
  The Help Web ViewModel names its configured page request. Updated the controller and
  both focused test suites. Swift parsing and git diff --check passed. The signing-
  disabled generic Library-iOS simulator build was blocked during Swift package
  resolution. HelpFeatureTests and HelpWebViewModelTests could not run because
  CoreSimulator refused connections.
- Messaging: named searchMessageThreads for the results the search screen receives, the
  retained mailboxes by route, and the session guard against obsolete results. Reviewed
  mailbox, search, and send tests. Swift parsing and git diff --check passed. The
  signing-disabled generic Library-iOS simulator build was blocked during Swift package
  resolution. MessagingFeatureTests and message search tests could not run because
  CoreSimulator refused connections.
- Onboarding: named push authorization tasks and delayed tracking checks. Specified
  that activation state belongs to the app and that scheduling compares it against the
  last handled activation signal. Reviewed the onboarding screen and focused prompt-
  sharing tests. Swift parsing and git diff --check passed. The signing-disabled
  generic Library-iOS simulator build was blocked during Swift package resolution.
  OnboardingFeatureTests and OnboardingViewModel tests could not run because
  CoreSimulator refused connections.
- Payments: named the two card setup intent entry points by destination. Clarified the
  newest queued card write and its revision. Updated the payment settings and pledge
  card ViewModels and setup context tests. Swift parsing and git diff --check passed.
  The signing-disabled generic Library-iOS simulator build was blocked during Swift
  package resolution. PaymentsFeatureTests and payment methods ViewModel tests could
  not run because CoreSimulator refused connections.
- Pledge: named the newest queued write per session, the in-flight write tasks, and the
  latest read request ID per route. Reviewed backing refresh, checkout, and
  cancellation callers and tests. Swift parsing and git diff --check passed. The
  signing-disabled generic Library-iOS simulator build was blocked during Swift package
  resolution. PledgeFeatureTests and checkout ViewModel tests could not run because
  CoreSimulator refused connections.
- PledgedProjects: named loadNextPage, the internal page request, and the retained
  page-load tasks. Updated the overview ViewModel and focused pagination tests. Swift
  parsing and git diff --check passed. The signing-disabled generic Library-iOS
  simulator build was blocked during Swift package resolution.
  PledgedProjectsFeatureTests and PPOViewModel tests could not run because
  CoreSimulator refused connections.
- Profile: named the returned avatar bytes and the request cancelled when the profile
  icon changes. Identified the current avatar request by ID. Updated RootViewModel and
  focused avatar tests. Swift parsing and git diff --check passed. The signing-disabled
  generic Library-iOS simulator build was blocked during Swift package resolution.
  ProfileFeatureTests and RootViewModel avatar tests could not run because
  CoreSimulator refused connections.
- ProjectDetails: named the project link context resolver and distinguished attribution
  tasks retained for a route from those still running. Updated AppModel's deep-link
  caller and reviewed project page and attribution tests. Swift parsing and git diff
  --check passed. The signing-disabled generic Library-iOS simulator build was blocked
  during Swift package resolution. ProjectDetailsFeatureTests and deep-link tests could
  not run because CoreSimulator refused connections.
- ProjectMedia: named the playback preparation requests and cancel action, plus the
  video-feed save tasks. Updated the project page ViewModel and focused preparation
  tests. Reviewed watch and feed callers. Swift parsing and git diff --check passed.
  The signing-disabled generic Library-iOS simulator build was blocked during Swift
  package resolution. ProjectMediaFeatureTests and video feed ViewModel tests could not
  run because CoreSimulator refused connections.
- ProjectReporting: named the fetched report options and contact email, the reporting-
  session guard, and the queued submission. Updated the info and form ViewModels and
  the focused stale-session tests. Swift parsing and git diff --check passed. The
  signing-disabled generic Library-iOS simulator build was blocked during Swift package
  resolution. ProjectReportingFeatureTests and reporting ViewModel tests could not run
  because CoreSimulator refused connections.
- Recommendations: named the recommendation request shared by Curated Projects and
  Thanks, and the tracked route and load tasks. Updated both ViewModels and focused
  route and replacement tests. Swift parsing and git diff --check passed. The signing-
  disabled generic Library-iOS simulator build was blocked during Swift package
  resolution. RecommendationsFeatureTests and recommendation ViewModel tests could not
  run because CoreSimulator refused connections.
- RemoteConfiguration: named the injected Firebase Remote Config client and the NSError
  used to filter activation failures. Reviewed the Settings integration, flag tools
  ViewModel, and remote configuration tests. Swift parsing and git diff --check passed.
  The signing-disabled generic Library-iOS simulator build was blocked during Swift
  package resolution. RemoteConfigurationServiceTests and
  RemoteConfigFeatureFlagToolsViewModelTests could not run because CoreSimulator
  refused connections.
- Rewards: named the project reward load and its task-returning request. Identified
  shipping selectors separately from reward collections by route. Updated the
  collection ViewModel and focused reward tests. Swift parsing and git diff --check
  passed. The signing-disabled generic Library-iOS simulator build was blocked during
  Swift package resolution. RewardsFeatureTests and rewards collection ViewModel tests
  could not run because CoreSimulator refused connections.
- Search: named the pending results request, next page cursor, and first-query flag
  that controls debouncing. Reviewed search and filter presentation callers and the
  debounce and pagination tests. Swift parsing and git diff --check passed. The
  signing-disabled generic Library-iOS simulator build was blocked during Swift package
  resolution. SearchFeatureTests and SearchLookupTests could not run because
  CoreSimulator refused connections.
- Session: distinguished account-session changes from user and setup read invalidation,
  and named the latest queued device registration. Reviewed login, root tabs, and
  focused session replacement tests. Swift parsing and git diff --check passed. The
  signing-disabled generic Library-iOS simulator build was blocked during Swift package
  resolution. SessionFeatureTests and session-related AppModel tests could not run
  because CoreSimulator refused connections.
- Settings: distinguished the refresh debounce, active account refresh and account
  setup tasks. Named the latest queued account write and its read and write tasks.
  Reviewed AppModel, account screens, and focused settings tests. Swift parsing and git
  diff --check passed. The signing-disabled generic Library-iOS simulator build was
  blocked during Swift package resolution. SettingsFeatureTests and
  SettingsProjectNotificationsTests could not run because CoreSimulator refused
  connections.

## Programme status

The source review covers AppModel and all 23 tracked Feature areas, including
the earlier Activity checkpoint. All 61 modified Swift files parse. The final
Swift token comparison found identical string literal segments and
identifier-only changes outside Authentication. Authentication additionally
passes its existing login/resend operation explicitly and names the pending
attempt before awaiting it. The migration ledger, behaviour contract and
Xcode project match the baseline.

Full Xcode verification remains pending. The project declares the requested
`Library-iOS` scheme. Xcode's scheme discovery and generic simulator builds
stopped during package manifest resolution under the session sandbox. The
focused test dry run could not reach destination validation, and CoreSimulator
still refused connections after routine recovery.

The readability checkpoints are committed locally. Push attempts to
`origin/migration/cfa-swift-concurrency` failed because this session could not
resolve `github.com`.

## Model file naming pass

Baseline: `55a4ff161`. Scope is each Swift file under `2 - AppModel` and any
callers or tests affected by a rename.

- AppModel, navigation and composition. Named persisted environment values, restored
  environment, allowed route keys, and the publisher that maps output to Void. Traced
  its PPOContainer caller and reviewed environment and navigation tests. Swift
  parsing, Swift token comparison and git diff --check passed.

- Configuration, networking and platform storage. Distinguished pending config fetches
  from SDK activation, cached avatar bytes from downloaded bytes, and reachability
  monitoring from its consumer state. Updated Authentication, Profile and focused
  redirect and avatar tests. Swift parsing, Swift token comparison and git diff
  --check passed.

- Analytics storage and adapters. Named the attribution JSON payload, notification
  bytes in identity Codable methods, checkout tracking properties, and the Braze
  integration key. Checked attribution callers and checkout and identity tracking
  tests. Swift parsing, Swift token comparison and git diff --check passed.

- Authentication and Discovery helpers. Named password length and email format inputs,
  the authorization code and PKCE values, and the lookup that resolves a category or
  subcategory from a deep link. Reviewed OAuth and discovery routing tests. Swift
  parsing, Swift token comparison and git diff --check passed.

- Activity, CreatorDrafts, DeveloperExamples, Discussion, Friends, Messaging and
  Onboarding. Named state by the account or route it belongs to, and retained tasks by
  their actions. Reviewed focused feed, queued edit, pagination, comment, follow,
  mailbox and permission tests. Swift parsing, Swift token comparison and git diff
  --check passed.

- Payments and Pledge. Named the initial card-selection snapshot, selected payment
  source, pledge presentation inputs, setup-intent secret, current plan request ID and
  scheduled collection date. Reviewed card-selection, payment-method and Pledge Over
  Time tests. Swift parsing, Swift token comparison and git diff --check passed.

- PledgedProjects, Profile, ProjectDetails, ProjectMedia, ProjectReporting and
  Recommendations. Named the parsed card action, project and profile route state,
  referral cookie parts, playback readiness values, and the recommendations freshness
  guard. Traced focused cache, project card, attribution, reporting and media tests.
  Swift parsing, Swift token comparison and git diff --check passed.

- RemoteConfiguration, Rewards, Search, Session and Settings. Named mock flag values,
  configured reward token state, the shared category load, filter toggle
  initialization, device registration delivery, and notification and email requests.
  Reviewed focused category, reward, flag, session and settings tests. Swift parsing,
  Swift token comparison and git diff --check passed.

- Final helper review. Named the accumulated URL match, route destination builder,
  decoded routing parameters, mock timestamp, audio observer and audio reset IDs, and
  initialized search filter fields. Reviewed navigation and audio-controller test
  paths. Swift parsing, Swift token comparison and git diff --check passed.

Reviewed names across 159 tracked AppModel Swift files. The pass changed
identifiers in 49 model files and six caller or test files. The aggregate
Swift token comparison matched every non-identifier token and string literal
segment against the baseline. Source parsing, renamed caller scans and
`git diff --check` passed. The migration ledger, behaviour contract and Xcode
project match the baseline.

A standalone Swift type check passed for nine sources using the simulator SDK
and the project's `IsolatedDefaultValues` setting. It emitted the existing
SystemConfiguration deprecation warnings. The signing-disabled generic
`Library-iOS` build and focused test dry run stopped during package manifest
resolution with a sandbox permission error. CoreSimulator still refused
connections, so runtime tests remain unverified. Push remains pending because
this session could not resolve `github.com`.

## Exhaustive declaration review (open)

The preceding file-level naming pass was not a per-declaration review. A new
SwiftSyntax inventory in `READABILITY_NAME_REVIEW.md` enumerates 1,407 functions
and initializers plus 1,617 stored or computed properties across all 159 Swift
files in `2 - AppModel`. Every declaration is currently marked pending until
its behaviour, callers, local names and keep/rename reason have been recorded.
The 23 Feature areas take priority; three files contain enum cases but no
function or property declarations. Reconcile counts after the last code edit.

The earlier uncommitted Session change replaces `request(_:)` with separate
current-user, Graph-user and activity-indicator requests, updating its
presentation, Profile and test callers. This pass further named the awaited
current-user refresh, the operation wrapper, and SessionProvider fetches.
Payments now exposes card fetch, payment-method removal, payment-source creation
and setup/payment-intent creation by name, including its provider and tests.
Settings names account refresh, Recommendations names its load, and the
configuration service names the refresh request. These are code changes,
not evidence that the 3,024-declaration review is complete.

All currently changed Swift files parse and `git diff --check` passes. Xcode
scheme discovery stops during SwiftPM package manifest resolution because the
session cannot write its user cache. Temporary package, derived-data and module
caches did not remove the manifest-cache denial. An unrestricted Xcode command
was automatically rejected by this session's approval policy. The final build
and focused runtime tests have therefore not run; the code and naming pass must
not be marked complete or committed as a verified checkpoint. Next: complete
each per-declaration decision, reconcile all 159 target files and callers,
then compile and run focused tests at the final revision.

Final-revision build attempt: `xcodebuild -project Kickstarter.xcodeproj
-scheme Library-iOS -destination 'generic/platform=iOS Simulator'
-derivedDataPath /tmp/kickstarter-derived-data -packageCachePath
/tmp/kickstarter-package-cache -clonedSourcePackagesDirPath
/tmp/kickstarter-source-packages CODE_SIGNING_ALLOWED=NO build`, with temporary
XDG, Clang and SwiftPM module caches. Exit 74 during package resolution;
SwiftPM could not write `~/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading`.
No app source reached compilation. Re-run this build and focused tests once
Xcode can write its caches; parsing success is not a build result.

Xcode's 25 November 16:29 `Library-iOS` build reached compilation and reported
seven errors: two `SessionFeature.sessionBound` callers in
`SettingsLinkPresentation`, two internal `PaymentsFeature.setup` calls and
three dependent type-inference diagnostics. Repaired those five stale calls
immediately, including the matching Session test call found by a whole-repo
search. No old `sessionBound`, `setup(projectID:)`, `requestIntent`,
`refreshSetup` or `invalidateReads` references remain in first-party Swift.
All changed Swift files parse and `git diff --check` passes. A new final Xcode
build is still required; the restricted terminal cannot write SwiftPM's user
manifest cache, so this repair is not yet reported as compile-verified.
The Toolkit's executable rename-build gate was run against `Library-iOS` after
the repair. It exited nonzero during Xcode scheme discovery/package resolution
for the same cache permission failure and wrote no verification evidence.

The developer then built the final source in Xcode at 16:55 on 25 November:
`Library-iOS`, iPhone 17 Pro, Build Succeeded. Xcode's build log
`39E56E2A-3728-4DEA-9D80-028A489AACB9` records zero errors and includes
compilation of the changed app sources. This verifies the repaired app target
at that revision. Warnings remain. The `ApplicationTests` target did not appear
in that build log, so changed test sources and runtime behaviour still need
their own build-for-testing/test verification. The 3,024-declaration naming
review remains open independently of this repaired rename checkpoint.

Xcode's 25 November 17:00 `Library-iOS` Build For Testing reached the
`LibraryTests` target and failed with six `ApplicationConfigurationService`
no-member-`refresh` diagnostics in
`ApplicationTests/Model/Platform/ApplicationConfigurationServiceTests.swift`.
Build log: `9DAF8AAB-F562-4DB5-86F2-75A771F70A34`. Updated all six test
callers to `requestConfigurationRefresh()`, the current service API. The
changed Swift sources parse, and `git diff --check` passes. The test target
has not yet been rebuilt after this repair; a passing Build For Testing is
required before this rename checkpoint can be treated as compile-verified.

The developer reran Xcode Build For Testing after the six test-caller fixes.
Build log `3DD20365-5D61-405E-AFE7-354263638797` records a successful
`Library-iOS` build, zero errors, and compilation of `LibraryTests`, including
`ApplicationConfigurationServiceTests.swift`. This verifies compilation of
the repaired source and test targets at this revision. The build recorded 145
warnings; it did not execute runtime tests. Subsequent source edits require a
new build before any rename checkpoint can be called verified again.

## Model-only naming audit (in progress)

The renewed audit covers all 159 Swift files under `2 - AppModel`, including
its 23 Feature areas, composition, navigation, storage, services and workers.
The View layer is outside the naming-review scope; existing View callers and
tests must still be updated if a Model API is renamed. The source-located
inventory in `READABILITY_NAME_REVIEW.md` has 1,407 functions/initializers and
1,617 properties; all 3,024 decisions remain open. A first implementation
triage found additional ambiguous Model APIs. See `MODEL_READABILITY_AUDIT.md`
for the concrete candidates and their observed behavior. This was a discovery
checkpoint, not a completed per-declaration audit or permission to rename
without a fresh build.

Session Feature review: all 60 inventory declarations now have a recorded
action/result, caller context and keep-or-rename reason. Renamed the public
`readGeneration` accessor to `userReadGeneration` and the internal token
ingress from `receiveDeviceToken` to
`scheduleDeviceRegistration(for:onRegistered:)`. The AppModel ingress retains
its own `receiveDeviceToken` name because it receives the application event.
Renamed the environment storage closure `updateSetup` to
`applyGraphUserSetup`; updated its composition and Session tests. A full
first-party Swift scan found no remaining references to the removed Session
members. Source parsing and `git diff --check` pass. Xcode's subsequent
`Library-iOS` Build For Testing log
`E6C199B9-873D-4781-8EAE-DA9A6BEB4E88` compiled app and LibraryTests,
including SessionFeatureTests, with zero errors. Runtime tests have not run.
The Terminal build runner executed the fixed `Library-iOS` Build For Testing
command outside this session's SwiftPM cache restriction. Its initial
`session-runner-smoke` build exited zero and reported `TEST BUILD SUCCEEDED`.
The runner is invoked by a one-time Terminal launch and a request file; no
further developer Xcode clicks are required for ordinary rename checkpoints.

Activity Feature review: all 42 declarations have decisions. The provider now
fetches named Activity pages and unanswered surveys. The public page error and
loading properties identify the page, and project-card click forwarding names
its analytics action. Traced the AppModel, Activity ViewModel, test factory and
provider test implementations; other Features' similarly spelled providers
were left intact. Full-source stale caller scan, Swift parsing and diff checks
passed. The runner's `activity-renames-1` Build For Testing exited zero and
reported `TEST BUILD SUCCEEDED`. Runtime tests have not run.

Help Feature review: all four declarations have explicit keep reasons after
reading the request builder and its Help ViewModel and test callers. No source
change or additional build was required.

ProjectReporting Feature review: all 28 declarations have decisions. Provider
reads and submissions, the public report submission, current reporting context
and submission waiter are now named for their behavior. Updated report
ViewModels and focused tests. Its runner build `reporting-renames-1` exited
zero and reported `TEST BUILD SUCCEEDED`; the renamed app and test targets
compile. Runtime tests have not run. Model review remaining: 2,890
declaration decisions.

Recommendations Feature review: all 42 declarations have behavior and naming
decisions. Renamed provider project/category reads, loaded selection by route,
curated and post-backing private loaders, and the waiter for recommendation
loads. Updated Curated and Thanks ViewModels and the provider/Feature tests.
The first `recommendations-renames-1` Build For Testing failed: eleven missed
`RecommendationsFeature.waitForOperations()` calls in CuratedProjects and
Thanks ViewModel tests. Repaired all eleven immediately and searched every
first-party Swift file mentioning RecommendationsFeature for remaining old
waiter calls; only unrelated SettingsFeature calls remain. The runner's
`recommendations-repair-2` Build For Testing exited zero and reported
`TEST BUILD SUCCEEDED`. The repaired app and test targets compile; runtime
tests remain unverified. Remaining inventory decisions: 2,848.

Profile Feature review: all 48 declarations across `ProfileFeature.swift` and
`UserAttribute.swift` have behavior and naming decisions. Provider page reads
now say they fetch a profile projects page; the Feature's refresh, next-page
and task-returning page APIs name the project collection. Updated the backed
and saved projects ViewModel, controlled provider and focused tests. A global
first-party Swift scan found no old Profile page APIs. The runner's
`profile-renames-1` Build For Testing exited zero and reported
`TEST BUILD SUCCEEDED`; app and test targets compile. Runtime tests remain
unverified. Remaining inventory decisions: 2,800.

Friends Feature review: all 58 declarations across `FriendsFeature.swift` and
`FriendsSource.swift` have behavior and naming decisions. Provider reads now
fetch named friends pages and statistics. Public page methods name the Friends
data, while private write methods distinguish starting a follow write from
awaiting one. Updated Find Friends presentation and all identified Feature and
follow-cell test callers. A first-party type-context scan found no old Friends
API callers. The runner's `friends-renames-1` Build For Testing exited zero and
reported `TEST BUILD SUCCEEDED`; app and test targets compile. Runtime tests
remain unverified. Remaining inventory decisions: 2,742.

CreatorDrafts Feature review: all 46 declarations have behavior and naming
decisions. Provider reads and draft/image mutations now name the data and
operation. The private draft dispatcher distinguishes starting an ordered edit
from awaiting it. Updated the UpdateDraft ViewModel and controlled provider
tests. Source scan, Swift parsing and diff checks passed. The runner's
`drafts-renames-1` Build For Testing exited zero and reported
`TEST BUILD SUCCEEDED`; app and test targets compile. Runtime tests remain
unverified. Remaining inventory decisions: 2,696.

DeveloperExamples Feature review: all 61 declarations across
`DeveloperExamplesFeature.swift` and `DebugData.swift` have behavior and naming
decisions. Provider reads now distinguish Discovery pages from rich-text example
projects. Public pagination and direct lookup APIs identify their datasets;
private page admission and cancellation do likewise. Updated Pagination and
RichText ViewModels, the provider conformance in presentation tests and the
Feature tests. A scoped first-party stale-name scan, Swift parsing and diff
checks passed. The runner's `examples-renames-1` Build For Testing exited zero
and reported `TEST BUILD SUCCEEDED`; app and test targets compile. Runtime
tests remain unverified. Remaining inventory decisions: 2,635.

Messaging Feature review: all 63 declarations have behavior, caller and naming
decisions. Provider reads now distinguish mailbox pages, searches, threads and
backings; write methods name message sending and marking a thread read. The
Feature's page, snapshot, route release, reset and thread/backing reads name
their data and effects. Updated the MessageThreads, Messages and MessageDialog
ViewModel callers, deep-link lookup, AppModel reset, the controlled provider
and all identified test callers. The first runner build
`messaging-renames-1` found an argument-label mismatch at the renamed
`mailboxSnapshot(for:)` caller. Fixed the ViewModel and all ten focused test
calls, searched for the old label, then reran Build For Testing as
`messaging-repair-2`. It exited zero and reported `TEST BUILD SUCCEEDED` for
app and test targets. Runtime tests remain unverified. Remaining inventory
decisions: 2,572.

RemoteConfiguration review: all 46 declarations across eleven files have
individual decisions. Most client operations intentionally retain Firebase's
interface names; the flag lookup helper was ambiguous at its call site, so
both overloads are now `remoteConfigFeatureIsEnabled` and its AppEnvironment
caller was updated. A first-party scan found no old helper calls. The runner's
`remote-config-renames-1` Build For Testing exited zero and reported
`TEST BUILD SUCCEEDED`; app and test targets compile. Runtime tests remain
unverified. Remaining inventory decisions: 2,526.

Onboarding review: all 72 declarations across the Feature and its legacy
content use case have decisions. Public names now distinguish persisted
onboarding completion, fetching notification status, requesting a system
authorization prompt, and starting push registration. Internal launch and
badge methods name their timing and effects. Updated AppModel, AppDelegate,
the Onboarding ViewModel, and the Feature, AppModel and application routing
tests. A first-party stale caller scan found only the separate AppModel-level
`refreshNotificationAuthorization` method, which remains correctly named for
its own delegation. The runner's `onboarding-renames-1` Build For Testing
exited zero and reported `TEST BUILD SUCCEEDED` for app and test targets.
Runtime tests remain unverified. Remaining inventory decisions: 2,454.

Discussion Feature review: all 95 declarations have decisions. Provider names
now distinguish comment/reply page reads, project/update context reads, comment
submissions and user blocks. The public `post` action became `submitComment`;
Task-returning APIs state they start comment submissions, blocks or Discussion
page/context loads, while async counterparts say they await those reads.
Updated the Comments, Replies, Update, ProjectUpdates and Messages ViewModels,
both controlled provider conformances, Feature tests and deep-link tests. A
first-party caller scan left only identically spelled methods on unrelated
Features and the ViewModel's own pagination methods. The runner's
`discussion-renames-1` Build For Testing exited zero and reported
`TEST BUILD SUCCEEDED` for app and test targets. Runtime tests remain
unverified. Remaining inventory decisions: 2,359.

Messaging API refinement: the four Task-returning calls now say they start
mailbox page loading, message sending or thread read-status changes. Updated
the MessageThreads, MessageDialog and Messages ViewModels and focused tests;
the old member spellings have no remaining first-party Swift callers. The
runner's `messaging-task-name-refinement-1` Build For Testing exited zero and
reported `TEST BUILD SUCCEEDED` for app and test targets. This revises four
existing Messaging decisions, so the reviewed declaration count remains 665.

Discovery Feature review: all 83 declarations across the Feature and deep-link
extension have decisions. Provider methods now name Discovery page and activity
sample reads. The awaiting page/sample APIs and Task-returning page refresh,
pagination and activity sample APIs distinguish result loading from starting
work. Updated DiscoveryPageViewModel, four provider conformances, focused tests
and deep-link category loading. The initial `discovery-renames-1` build ran
while the caller update was incomplete and reported three stale ViewModel
calls. Repaired the calls, verified no old Discovery method spelling remained
in first-party type context, then reran `discovery-repair-2` Build For Testing.
It exited zero and reported `TEST BUILD SUCCEEDED` for app and test targets.
Runtime tests remain unverified. Remaining inventory decisions: 2,276.
