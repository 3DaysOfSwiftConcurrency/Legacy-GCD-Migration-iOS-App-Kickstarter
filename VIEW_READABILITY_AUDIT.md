# Kickstarter View readability audit

Maintained by Matthew Thomas. This is the presentation phase of the separate
readability programme. The Model audit closed first at `e5c71e8d8`; editing
View callers during that phase did not constitute a View review. The completed
CFA migration record remains unchanged.

## Inventory and status

A SwiftSyntax inventory of `Kickstarter-iOS/1 - View` at the start of this phase
found 599 Swift files and 11,640 function/property declarations: 6,510
functions or initializers and 5,130 stored or computed properties. Nine files
have no such declarations; they still require source and target review. This
initial inventory includes conditional compilation branches but does not prove
every file's Xcode target membership. Re-enumerate at the final source revision.

| Area | Files with declarations | Functions / initializers | Properties |
| --- | ---: | ---: | ---: |
| AppDelegate | 1 | 42 | 15 |
| Contextual permission alert | 1 | 3 | 5 |
| Navigation | 2 | 29 | 28 |
| Shared system strings | 2 | 1,835 | 5 |
| Shared Views | 94 | 417 | 352 |
| SwiftUI extensions | 1 | 1 | 0 |
| UIKit extensions | 28 | 76 | 23 |
| Views and ViewModels | 461 | 4,107 | 4,702 |
| **Total** | **590** | **6,510** | **5,130** |

The nine declaration-free files are `Shared Views/DataSource/PledgeRewardsSummarySection.swift`,
`Shared Views/GIFAnimatedImageView.swift`, four `Shared Views/Styles/*Styles.swift`
files (ActivitySample, BarButtonItem, HTMLViewElement, ProjectActivity),
`UIKit Extensions/UIApplication.swift`,
`Views/Comments/Views/CommentTableViewFooterViewModel.swift`, and
`Views/ProjectPage/Views/Cells/ProjectDisclaimerType.swift`.

## Settings link presentation slice

`Navigation/SettingsLinkPresentation.swift` has nine declarations, all reviewed
with the presentation caller (`DeepLinkRouter`), AppDelegate composition and
routing tests. The first-party caller scan identified both navigation test
files and AppDelegate. The delay injection is deliberate: routing tests pause
presentation after a save to check suppression for a replaced session.

| Declaration | Decision and reason |
| --- | --- |
| `settingsFeature` | Keep: identifies the concrete Settings capability. |
| `presentationDelaySeconds` | Rename: states the delay's purpose and unit. |
| `waitForPresentationDelay` | Rename: names the awaited test-controlled timing operation; preserve the injection. |
| `notificationSaveTasks` | Rename: identifies the retained save work rather than unspecified notification work. |
| `emailVerification` | Rename: identifies the one replaceable verification task. |
| `init(settingsFeature:presentationDelaySeconds:waitForPresentationDelay:)` | Rename two labels to match stored dependencies; callers in app and tests updated. |
| `saveNotificationPreference(name:enabled:onComplete:)` | Rename: starts a preference save and reports presentation success. |
| `verifyEmail(token:onComplete:)` | Keep: names the verification and its response callback. |
| `waitForPendingSettingsLinkResponses()` | Rename: test barrier for both notification and email link feedback tasks. |

Within the two actions, `request`, `operation`, `session`, `userID`,
`generation`, `seconds`, `id` and `task` were checked in their immediate
contexts. They identify a Feature task, session-bound operation, stale-session
guard, presentation delay, operation identity and retained task. No additional
local rename was warranted in this slice.

**Settings link checkpoint verified:** the Terminal build runner executed
`xcodebuild -project Kickstarter.xcodeproj -scheme Library-iOS -destination
'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build-for-testing`
after the final code change. `view-settings-1` exited 0 with `TEST BUILD
SUCCEEDED` for the app and test targets. Existing warnings remain. The
restricted process could not run focused routing tests because CoreSimulator
is unavailable here; build-for-testing compiled those tests but did not execute
them. The initial direct build attempt had stopped during package resolution
in the restricted process, so only the Terminal runner's result verifies this
checkpoint.

Remaining View declarations awaiting individual decisions: **11,631**.
This count is provisional until the final-source re-enumeration. Next, close
this Settings link slice with the build, then review the rest of navigation
and proceed screen by screen through the Views, ViewModels, shared views and
extensions. A no-change final View pass and build are required for completion.
