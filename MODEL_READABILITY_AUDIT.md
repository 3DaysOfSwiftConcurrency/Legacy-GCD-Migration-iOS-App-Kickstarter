# Kickstarter AppModel readability audit

Maintained by Matthew Thomas. Scope: all source under `Kickstarter-iOS/2 -
AppModel`, excluding `1 - View` from naming review. View callers and tests
remain part of the caller closure for any later Model rename. This audit does
not change the completed CFA migration record.

## Coverage and verification

The refreshed SwiftSyntax inventory in `READABILITY_NAME_REVIEW.md` enumerates
159 AppModel Swift files: 156 containing 1,407 functions/initializers and
1,617 properties, plus three with no such declarations. Each of the 3,024
rows now has a recorded naming and behavior decision, including the Feature
boundary and the rest of AppModel. Source locations, signatures and owners
were reconciled against the final SwiftSyntax scan; the declaration count
remains 3,024. Conditional compilation branches are included. The final
app/test target Build For Testing result is recorded in the ledger. A subsequent
independent pass clarified cancellation names in Discovery and configuration
settings and passed another complete Build For Testing. Runtime
tests remain unverified. This is a naming audit, not a guarantee that every
reader will agree with each judgment; further naming issues can still be
raised as concrete examples.

The `Library-iOS` app and `LibraryTests` targets are compiled after each
rename checkpoint. The final verification log is noted in `READABILITY_LEDGER.md`.
Warnings remain in the project; runtime test execution and visual behavior are
outside this compile verification.

## Findings from the first implementation review

These were candidates at the start of the audit. Their final decisions and
current names are recorded in the reconciled declaration inventory.

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
