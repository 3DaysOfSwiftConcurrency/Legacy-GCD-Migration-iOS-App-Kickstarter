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
