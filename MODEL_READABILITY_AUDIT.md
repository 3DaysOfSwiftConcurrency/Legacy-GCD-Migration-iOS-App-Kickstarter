# Kickstarter AppModel readability audit

Maintained by Matthew Thomas. Scope: all source under `Kickstarter-iOS/2 -
AppModel`, excluding `1 - View` from naming review. View callers and tests
remain part of the caller closure for any later Model rename. This audit does
not change the completed CFA migration record.

## Coverage and verification

The existing SwiftSyntax inventory in `READABILITY_NAME_REVIEW.md` enumerates
159 AppModel Swift files, 1,407 functions/initializers and 1,617 properties
across 23 Feature areas and the rest of the Model. It includes declarations in
extensions and conditional compilation branches. Session, Activity, Help,
ProjectReporting, Recommendations, Profile, Friends, CreatorDrafts and
DeveloperExamples, Messaging, RemoteConfiguration, Onboarding, Discussion and
Discovery, Authentication, Payments, PledgedProjects and the first Pledge
write and read APIs have 1,164 individual behavior, caller and naming decisions.
The remaining 1,860 rows are
pending; the whole Model has
**not** been declared reviewed. The latest Pledge result extractor closure passed
Build For Testing for the app and test targets; runtime tests remain unverified.

The repaired `Library-iOS` app and `LibraryTests` compilation passed in Xcode
on 25 November 2026, build log
`3DD20365-5D61-405E-AFE7-354263638797`, with zero errors and 145 warnings.
This verifies the source *before* any further audit-driven code edits. Runtime
tests have not run. Each later rename needs a complete caller search and a new
build for every affected target.

## Findings from the first implementation review

These are candidates for a naming decision, not instructions for a mechanical
replacement. Proposed names need review against every overload and caller.

| Location | Current API | Observed behavior | Candidate direction |
| --- | --- | --- | --- |
| `Features/Discussion/DiscussionFeature.swift:11,32` | `DiscussionProvider.update(id:project:)` | Calls `service.projectUpdate` and **reads** a project update for a discussion. The verb can be mistaken for a write. | `fetchProjectUpdate(id:project:)`, together with the provider implementation and its consumers. |
| `Features/Discussion/DiscussionFeature.swift:12,35` | `post(input:)` | Submits a comment using `submitDiscussionComment`. | Name the comment submission explicitly, subject to provider and call-site review. |
| `Features/Discussion/DiscussionFeature.swift:13,38` | `block(id:)` | Blocks a discussion user through `blockDiscussionUser`. | Name the user and action in the provider boundary. |
| `Features/Pledge/PledgeFeature.swift:320,335,350` | `create(_:)`, `update(_:)`, `cancel(_:)` | Creates, changes and cancels a **backing**. Callers only learn this from the input type. | `createBacking`, `updateBacking`, `cancelBacking`; reconcile the provider, overloads and tests. |
| `Features/CreatorDrafts/CreatorDraftsFeature.swift:161,176` | private `execute(_:)`, `request(_:state:)` | Admits and queues draft edits, deduplicates equivalent writes, and returns a retained task; `execute` awaits it and checks the current session. | Names should distinguish queue admission from awaiting a draft edit. They are private but still obscure the flow. |
| `Features/Friends/FriendsFeature.swift:205,248` | private `request(_:)`, `execute(_:)` | Queues follow writes per session; `execute` awaits and verifies session freshness. | State the follow-write action and queue/await distinction. |
| `Features/Payments/PaymentsFeature.swift:195` | former private `request(_:operation:)` | Shares equivalent payment operations, sequences card writes and returns a retained task. | Resolved as `startPaymentCommand(_:operation:)`; caller/build closure recorded in the readability ledger. |
| `Features/Pledge/PledgeFeature.swift:233,296` | private `request(_:)`, `execute(_:)` | Queues backing writes in order and awaits them under a session guard. | Name backing-write admission and awaiting. |
| `Features/Settings/SettingsFeature.swift:314,318` | private `request(_:from:)` | Queues an account preference edit; one overload wraps the other. | Name account-preference write admission and remove ambiguity between overloads. |
| `Features/Search/FetchCategoriesUseCase.swift:30,34` | `load()`, `start()` | `start()` returns the category-loading task and may publish cached categories; `load()` awaits it. | Name the categories and whether work is started or awaited. |
| `Features/ProjectDetails/ProjectDetailsFeature.swift:392` | `load(route:param:secretRewardToken:force:)` | Awaits a request for the project page snapshot, with optional reward enrollment. | Name the page being loaded and inspect `requestLoad` and callers together. |
| `Features/Friends/FriendsFeature.swift:125` | `refresh(route:)` | Awaits the friends page request for a route. | Consider `refreshFriendsPage(route:)` if callers need that distinction; compare other `refresh` APIs. |

The declaration inventory also contains repeated `reset()` methods in Feature
types and short `id`/`task` properties in nested pending-work records. These
are **review candidates**, not presumed defects: `id` and `task` can be clear
within a focused `Pending` type, while `reset()` needs its actual effects and
callers checked before changing the contract. A token scan cannot decide this.

## Completion criteria

For every inventory row, read the implementation, its callers and local names;
record the action/result/side effect and a reasoned keep, rename or blocked
decision. Work through all Features first and the rest of AppModel next.
Re-enumerate at the final revision and reconcile the counts, including files
with only enum cases. For each rename, repair every caller across Model, Views
and tests, then build the affected app and test targets after the last edit.
Execute relevant focused tests when available. Only a final green build and
zero unexplained inventory rows can close the whole-Model audit.
