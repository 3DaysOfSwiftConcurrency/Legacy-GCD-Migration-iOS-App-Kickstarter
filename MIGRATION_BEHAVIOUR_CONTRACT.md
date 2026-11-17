# Kickstarter migration behaviour contract

## Application entry and ViewModel boundaries — 17 November 2026

Author: Matthew Thomas. Architecture direction confirmed by the developer.

AppDelegate is a UIKit application entry point, not a View. It has no ViewModel.
Lifecycle events do not constitute a product Feature. AppDelegate forwards app
events to AppModel; AppModel coordinates the relevant Features, which own their
rules, requests and authoritative state. UIKit navigation adapters apply the
resulting presentation actions. Preserve URL, universal-link, push and shortcut
behavior while migrating those responsibilities.

The current source has removed AppDelegateViewModel and AppLifecycleFeature.
DeepLinkRouter currently lives in the navigation layer and is called directly
by AppDelegate. It requests destination and email-redirect resolution through
AppModel. AppModel coordinates the existing Features and returns data;
DeepLinkRouter retains navigation task lifetime and UIKit construction.
AppModel now stores its singleton, concrete Feature references and one private
launch guard. Its live factory constructs lower-level dependencies and passes
Features to its initializer. Global storage and the wider application composition
still require review; this property boundary does not establish full CFA compliance.

## Effective application settings and flag tools — 17 November 2026

Author: Matthew Thomas.

SettingsFeature owns effective configuration reads, supported flag enumeration,
flag overrides, the Settings App Store URL and application-setting refresh/activation
commands. FeatureFlagToolsViewModel and RemoteConfigFeatureFlagToolsViewModel receive
SettingsFeature and retain screen rows and reload timing. Their controllers no
longer write configuration. AppModel forwards launch, foreground, session-reset
and remote-activation intents to SettingsFeature; it no longer stores configuration
services. The retained services provide transport and task lifetime below the Feature.

- Keep the current Environment Config and DebugData as the existing storage
  authority. Settings reads current values through injected storage closures and
  introduces no second Config cache. Preserve DebugData's whole-config precedence:
  a tool override updates DebugData before applying the effective configuration.
- Expose recognized application flags sorted by their raw keys. Preserve unknown
  keys when changing a known flag. A missing Config, missing key or unchanged
  value is a no-op. Each rapid toggle merges into the latest stored configuration,
  including values changed since the tools screen's last reload.
- Preserve the tools' one-second reload delay and replacement of a pending reload.
  A delayed screen snapshot must not suppress or overwrite a later toggle. Publish
  the existing configuration notification after a successful configuration edit.
- Remote-config and Statsig overrides retain their existing user-defaults keys.
  An explicit false override takes precedence over a true SDK value. Preserve
  unrelated stored overrides and read the injected client for each request;
  a client-specific helper must use that client rather than the global instance.
- Prefetches share pending configuration reads without applying them. A refresh
  can promote that shared read to apply its result once. Preserve visitor cookies,
  non-release flag retention and release-mode server flags. Refresh completion
  reads current overrides, including edits made while transport was suspended.
- Session reset replaces the pending application-configuration read. Obsolete
  completion cannot apply its result. Install a remote client synchronously before
  starting activation; equal clients share activation, while replacing a client
  suppresses the prior activation's late success or failure notifications.
- Settings' rating action reads the current App Store URL from its Feature and
  retains its existing empty-string fallback when the URL is absent.
- Post-backing rating eligibility reads that same effective Settings destination.
  Recommendations owns prompt priority and one-time prompt storage through its
  injected platform; a games-newsletter prompt still takes priority over rating.
- Newsletter opt-in policy belongs to SettingsFeature. Preserve the two existing
  country inputs: newsletter Settings uses the configured application country,
  while the post-backing games signup uses the current environment country. Each
  requires the opt-in alert only for `DE`. Both screens obtain save-delivery delay
  from their injected SettingsFeature, without reading the global environment.

Bootstrap/keychain decisions remain independent of AppModel construction. Global
configuration helpers and other consumers are still present; this checkpoint does
not claim that all configuration dependencies have migrated. Executed validation
belongs in the dated migration ledger. Live SDK configuration delivery, device
behavior and visual comparisons remain unverified by this ownership change alone.

## Pledged Projects rollout policy — 17 November 2026

Author: Matthew Thomas.

PledgedProjectsFeature owns the V2/V4 remote rollout decision through its injected
SettingsFeature. Preserve the existing independent behavior:

- V4 takes precedence over V2 when choosing request tiers and empty-state content.
- V2 independently controls the `Backings` list heading and reward-received toggle,
  including when V4 is also enabled.
- With neither flag, request project-alert tiers and retain the existing alert copy.
- Read current policy when admitting a request and when parsing its returned cards.
  A route whose tiers no longer match refreshes rather than appending incompatible data.

PPOViewModel converts the Feature decision into localized heading and empty-state
presentation. PPOView and PPOEmptyStateView render those values and do not read
remote configuration. Card parsing receives the reward-toggle decision explicitly.
Bootstrap keychain decisions remain outside this runtime Feature graph.

## Video-feed availability and connectivity — 17 November 2026

Author: Matthew Thomas.

ProjectMediaFeature decides whether the video feed is available from its injected
SettingsFeature and connectivity source. The effective Statsig decision preserves
the existing precedence: a stored override (including explicit false), then the
injected current Statsig client, then false. Search and Discovery ViewModels receive
domain availability instead of reading global reachability and repeating the rule.
AppModel.live composes the same SettingsFeature and one native connectivity service,
both retained privately by the media Feature. Environment no longer owns reachability
or supplies this policy through a global helper closure. Tests inject their own
settings and connectivity state directly.

- Availability requires the flag and either Wi-Fi or cellular connectivity.
  Offline hides the banner. Checking availability does not fetch the video feed.
- Deliver the initial availability synchronously to initialize the ViewModel,
  while preserving the existing screen-appearance/configuration emission timing.
  Each ViewModel suppresses repeated banner values independently.
- Reevaluate the current flag on every connectivity event, including repeated
  network states, and on explicit configuration/appearance reads. A separate
  cached flag or duplicate filter in the Feature must not hide a current change.
- Multiple screens share one lazily started native monitor. Stopping one screen's
  observation leaves the other active; account/session replacement leaves the
  application-scoped monitor running. Releasing its owner ends the stream.
- Preserve native reachability flag classification, including cellular precedence.
  Keep the platform callback bridge separate from domain eligibility and tests.

## Project-story rich-text policy — 17 November 2026

Author: Matthew Thomas.

ProjectDetailsFeature reads the effective project-story rich-text decision from its
injected SettingsFeature. The effective decision retains the same stored-override,
current Statsig-client, false-fallback precedence as other runtime Statsig settings.
AppModel composes the same SettingsFeature used by the rest of the application; it
does not pass a global rich-text closure.

- Capture the current rich-text decision in each project-request identity and pass it
  to the provider. A changed decision replaces an otherwise equivalent pending read.
- Keep the current decision live for presentation through `includesRichTextStory`;
  do not cache a second flag in ProjectDetailsFeature.
- Rich-text eligibility does not itself decide whether the returned story has rich
  content. Project Page keeps the existing fallback to its table presentation when
  rich content is absent, and still returns to table presentation outside Campaign.
- The independent instant-pledge experiment remains a separate request-loading input;
  moving the rich-text setting does not change its enrollment or fast-loading policy.

## Authentication platform ownership — 17 November 2026

Author: Matthew Thomas.

AuthenticationFeature owns the application-facing authentication capability while
AppModel composes its platform values and analytics transports. Authentication and
LoginViewModel do not read AppEnvironment directly.

- The web base URL remains live and supplies the same help-link matching and Facebook
  confirmation destinations. The Sign in with Apple app ID remains the current API
  service value when credentials are constructed.
- Login page-view tracking still occurs when LoginViewModel loads. Email submit
  tracking still occurs before validating stored form values, preserving keyboard and
  button behavior. Both intents now pass through AuthenticationFeature.
- OAuth submit tracking remains after a complete current result and immediately before
  the single session commit. Shared OAuth callers produce one tracking event, and an
  obsolete or failed result produces none.
- Moving these dependencies does not change redirect ownership, login/resend overlap,
  password-reset behavior, two-factor presentation or session-generation checks.

## Messaging response policy ownership — 17 November 2026

Author: Matthew Thomas.

MessagingFeature receives the mailbox response-delay policy from AppModel at
composition. The delay is captured when a page request is admitted, after transport
success and before publishing the page, exactly as before. Mailbox request sharing,
pagination concatenation, empty-page termination, session invalidation, errors,
search, reads and sends are unchanged.

## Friends response policy ownership — 17 November 2026

Author: Matthew Thomas.

FriendsFeature receives page and statistics response-delay policy from AppModel at
composition. Each read captures the current delay when admitted and applies it after
transport success before publishing. Page and statistics reads remain independent;
page reads still wait for already-admitted follow writes, and follow ordering, shared
Activity state, session invalidation, pagination, errors and retry are unchanged.

## Profile response policy ownership — 17 November 2026

Author: Matthew Thomas.

ProfileFeature receives header and project-page response-delay policy from AppModel
at composition. Header user and graph reads still begin independently and each applies
the captured delay after transport success; a project page does the same before
publishing. Header concurrency and partial-session behavior, per-tab request sharing,
pagination, refresh supersession, session invalidation, errors, retry and avatar task
ownership are unchanged.

## Search timing policy ownership — 17 November 2026

Author: Matthew Thomas.

SearchFeature receives response and debounce timing through a Platform composed by
AppModel. Category and project responses capture the current response delay when a
request is admitted. The first project request remains free of debounce; subsequent
successful queries add the captured debounce, while failures retain response delay
only. Lookup independence, cache behavior, query replacement, request sharing,
pagination, cancellation, output order, errors and retry are unchanged.

Final validation passed 144 focused LibraryTests, the separate Environment
initialization test, 146 bounded PresentationTests and 14 signed Environment
persistence tests on iPhone 17 Pro Max, iOS 26.2, with no failures/skips. Hardware network transitions and banner
snapshot/visual comparisons remain unverified.

## Account device registration — 17 November 2026

Author: Matthew Thomas.

SessionFeature owns associating device tokens with the current account through
SessionProvider. The server endpoint is the current user's iOS push-token resource.
This responsibility is separate from OnboardingFeature's permission and consent
policy; no new Feature or delegate ViewModel is introduced.

- AppDelegate forwards every raw token to Braze in arrival order, preserving the
  existing deferred SDK call, then sends account registration through AppModel.
- Preserve lowercase hexadecimal encoding and the five-second server debounce.
  New tokens replace pending debounce/delivery without retracting an admitted
  server write. Equal pending tokens within one session share a request; distinct
  tokens reach the server in order. Only the latest admitted token publishes success.
- Capture the account ID, session generation and provider at request admission.
  Same-user session replacement cancels pending debounce and delivery. Already
  admitted writes settle before a new session's write; queued obsolete requests
  must not reach the transport or publish a result. Restoring a missing user from
  stored credentials within the same session must retain pending registration
  and share the same token request; a changed known account remains invalid.
- A failed request can retry the same token. Keep failures silent at the native
  application boundary while preserving directly awaitable Feature errors.
- Retain logged-out token handling and native permission behavior. No real push
  token, credential, or live registration is part of the regression evidence.

Final validation passed 79 focused LibraryTests and 146 bounded PresentationTests
on iPhone 17 Pro Max, iOS 26.2, with zero failures/skips. The native callback's
production handler is covered with injected SDK delivery. Actual APNs/Braze
integration and live account registration remain unverified.

## Account refresh and recommendation ownership — 17 November 2026

Author: Matthew Thomas.

AppModel coordinates account refresh through SettingsFeature, SessionFeature and
DiscoveryFeature. It stores no account-refresh coordinator or shortcut service.
AppDelegate receives value events and applies native presentation and SDK updates;
it has no ViewModel. ShortcutItem owns the ordered native shortcut list.

- Launch, foreground and sign-in refresh account/setup data. Sign-out refreshes
  account-dependent presentation without fetching account setup.
- Settings retains refresh debounce and serialization with preference writes.
  Session remains the authority for account identity and committed user values.
  Invalid-token failure retains the guarded logout behavior.
- Discovery recommendation availability is scoped to both account identity and
  session generation. Same-user session replacement cannot share or publish an
  obsolete read. Replacing delivery cancels that waiter, not a shared domain read.
- A session replacement before a pending delivery starts must prevent its request.
  If a user-update consumer changes the session synchronously, AppModel must not
  start the old account's subsequent recommendation workflow.
- Logged-out availability performs no recommendation request. Keep the existing
  failure-to-unavailable behavior and shortcut ordering: recommended, projects we
  love, search when available; otherwise projects we love, search.
- Preserve user-update notifications and the existing deferred UIKit/analytics
  delivery. This checkpoint does not certify native system shortcuts or visual
  behavior, or complete the remaining AppModel composition audit.

The focused baseline passed 77 tests. Final validation passed 188 LibraryTests
and 145 bounded PresentationTests on iPhone 17 Pro Max, iOS 26.2, with no failures
or skips. The Feature and AppModel tests exercise the session boundaries above;
application-routing tests retain the existing notification and shortcut assertions.
Native system shortcut integration and live account operations remain unverified.

## Onboarding and application permission ownership — 17 November 2026

Author: Matthew Thomas.

OnboardingFeature owns onboarding completion, eligibility, notification requests,
tracking-request sharing, delayed consent checks and tracking-status observation.
AppDelegate sends permission preparation, activation and foreground-check intents
through AppModel. The native PushRegistration and AppTrackingTransparency adapters
continue to handle their system APIs. Neither app lifecycle nor AppDelegate is
represented as a Feature or ViewModel.

- Preserve launch/foreground badge clearing, standard alert/sound/badge options,
  onboarding eligibility, registration after a grant, and consent-status delivery
  to the existing analytics SDK handlers.
- Start automatic tracking checks only after preparation and activation. Keep the
  existing one-second delay, onboarding-completion check, advertising-ID check
  and native authorization-status check. Read completion when the delay finishes.
- An application request and an onboarding request share one pending prompt of
  the same kind. Notification requests with different options remain serialized.
  Cancelling a screen's observation does not retract an admitted native prompt.
- Replacing or removing the tracking adapter stops delivery from the old adapter.
  Keep these permissions application-scoped across account/session replacement.
- Permission preparation remains synchronous and starts owned work without
  waiting for the native prompt or blocking root UI construction.

The baseline passed 23 focused tests. The final selection passed 28 LibraryTests
and 145 bounded PresentationTests on iPhone 17 Pro Max, iOS 26.2, with no failures
or skips. OnboardingFeatureTests covers both application/screen overlaps and
prompt lifetime; AppModelTests covers forwarding to an injected Feature.
Native ATT/APNs permission UI, live push delivery and visual parity remain
unverified. This checkpoint does not complete the wider migration.

## Deep-link model coordination — 17 November 2026

Author: Matthew Thomas.

- Keep configured-host URL matching, application/Braze source differences, browser
  fallback, push and shortcut destination mapping, and synchronous delegate replies.
- Project links require the complete requested project/update/reply context before
  UIKit builds the destination. A prelaunch project exposes its root only and must
  not start requests for private subresources.
- Equivalent pending links within one route share resolution. A new destination,
  route release, caller cancellation or session replacement prevents obsolete
  navigation, including results delivered after cancellation by a transport.
- A cancelled model caller must not start a Feature request. A survey failure
  after session replacement is treated as cancellation; a new request may succeed.
- Discovery retains category/subcategory matching and the response delay captured
  at admission. Settings writes retain their independent completion lifetime.

AppModelTests directly covers cancellation before request admission and a late
survey failure followed by a successful new-session request. DeepLinkRouterTests
covers shared chains, replacement, session changes, prelaunch restrictions,
redirects and delivery validity. ApplicationRoutingTests and Root Tabs tests cover
the existing navigation and UIKit handoff. The final runs passed 86 LibraryTests
and 145 PresentationTests on iPhone 17 Pro Max, iOS 26.2, with no failures or skips.
Live system URL/push delivery and visual transition parity remain unverified.

## Project Page related projects — 17 November 2026

Author: Matthew Thomas.

- Opening a project shows a loading state until its related-project request
  succeeds or fails; an empty successful result remains distinct from a failure.
- Refreshing the same project within the same session retains its completed
  related projects without issuing another related-project request.
- Opening another project cannot display the previous project's recommendations
  as the new project's result. The new request displays its own loading/error state.
- A session change clears the prior recommendations and reloads them even when
  the project ID is unchanged. Superseded requests cannot publish a late outcome.
- Selecting a related project delivers the existing project navigation output.
- ProjectPageViewModel derives these presentation states from ProjectDetailsFeature;
  the Feature owns the request and result for the page's route.

The focused main-module run passed 106 tests and the bounded regression run passed
89 tests on iPhone 17 Pro Max, iOS 26.2, with no failures or skips. This verifies
controlled page/Feature behavior; live networking and rendered visual parity
remain unverified. See the matching checkpoint in MIGRATION_LEDGER.md.

## Pledge mutation transport snapshot contract — 29 October 2026

Author: Matthew Thomas. 29 October 2026.

Pledge and backing-management ViewModels continue to use their existing AppModel
Features. Native Service submitPledge, revisePledge, cancelPledge, openPledgeCheckout,
confirmPledgeAddress and setPledgeReceipt now map generated GraphQL responses on the
Apollo callback executor, before returning through the asynchronous continuation.
Only existing checked Sendable envelopes, Bool and Void cross into the awaiting actor.
No generated GraphQL type gains Sendable or unchecked conformance.

Preserve input construction, existing omitted cancellation-note behavior, SDK queue,
GraphQL-error priority, missing-data/invalid-envelope errors, token cancellation and
no automatic retry. Address success defaults to false for absent payload; receipt
acknowledgement still compares the returned value to the requested value. No server
accepted write can be undone by local cancellation.

The SDK executor remains its existing native callback queue; this patch does not add
GCD work. Existing mapped-bridge tests cover duplicate callbacks, cancellation and
error precedence. New typed-envelope tests check checkout/authentication fields and
missing-checkout rejection. These tests do not exercise live pledge/payment mutations.

Other generated-response query/checkout completion providers and UI protocol isolation
remain open. Public ServiceType APIs are unchanged; legacy generic bridges remain for
callers that still require individual conversion.

## PaymentSheet and Apple Pay token contract — 29 October 2026

Author: Matthew Thomas. 29 October 2026. Local draft.

Routes remain PaymentMethodSettings/PledgePaymentMethods controllers -> their existing
ViewModels -> AppModel PaymentsFeature -> native services. Pledge delegates continue
to deliver token values to PledgeViewModel/PledgeFeature. UIKit layout, navigation,
card persistence and payment/business decisions are unchanged in scope.

PaymentSheetOperation owns one asynchronous presentation observation from load to
selection, confirmation and optional setup-intent enrichment. StripePaymentSheetClient
owns its non-Sendable UI resource on MainActor. Equivalent pending client secrets
share one flow; conflicting secrets fail explicitly rather than replace an admitted
native confirmation. Events are checked Sendable values; generated SDK objects never
enter the event stream. Only the expected phase accepts a callback, including duplicates.

Permanent departure, owner release and session replacement suppress obsolete work.
Temporary Stripe presentation does not cancel the operation. Editing/deleting cards
or changing pledge modals cancels preparation only; an already-presented confirmation
is not silently canceled by that preparation signal. SDK operations have no cancellation
handle; canceling observation does not undo an accepted setup/payment or trigger retry.

Settings load errors show their existing banner; confirmation failures also notify
failedToAddNewCard. Selection cancellation is distinct from confirmation cancellation.
Pledge flows still add the card when optional payment-method-ID retrieval fails.

ApplePayTokenOperation owns token observation and one PassKit reply. Cancellation or
owner release finishes the wait and replies failure even if Stripe never calls back.
Only the current controller/session may send a token to the ViewModel. An overlapping
authorization receives failure without starting a second token request. Native SDK
tokens are reduced to String/error values in the callback. Token success/failure and
existing ViewModel status calculation remain unchanged.

Pinned SDK evidence: PaymentSheetLoader.load executes Task { @MainActor in }; the
FlowController creation completion executes directly in that loader completion.
Payment-option dismissal is UIKit-owned. FlowController.confirm explicitly asserts
main-thread invocation. Stripe API setup-intent retrieval maps only paymentMethodID
inside its callback. Callback protocols are retained only for native SDK integration.
The older PassKit delegate's missing actor annotation is not hidden with preconcurrency;
complete diagnostics remain a separate audit gate.

Native SDK UI, live cards, Apple Pay/3DS, physical-device and full visual parity are
not validated by fake-client lifetime tests. Existing snapshot requirements remain.

## Stripe confirmation lifetimes — 29 October 2026

The native Stripe SDK remains responsible for authentication UI and payment processing.
The controller owns one async result observer. Equivalent pending identity (kind,
client secret and selected payment method) shares one native start and one UI result.
A different pending identity fails explicitly without replacing the admitted operation.
SDK errors and success/cancel/failure mapping remain available to existing ViewModels.

A temporary authentication sheet does not cancel observation. Permanent navigation
removal/dismissal, owner release, or a changed session suppresses late UI/checkout
work. The SDK provides no cancellation token: observation cancellation cannot undo
an accepted payment, and it must not trigger an automatic retry.

Only checked status/error values enter the async stream; SDK intent objects remain
in the callback. First completion wins. The stream is finished on cancellation and
release, so waiting does not depend on an eventual SDK callback.

Post-campaign Apple Pay retains one context/secret/session, rejects obsolete context
callbacks and clears its state before completion delivery. Its required client-secret
completion is called even for stale/missing context, with an error. Unknown future
SDK status follows failure handling rather than crashing or reporting success.

Pinned source evidence: stripe-ios-spm/StripeCore/.../API Bindings/STPAPIClient.swift
sendRequest delivers completion on DispatchQueue.main; StripeApplePay/.../ApplePayContext/
STPApplePayContext.swift creates the payment method through that API, delivers completion
from authorization-controller dismissal, and declares a weak delegate. STPPaymentHandler's
authenticationContextWillDismiss calls originate in UIKit/Safari dismissal callbacks.
Only these synchronous delegate boundaries use MainActor.assumeIsolated. Async confirmation
result observation accepts callbacks from any executor and applies them on MainActor.

No live Stripe, Apple Pay, 3DS, physical-device or full visual validation is claimed.
PaymentSheet creation/presentation/confirmation and the older PKPayment token callback
remain separate audit items; this checkpoint does not declare every Stripe path migrated.

During complete checking, the first synchronous Apple Pay actor wrapper still
captured SDK objects and its callback. The final wrapper extracts ObjectIdentifier,
String and checked status values first, and returns the client-secret/error value
before invoking the SDK completion on its original executor. This avoids moving
SDK objects or closure state into the actor-isolated region.

## Checkout callbacks and payment transport — 29 October 2026

Preserve synchronous main-actor session delivery to pledge, post-campaign checkout,
pledge-manager web and login controllers. Observer lifetime follows its controller;
rebinding replaces registration. Existing main-actor publisher audit applies.

UI delegates, message banners, haptics and checkout styling belong to MainActor.
Keep presentation, feedback kind and prepare-before-feedback order unchanged.
Video feed readiness/failure callbacks execute on the same UI actor.

Payment reads and writes preserve request inputs, cache policy, SDK executor,
error mapping and cancellation/token lifetime. Convert generated GraphQL data on
its callback executor before resuming the Feature with a checked Sendable snapshot.
GraphQL errors outrank partial data; missing/invalid data retains parsing failure.
No payment is retried automatically; cancellation cannot undo a server-accepted write.

Retain the legacy generic bridge for other callers pending their individual audits.
The lock-protected continuation/token holder's existing unchecked conformance is
not permission to mark Apollo object graphs globally Sendable. No new unchecked
conformance is added. Source SDK protocol/Apple Pay validation and live payments
remain open. No visual redesign or language-mode conversion is part of this change.

## UIKit ownership and checkout values — 29 October 2026

- Shared cell/data-source, layout and overlay UI contracts belong to MainActor.
  Preserve nib setup ordering, data presentation and synchronous UI behavior.
- Discovery session/saved-project publishers and observers stay on MainActor.
  Deliver the original notification synchronously, including full Project payload;
  cancellation or observer release stops delivery. Background SDK notifications
  must use a separate adapter that transfers safe values.
- Checkout release must remove its overlay on MainActor without retaining or
  resurrecting the released controller. Do not assume deinit runs on MainActor.
- Checkout/backing/watch response structs keep the same stored values, decoding
  and equality. Checked Sendable conformances describe reviewed value-only graphs.
- Retain business assertions and reference-device snapshot requirements. Selected
  tests and compiler diagnostics do not establish live or full visual parity.

## Layout, HTML and value-transfer contracts — 29 October 2026

- Keep UIKit HTML import synchronous and preserve fonts, links, formatting and nil
  fallback. Its formatter and UI-only Activity inputs run on MainActor; background
  callers must explicitly await the actor rather than block a queue. SwiftSoup text
  stripping and Markdown conversion keep their existing independent behaviour.
- Preserve the refresh control's 10ms settling delay and zero-offset reveal policy.
  Ending loading, removal or release cancels a pending start; repeated pending starts
  share. A fast completion must never restart the spinner after it ended.
- Discovery refresh/reload, comment footer sizing, reward expansion and card shadows
  use UIKit's layout lifecycle and current geometry. Latest pending state wins;
  preserve animation durations, ordering relative to data load and screen styling.
- Reconfiguring a report cell updates one retained hosted view, with the existing
  labels, spacing and accessibility policy; reuse must not accumulate hosted views.
- Pledged-card toggle retains its 300ms Combine debounce and existing Feature-owned
  write. Subscription lifetime must not retain the card or emit after release.
- User, Location, ProjectNotification and email-verification response data remain
  value types with the same fields/decoding/equality. Checked Sendable conformance
  is limited to their reviewed value-only stored-property graphs; no unchecked
  annotation or warning suppression is introduced.


## Project video and campaign images — 29 October 2026

- Preserve playback/pause/replay controls, positive finite duration updates, 85%
  completion threshold and once-per-screen start/completion analytics. Unknown or
  nonfinite metadata cannot create a boundary observer or reach numeric analytics.
- One observer owns one exact AVPlayer. Replacement invalidates its KVO/boundary
  tokens; replacing a threshold removes its earlier token and rejects queued old
  callbacks. Screen release finishes delivery and cleans up the original player.
- Campaign-image reads keep the existing Kingfisher cache and WebP processing.
  Equivalent pending reads share within a page; failure permits retry. Page/row
  replacement rejects obsolete delivery, and one page cannot cancel another page's
  image downloads. Temporary navigation retains cache preparation; permanent exit
  and project replacement cancel the departing page's work.
- Image assignment checks row bounds and current source URL, retaining the current
  caption/link. Nil or failed images keep the existing optional-image fallback.
- UIImageView's AlamofireImage receipt ownership, weak captures, replacement checks,
  cached-image behavior, circle filter and 300ms uncached transition remain intact.
- Controlled callbacks/local media validate ownership; remote decoding, real network
  cancellation, physical-device playback and full visual parity remain open.

## Permission-alert delay and connectivity — 29 October 2026

- Keep the 500ms web-login settling delay, prompt text/actions, denial accounting
  and notification authorization path. Read the context from its named payload key.
- Equivalent pending prompts share; a different prompt replaces the pending request.
  Backgrounding, owner release or removal of the requesting screen prevents late
  presentation. Do not present over another modal. Suppression is not a denial.
- ConnectivityService owns one lazily created connectivity monitor across account
  resets. Preserve synchronous initial delivery to main-thread compatibility
  subscribers and the existing SystemConfiguration WWAN/reachable/none mapping.
- Native callbacks yield immutable values to the service-owned async consumer. Retain
  and unregister the native handle/context on release; observer disposal does not
  stop application-wide monitoring. Search/Discovery use injected connection state.
- The page-controller compatibility helper remains synchronous on MainActor. All
  six production call sites are UIKit lifecycle/configuration or controller-action
  outputs; preserve native navigation order, animation and completion.
- Real network switching, permission prompts and visual/device behavior remain
  separate validation gates; controlled tests do not claim those journeys passed.

## Video-feed observation and activation — 29 October 2026

- Initial fetch readiness must still notify the presenter before the feed is visible.
  One controller lifetime owns observation; repeated binding must not multiply it.
- Re-arm only the changed output after willSet. Acknowledgement/clear is observable,
  so a later save error or login request is not lost. Stop/release rejects old events.
- Keep model refresh observation while temporarily hidden, but never activate video
  after disappearance/backgrounding, over a share sheet or during a drag. Settle a
  drag both with and without deceleration. A new appearance can activate again.
- Coalesce pending UI activation; replacement/cancellation rejects noncooperative
  late completion. Explicit layout precedes activation, with current visibility checks.
- Preserve source-level UI, navigation, save/mute behavior and analytics. Cell bindings
  must not retain their controller. Populated-device/visual behavior remains unverified.

## View-owned transient-message delays — 29 October 2026

Keep the existing banner (4/10 seconds), save-error toast (3 seconds) and copy-link
confirmation (2.5 seconds) timing, content and animation. SwiftUI owns these tasks;
removal cancels them. Banner replacement restarts its lifetime and stale identity
cannot clear a replacement binding. Toast dismissal remains change-triggered rather
than starting for an initially supplied error. Hosted runtime checks cover banner
replacement and removal; other gesture/accessibility/device behavior remains open.

## Project-page media and audio-session lifetime — 29 October 2026

- Preserve per-row AVPlayer instances, optional cached WebP thumbnails and the
  existing audio/video cells. Thumbnail availability must not delay player readiness.
- ProjectMediaFeature owns pending preparation per page/slot. Equivalent pending
  requests share; changed media replaces that slot. Page replacement/exit cancels
  preparation and rejects stale delivery. Separate pages and rows stay independent.
- Native asset loading is awaited. Readiness observation finishes on ready, failure
  or cancellation and is always invalidated. KVO notifications may omit their typed
  new value; capture the item's current status at the callback boundary instead.
- A late row result may not overwrite a different URL/thumbnail or a removed row.
- One production audio controller serves both the framework and tests. Retain the
  existing soloAmbient/playback policy, OS gating and hardware/unmute intentions.
  Rebinding removes prior observers; dismissal/release finishes event observation.
  Reset completion belongs to its current generation and cannot reopen a dismissed feed.
- Resource cleanup must work for synchronous Objective-C/UIKit-style release as well
  as async release. Finite MainActor cleanup captures resources by value, never the
  deinitializing owner. Cleanup does not initiate new service work.
- Local PCM media and controlled callbacks validate ownership, not visual parity,
  real remote decoding/network behavior or physical-device audio routing/silent switches.

## Saved projects, reporting and account fields — 28 October 2026

- SAVE-01: Keep login gating, the 500ms debounce, optimistic selection, notification
  payloads, counts, saved-project prompts, accessibility, haptics and analytics.
- SAVE-02: Ordinary buttons and video-feed saves share ProjectMediaFeature's native
  queue and transient cache. Equivalent pending writes share; changed desired states
  execute in order per session/project. No automatic mutation retry is introduced.
- SAVE-03: Reused cells discard unadmitted debounced requests and their optimistic
  cache entry. Disposed observers do not cancel admitted mutations. Latest-intent
  and session-generation checks reject obsolete rollback, cache and UI results.
- REPORT-01: Keep option hierarchy, labels, email display, details, banners and
  dismissal behavior. ProjectReportingFeature owns these requests; screen-owned read tasks cancel on disappearance.
- REPORT-02: Equivalent pending reports share; different reports execute in session
  order. Missing context fails gracefully rather than force-unwrapping. Send is
  disabled and its existing spinner is active while submission is pending; explicit
  retry is restored on failure. Cancellation never claims to undo an accepted report.
- ACCOUNT-01: Account fields use SettingsFeature's shared async read, which waits
  for admitted account edits. Retain refresh timing, currency/email/warning/password
  decisions and navigation. Delayed output and deferred admission retain session
  identity. Controllers construct destinations; the ViewModel receives only a Feature.
- ACTION-01: Public-demo reporting and save writes fail explicitly. Live mutations,
  visual parity and physical-device behavior remain separate unverified gates.

Baseline: 30 original logic tests passed (23 saving/reporting, 7 account fields).
Original behavior assertions are retained with explicit async waits; one unsave
fixture now supplies an unsave response instead of silently completing without data.
The report submit spinner activates an existing loading control during the request;
this small pending-state correction is explicit, not a screen redesign.

## Friends and following — 28 October 2026

- FRIEND-01: Preserve Facebook connection gating, source attribution, friend order,
  concatenated pagination, terminal empty pages, statistics, loading behavior,
  discovery navigation, names/counts/accessibility and all existing screen layout.
- FRIEND-02: Keep follow-all confirmation, immediate list clearing after success,
  and the existing two-second refresh delay. A previous session's delayed refresh
  cannot start a request under a replacement account.
- FRIEND-03: One FriendsFeature owns transient follow state shared by Find Friends
  and Activity. Follow/unfollow/follow-all writes execute in admission order;
  identical pending tails share. Failures do not mutate confirmed state or retry.
- FRIEND-04: Reads belong to screen routes. Equivalent pending reads share, refresh
  supersedes pagination, and released routes or replaced accounts reject old values
  and errors. Page and statistics failures remain independent. New reads wait for
  admitted writes; follow-all invalidates any older page before delayed refresh.
- FRIEND-05: Cell reuse suppresses another friend's completion. Observer disposal
  does not cancel an admitted remote write. Session changes reject late cache
  commits and delayed presentation, including logout/login to the same user ID.
- FRIEND-06: Native requests retain existing routes, methods, cursor and body fields.
  The fictional demo rejects follow mutations. No live service mutation is implied
  by mock success, and cancellation cannot undo a server-accepted write.

Baseline: 25 original logic tests passed. Their behavior assertions are retained
with explicit async waits. New controlled tests cover ownership and ordering.
Full checkpoint results and limits are recorded in the ledger and sibling
Migration Evidence/kickstarter-friends. Visual/device and live-service checks remain open.


## Pledged-project overview and payment plans — 28 October 2026

- PPO-01: Preserve card parsing, tier flags, order, page counts, empty/error/loading
  states, dashboard/card analytics, navigation, banners and existing screen layout.
- PPO-02: Share equivalent pending pages; refresh supersedes pagination. Screen
  release or account replacement prevents late results. Terminal load-more returns.
- PPO-03: Order address/receipt writes. A single receipt failure produces one error
  banner and refresh; success retains optimistic feedback. Preserve negative address
  acknowledgement/progress behavior. Never retry writes automatically.
- PPO-04: Public demo rejects mutations. Disposed screens stop observing but cannot
  undo admitted writes. Old-account outcomes cannot publish into a new session.
- PLAN-01: Preserve amount formatting, eligibility/context/default selection and
  payment errors. Bind each plan to its requesting project; replaced amounts,
  released routes and account changes reject old responses.

25 original baseline tests passed. Final integrated run: 1,378 passed, zero
failures/skips, app build succeeded. Eighteen new cases cover ownership and
presentation. Existing parent pledge assertions now await plan completion.
Live payments, visual/device validation and app-wide concurrency remain open.


## Payment methods and Stripe intents — 28 October 2026

- PAY-01: Preserve card ordering/availability, selection, optimistic deletion and
  rollback, edit/loading state, error/banner copy and payment-sheet configuration.
  Preserve the workaround filling a newly stored card's missing stripeCardId.
- PAY-02: Keep intent contexts, two-decimal amount formatting, encoded Checkout ID
  and existing nullable input mapping. Native stored-card reads fetch fresh data.
- PAY-03: Share equivalent pending intents and equivalent pending card-write tails.
  Distinct card writes run in order; failure does not retry or block later commands.
  Reads wait for writes and refetch when overtaken.
- PAY-04: Screen disposal cancels observation, not an admitted mutation. Native
  reads honor cancellation; obsolete session values/errors and delayed secrets
  cannot be delivered to a replacement session.
- PAY-05: Public demo rejects every payment entry point. Never infer a successful
  payment from an intent, or assume cancellation reverses a server-accepted write.

Baseline: 69 original tests passed. Final integrated run: 1,147 passed with zero
failures/skips and successful app build; includes ten new controlled Feature tests.
Original screen assertions retained with explicit async fixture lifetimes and one
completed card-list fixture. Compile failures and two test-fixture crashes are
recorded in the ledger/evidence. Real Stripe authorization/charges, live account
operations, visual/device parity, remaining checkout/pledge ownership and full
app-wide validation are still open.

## Messaging — 28 October 2026

- MSG-01: Preserve inbox/sent/project scope, refresh clearing, concatenation,
  empty-page stop, loading/footer behavior and current navigation.
- MSG-02: Search clears immediately and cancels obsolete work before debounce.
  Late success/error cannot restore a cleared query or change newer loading.
  Disappearing screens cannot admit a pending debounced request.
- MSG-03: Preserve sorted messages, backing lookup rules, role-based empty copy,
  recipient labels, untrimmed bodies and blocking/read-status effects.
- MSG-04: Share equivalent pending sends and read-status writes. Distinct sends
  remain ordered per destination; a failed send does not automatically retry.
  Screen disposal suppresses presentation without canceling an admitted write.
- MSG-05: Reject stale account generations, including same-user replacement,
  and suppress delayed presentation after session changes.
- MSG-06: Keep native endpoint/query/body encoding and reject account messaging
  in the fictional demo. Deep links use the same MessagingFeature.
- MSG-07: A resolved message link selects Profile and opens the thread above
  the Profile and inbox screens. Preserve the previous tab's navigation stack.
  Cold-launch links can apply after the initial tab layout is ready. Recheck
  the account before applying the message stack.

Baseline 36 original tests passed. Final 1,063 integrated tests passed, zero
failures/skips, and app build succeeded. Includes 15 new Feature/lifetime cases,
one deep-link test and three native request/demo tests. All original messaging
assertions retained. See ledger/evidence for corrected fixtures and scheduler
synchronization failures. Live services, visual/device parity and app-wide
strict-concurrency validation remain open.

## Project-notification settings — 28 October 2026

- Preserve project names, list loading's silent failure, combined email/mobile
  switch, immediate optimistic feedback, existing error text and cache keys.
- Use the same GET/PUT routes and encoded channel fields. Never fabricate a
  successful account operation in the public fictional demo.
- Share equivalent pending tails; execute distinct edits in order per notification.
  Cell reuse/disposal stops presentation but cannot undo an admitted remote write.
- Commit only confirmed state for the current session. Suppress stale list results,
  old-session success/errors and delayed notifications after cell reuse.
- Intentional correction: rapid-edit failure returns to confirmed state rather than
  an earlier unconfirmed tap. Failure remains a failure; retry is explicit.

Baseline: all six original list/cell tests passed. Final: 1,008 integrated tests
passed, zero failures/skips; app build succeeded. Eight new ownership/lifetime cases
and two native route/decoder cases are included. The first runs omitted the new
test file from Xcode membership; that coverage gap was fixed and all eight named
results checked afterward. See the ledger and sibling Migration Evidence/
kickstarter-project-notifications. Live accounts, rendered/device parity,
full-suite and app-wide concurrency sign-off remain open.

## Shared activity badge — 28 October 2026

- Root tab and Activity callers share one pending badge-clear command and one
  session commit. Merge only its returned count into the latest current user.
- Preserve immediate tab-badge clearing, silent save failure, existing notification
  effects and tab layout. Retry is explicit; disposal cannot undo an admitted write.
- Suppress old-session results and delayed notifications. Completed badge changes
  invalidate older whole-user reads without cancelling unrelated setup metadata.
- Controllers notify after persistence; they must not replay returned User snapshots.
- The standard layout displays the Activity badge on Activity. The floating
  layout has no Activity tab. Restoring the standard layout displays the
  current badge count on Activity.

Baseline: 24 original Root tests. Final: 992 tests passed and app built, zero
failures/skips; six new scenarios. The Rewards fixture-cleanup crash, corrective
actor/lifetime changes and ten passing repeated runs are recorded in the ledger
and sibling Migration Evidence/kickstarter-root-badge. Exact runtime-abort cause
is not proven. No full-suite, live-service or visual/device sign-off is implied.

## Account writes and session refresh — 28 October 2026

- ACC-W01: Preserve account form validation, loading/errors, confirmation,
  navigation and notification effects; retain existing routes and encoded keys.
- ACC-W02: Account and preference writes execute in admitted order. Only an
  equivalent pending tail shares work. Failure does not strand the next edit.
- ACC-W03: Disposing presentation cannot cancel an admitted remote write.
  Old-session completions cannot persist into the replacement session.
- ACC-W04: Merge only the confirmed changed account fields into the latest
  session user. Facebook connection changes its connection/token flags, not a
  stale response's unrelated preferences. Live reconciliation remains unverified.
- ACC-R01: Refresh waits for queued settings writes; stale reads and stale errors
  are suppressed after account changes, including logout/login to the same ID.
- ACC-R02: Preserve cached-user-first Settings display. Only authenticated
  lifecycle refresh may restore a stored token's missing user; ordinary refresh
  never logs in. Setup email/PPO/features commit once through SessionFeature.
- ACC-V01: Verification links may execute while signed out, share equivalent
  pending tokens, order distinct tokens and never establish a session.
- ACC-D01: Public demo rejects account writes; no synthetic successful mutation.

Original assertions plus controlled SettingsFeature/SessionFeature tests protect
these requirements. Baselines: 37 account-form tests and 11 Settings tests;
Facebook original suite has post-change evidence only. Final: 962 tests passed,
zero failures/skips; app build succeeded. See MIGRATION_LEDGER.md and sibling
Migration Evidence/kickstarter-account-writes for commands, failures and limits.
UI source/layout is preserved; rendered/device and live account journeys have
NOT been signed off. This is an engineering checkpoint, not migration completion.

## Social/signup/OAuth and password reset — 28 October 2026

- Preserve existing Facebook errors and two-factor/confirmation routing, Apple
  SDK error handling, signup newsletter consent, reset validation/copy, navigation
  and session notifications. Layout and identifiers are unchanged.
- Treat Apple/OAuth token plus matching user as one operation. A partial failure,
  cancelled caller, superseding attempt or old session cannot persist credentials.
- Share equivalent pending signup/login requests; do not retry writes automatically.
  Preserve OAuth's pre-login analytics identity, once per committed shared attempt.
- Preserve existing REST routes, PKCE payload, both newsletter fields and Apple's
  mutation input. OAuth's temporary token overrides X-Auth only for its user request;
  it does not mutate the service or stored session before success.
- Reset is separate from login/resend and never establishes a session. Duplicate
  pending emails share; changed email replaces presentation. Disposal suppresses
  completion without claiming to reverse an already accepted remote write.
- OAuth browser/redirect work belongs to its screen adapter. Cancel/release and
  replaced browser/session generations cannot publish late authentication.
- Keep public demo account operations unavailable; no fictional successful login
  or password-reset send. No live account operation was performed in verification.

Intentional corrections: reset loading settles false after completion rather than
the old synchronous mock's reversed notification order; malformed Apple IDs show
failure rather than leaving loading active. Apple has one final artificial API
delay (default zero), not separate delays around both stages. Other existing
business assertions remain, with explicit async completion instead of timing guesses.

Baseline: 53 passed, two 10ms OAuth test timeouts. Final: 886 integrated tests passed,
zero failures/skips, app built with two existing warnings. Four nonvisual suites
retain per-suite snapshot-device opt-outs only. Thirteen new Feature/OAuth cases
and three native request tests are included. Results and limitations are recorded
in sibling Migration Evidence/kickstarter-auth-flows and MIGRATION_LEDGER.md.
No live-service, visual/device, full-suite or app-wide concurrency sign-off implied.

## Email login and two-factor authentication — 28 October 2026

- Preserve email/password and Facebook two-factor routes, request encoding,
  token/error decoding, validation, loading, resend messages and navigation.
- Commit successful login once through SessionFeature using the existing
  credential/current-user store before delivering presentation confirmation.
- Share equivalent pending attempts. Changed credentials/code replace the older
  attempt within that operation; verify request and session identity after await.
- Keep resend independent of submitted verification. Resend never creates a
  session, including an unexpected successful token response.
- Disposed/cancelled callers cannot commit. Disposing one shared caller does
  not cancel another. Same-user logout/login still invalidates prior attempts.
- Preserve failure delivery and explicit retry; public demo authentication fails
  rather than reporting synthetic success. No live authentication is performed.

Baseline: 21 unchanged Login/TwoFactor tests. Final: 815 integrated tests passed,
zero failures/skips, app build succeeded. Ten Feature and two decoder cases added.
Results: /private/tmp/kickstarter-authentication.juTwNe.
Evidence: sibling Migration Evidence/kickstarter-authentication, including the
reproduced Discovery lifecycle abort, test-lifetime cleanup and ten passing repeats.
Exact runtime-abort root cause remains unproven; failures are not erased by retry.

Initial Facebook/Apple/signup/OAuth/reset-password and other account flows remain
legacy. No whole-app, live-service, physical-device or visual sign-off is implied.

## Newsletter/deep-link preference entry points — 27 October 2026

- Preserve the post-pledge Games newsletter prompt, German opt-in text, silent
  save-failure behavior and user-updated notification after confirmed persistence.
- Preserve notification URL field names, enabled/disabled values, navigation and
  presentation delay. Unknown fields retain the legacy no-op save.
- Newsletter and notification links join the existing settings queue; a later
  edit must not overwrite an unrelated earlier edit from a stale User snapshot.
- Persist once in the Feature. Delayed UI callbacks may identify/notify the
  current user but must not re-save a completed command's old snapshot.

Baseline: 16 Thanks + 118 AppDelegate tests. After: 803 integrated tests passed,
zero failures/skips, app build succeeded. Six new cases cover all URL fields,
shared ordering, failure, signed-out/unknown input and delayed completion.
Evidence: /private/tmp/kickstarter-preference-entrypoints.ITOvsu and sibling
Migration Evidence/kickstarter-preference-entrypoints.
No live-service mutation or authenticated visual/device validation was run.
The older settings checkpoint below accurately describes its earlier boundary;
the two remaining updateUserSelf callers it lists are resolved by this checkpoint.

## Settings preferences and shared account persistence — 27 October 2026

- Preserve switch values, immediate visual feedback, rollback/error messages,
  German newsletter opt-in prompts, digest picker behavior and navigation.
- Preserve the user-self PUT route/encoding and existing account storage keys.
- Apply changed fields to the current session user when a queued write dispatches.
  Only equivalent pending tails share; distinct on/off/on intents remain ordered.
- Persist confirmed preferences before the next save. Screen disposal or caller
  cancellation does not abandon an admitted write; no automatic retry is added.
- Reject signed-out, mismatched-account and old-generation commands, including
  old failures after logout/login to the same ID. Invalid requests cannot reset
  another account's valid queue.
- Recommendations remain visually optimistic, but speculative values are no
  longer persisted as a full User. Failed writes leave authoritative state intact.
- Remove delayed controller persistence for migrated settings/Profile/Activity.
  Guard Profile responses through presentation delays and merge badge counts
  into the latest session user. Retain the existing UI notifications.
- The public fictional demo rejects preference writes; no synthetic success.

Baseline: 55 original settings tests passed. After: 642 integrated tests passed,
zero failures/skips, and the app built in
/private/tmp/kickstarter-settings-preferences.famRTj.
Thirteen SettingsFeature cases plus a delayed-Profile regression were added.
An earlier run had one test-process abort (605 passed); the identical full rerun
passed. Root cause of that intermittent XCTest/Swift runtime abort is unresolved.

Thanks newsletter signup and AppDelegate notification deep links remain legacy
writers of the same endpoint; app-wide write serialization is not complete.
Other account/authentication, messaging/project-notification and payment workflows
remain open. No live account mutation, authenticated visual/device sign-off,
full-suite pass or strict-concurrency completion is implied.

## Activity/Profile and shared account reads — 27 October 2026

- Preserve Activity's descending deduplicated history, refresh retention, empty
  first-page clearing, surveys, navigation, badge triggers and analytics.
- Preserve independent backed/saved pagination, cached header prefix, loading
  presentation, project-count refresh triggers and the one-second save debounce.
- Equivalent pending reads share. Refresh replaces pagination; completed saves
  invalidate older header reads. Late success/error cannot repopulate reset state.
- Validate account generation after suspension, including logout/login to the
  same ID. Login/logout resets both tab owners; signed-out private reads do not run.
- Combine successful header reads regardless of response order, explicitly fixing
  the old graph-first lost-update race. Independent display/error behavior remains.
- Admitted badge writes continue, but cannot update a newer account; no automatic
  retry after an uncertain remote mutation.
- AppEnvironment remains the sole credential/current-user persistence authority
  during this stage. No storage keys, branding, layout or login/logout effects changed.

573 tests passed with zero failures/skips and an app build succeeded:
/private/tmp/kickstarter-account-tabs.f1QiDO.
Existing expected values are retained. Sixteen controlled Feature tests cover
overlap, late replies, failure/retry, account change, reset and save invalidation.
No live badge/account mutation, populated authenticated UI, physical-device,
full-suite or strict-concurrency sign-off. Whole-app migration remains incomplete.

## Video-feed loading and save/watch — 27 October 2026

- Preserve the existing 30-item query, empty/error display and prior data on failed refresh.
- Publish initial-load completion before fetchedItems; optimistic saves update
  items only, without a collection reload. Preserve first-impression analytics.
- Preserve immediate saved state/count, login intent, cache reconciliation,
  mute preference, navigation and latest-intent failure toast/rollback.
- Share equivalent in-flight reads; reject released-route or old-account results.
- Order changed watch states per account/project; share equivalent pending
  commands and keep unrelated projects independent. No automatic remote-write retry.
- Navigation cancels feed reads, not admitted writes; queued old-account writes
  cannot dispatch and obsolete completions cannot alter visible state.

528 tests passed with zero failures/skips and the app built successfully in
/private/tmp/kickstarter-video-feed.gHPMre. Original 18 ViewModel assertions
remain; controlled tests cover completed success/failure and adverse ordering.
Live watch/unwatch, populated-feed visual parity, device and strict-concurrency
validation remain unexecuted. This is a bounded checkpoint, not app-wide sign-off.

## Discussion mutations — 27 October 2026

| ID | Preserved requirement | Protection |
| --- | --- | --- |
| DISC-W01 | Show a temporary comment immediately, replace by stable ID, retain failed text | Original Comments/Replies/Dialog assertions pass |
| DISC-W02 | Explicit retry shows retrying, retry-success for three seconds, then confirmed comment; failure returns original failed comment | Original timed tests pass; duplicate attempt sharing is Feature-tested |
| DISC-W03 | Distinct posts are not discarded; at most five execute concurrently | Controlled six-post admission/failure test |
| DISC-W04 | Block success posts the existing notification and analytics; failure remains visible | Original two-screen tests pass; Feature sharing/independence/failure tests |
| DISC-W05 | Screen disposal must not imply rollback of an admitted remote mutation | Disposed-subscriber/route-release test; existing Apollo adapter also did not cancel remote writes |
| DISC-W06 | Account changes cannot dispatch delayed old text or publish obsolete results | Controlled queued writes, retry/status delay and blocking tests |
| DISC-W07 | Cancelling one caller does not cancel shared mutation work; no automatic retry | Controlled waiter cancellation and failure/retry tests |

499 tests and app build passed in /private/tmp/kickstarter-discussion-writes.FuQBU3.
Existing optimistic dialog dismissal is preserved, not corrected as an incidental
redesign. Live-service/visual/device mutation checks remain unexecuted; no real
comment or block was submitted. This bounded checkpoint is not app-wide sign-off.

## Discussion reads and playback counters — 27 October 2026

- Preserve project-first configuration, update-only project context and current
  composer/keyboard/navigation behavior. Posting, retry and blocking stay legacy.
- Preserve returned page identity/cursors, backward replies and the empty-page
  stop condition. Missing envelopes complete silently; errors remain errors.
- Refresh clears as before. Reply retry after an initial failure must not emit
  an extra clear before the first successful reply count. Existing assertion passes.
- Separate route lifetimes, share equivalent in-flight reads, replace explicit
  refresh/changed navigation, and reject canceled/account-mismatched completions.
- Keep update WebKit policy, cached-project navigation, ref tags and silent lookup
  errors. No controller, layout or resource was redesigned.
- Video start/completion are independent events, not latest-wins reads. Preserve
  the playback threshold and once-per-screen triggers; never automatically retry
  a counter write with an unknown remote outcome. Playback UI remains unchanged.

454 integrated tests passed, zero failures/skips, and app build succeeded in
/private/tmp/kickstarter-discussion-media.ga9kgf. The 71-test baseline passed;
one post-change reply emission mismatch was corrected without weakening assertions.
Seven update-detail and 19 API tests also passed with zero failures/skips.
Agent smoke observed overview → Campaign → overview; the demo does not expose
populated discussion/video flows. Those are fixture-tested, not visually verified.
This is not live-service, visual parity, full-app or strict-concurrency sign-off.

## Shipping destinations and creator interactions — 27 October 2026

| ID | Preserved requirement | Protection and result |
| --- | --- | --- |
| SHIP-01 | Digital rewards make no shipping request and select nil; empty fetched destinations are a distinct successful result | Existing ViewModel and new Feature tests pass |
| SHIP-02 | Prefer valid backing location, then configured country, then US, then first destination | Existing nine shipping tests plus direct priority/fallback tests pass |
| SHIP-03 | Loading shows shimmer; error uses the existing localized message; picker select/cancel and 300 ms dismissal remain | Existing ViewModel assertions pass |
| SHIP-04 | Equivalent reads share; changed inputs supersede; independent selectors do not cross-cancel | Controlled suspension and adverse-completion tests pass |
| SHIP-05 | Cancellation/account change cannot deliver obsolete destinations; failure preserves previous data and retry recovers | Direct Feature tests pass |
| CREATOR-01 | Biography requests retain service preparation and message authorization reflects the current account | Feature and seven existing creator ViewModel tests pass |
| CREATOR-02 | Creator links preserve return-to-project, login, message and external-browser navigation | Existing creator assertions pass; updates/pledge-web adapters also regression-tested |

377 combined tests and app build passed:
/private/tmp/kickstarter-shipping-interactions.82bZbI.
Five location API tests also passed. Agent smoke observed overview/rewards/return
and creator-screen open/return. The demo is digital: no rendered shipping picker,
live creator content or transaction completion is claimed.
The nine shipping tests passed before migration. Creator baseline was blocked by
invalid synthetic WebKit object lifetime, not a navigation assertion failure.
The corrected fixtures preserve all navigation assertions and actual-event data.
New overlap tests strengthen obsolete-read protection without changing payment,
storage or visible design. No full-app, live-service or strict-concurrency claim.

## Rewards and related-project reads — 27 October 2026

- The shipping-sorted rewards API returns one complete list, not cursor pages.
  Preserve its query, server ordering, shipping metadata and synthetic No Reward
  placement experiment. Filter future rewards in the owning Feature.
- A changed shipping location supersedes that screen's read; equivalent in-flight
  requests share. Separate reward/project routes do not cancel each other.
  Cancellation and account changes suppress late results and errors.
- Keep cached reward cards bound to their last successful location after failure;
  retain the existing placeholder and retry-through-location-change behavior.
- Preserve secret/backed-reward scroll, selected reward, shipping rule, navigation,
  footer count, existing CTA decisions and analytics. No payment mutation changed.
- Recommendations load independently of required detail/backing/reward data.
  Preserve initial loading, loaded/empty/error presentation and card navigation.

Verification: 324 combined tests and app build passed in
/private/tmp/kickstarter-rewards-related.VmZxNu; two sorted-reward decoder tests
passed in /private/tmp/kickstarter-rewards-sorted-decoder.xcresult.
Agent smoke observed overview → Rewards → overview → Campaign. Public demo
does not supply recommendation cards; their rendering still needs visual/live
validation. No full-app or strict-concurrency completion claim.

## Project-detail loading checkpoint — 27 October 2026

Before: 75 existing page/tracking tests passed at bc6a50a01. After: all original
assertions retained, plus 12 Feature tests and one recommendations-rendering
regression; 293 combined tests and app build passed. Existing API fixture/decoder
contracts: 11 additional tests passed. No failures or skips in either final run.

| Requirement | Protection |
| --- | --- |
| Secret-reward enrollment precedes reads and failure prevents downstream work | Controlled enrollment gate and failure/retry tests |
| Standard project → optional backing → rewards ordering | Feature trace assertions, no partial-project publication |
| Backing merge retains project metadata; no-reward stays first | Direct Feature assertions plus existing API fixture contracts |
| Fast base/extras begin concurrently and either failure fails the page | Controlled parallel dependency tests; throwing task group cancels siblings |
| Repeated equivalent requests share; mutation refresh supersedes | Sharing and forced-refresh adverse completion tests |
| Independent project routes do not cross-cancel | Two-route cancellation/release test |
| Account changes and late responses cannot publish stale state | Controlled account/replacement tests |
| Existing preview, CTA, media, navigation and analytics outputs remain | 75 original assertions retained through async test adapters |
| Unrelated recommendations may still update a selected page | Explicit recommendations-error rendering regression; pending fixtures isolate other tests |

Agent smoke: Pocket Observatory overview → Campaign → FAQ → Rewards (demo
supporter edition) → same FAQ page. No payment, real account or enrollment used.
This does not verify the legacy rewards-screen executor, live APIs, snapshot
equivalence, full accessibility, device performance or app-wide completion.

## Explore async ownership checkpoint — 27 October 2026

Final continuation: 205 tests passed with zero failures/skips and the app built
in /private/tmp/kickstarter-discovery-async.RzwK5t. Selected filter state and
recommendation defaults now belong to DiscoveryFeature; all existing controller
output/analytics assertions still pass. Public filter selection does not eagerly
fetch hidden feeds. View models retain screen readiness/navigation timing.

Same filters under a different account no longer share in-flight work or reuse
an older account's cursor. A late project/activity response from the previous
account cannot publish. Direct regression tests cover both cases. Existing cached
card display behaviour is unchanged; this is not a full session/privacy audit.

Final Simulator smoke observed Games selection, Forest Trails and the selected
Games header, then All Projects restoring Pocket Observatory. No visual source
was changed. Other manual/strict-concurrency limitations below remain open.

Before: 55 existing Explore logic tests passed on commit
237d929d8c5c1e714935ccd959048e628e93ea07. After: those same assertions passed
through DiscoveryFeature's native async route; the combined run passed 202 tests,
zero failures/skips, and the app built. Results:
/private/tmp/kickstarter-discovery-async.vlaCu9.

| Requirement | Protection and result |
| --- | --- |
| Four retained sorts keep independent results and requests | New four-feed adverse-order test; existing sort/lifecycle tests passed |
| First-page loading, pull refresh, filter clearing and empty states keep existing presentation | All DiscoveryPageViewModelTests assertions retained; scheduler-only draining replaced with awaiting Feature task completion |
| Pagination appends in order without duplicates; empty page ends pagination | Existing testPaginating plus direct cursor/deduplication/termination test passed |
| Refresh retains cards until success and replaces pending pagination | Direct old-page-late regression passed; existing refresh/loading tests passed |
| Failures stop loading without inventing empty success; paging can retry | Feature retains errors separately; failed-page/same-cursor retry test passed; no new error UI |
| Equivalent in-flight callers share completion; superseded work cannot publish | Direct sharing, late-filter response and cancellation tests passed |
| Activity samples keep seen-ID storage and navigation behaviour | Existing activity/seen/clear/navigation assertions passed; new sample replacement/error/isolation tests passed |
| Session/filter/reachability/analytics presentation remains unchanged | Existing login, blocked-user, onboarding, banner and event assertions passed |
| Public demo remains usable without private API keys | Native MockService demo route test and running Simulator cards/detail observed |

The agent observed Magic, Popular, Newest and Ending Soon demo feeds, opened
Paper Cities from Ending Soon, then closed detail and observed the same selected
feed/cards. This is a bounded smoke check, not screenshot comparison, live-network
verification or authentication coverage. Manual pull-refresh was inconclusive
(the gesture opened a card), so only its automated coverage is claimed.

The final continuation above moved filter/recommendation policy into the Feature.
Screen readiness and navigation remain compatibility-view-model responsibilities. URLSession provides
native cancellation, but no live-server cancellation experiment was performed.
Swift 5 mode remains; full strict-concurrency and app-wide exit gates are open.

## Search checkpoint history

Latest confirmation (27 October): 189 tests passed, zero failures/skips, and app
build succeeded in /private/tmp/kickstarter-query-admission.7z1aJ3. This supersedes
the pending Search close-out and Explore logic-baseline notes below. The first
run exposed an actual sharing defect, now fixed: funding buckets and location
must participate in Search request identity even though legacy REST equality
omits them. All four now have cancellation/late-result regression coverage.
Manual/snapshot, strict-concurrency and app-wide completion remain outstanding.

Author: Matthew Thomas. Baseline captured 26 October 2026 at
`5ad48326904a4033e1b06ab21cb0942c51b077fe` (public-demo preparation).
Original upstream: `5f5463cfb830413d253efed45bfcec0322c9f152`.

This contract covers Search. Ownership, filters, async transport and native awaitable pagination have
incremental checkpoints recorded below. It is not a complete app contract, nor proof
that authentication, payments or live APIs work. UIKit presentation is retained.
Test names below refer to `LibraryTests/Library/ViewModels/SearchViewModelTests.swift`
unless another suite is named. The ledger records exact commands and results.

| ID | Plain-English requirement | Legacy evidence | Evidence status | Baseline | Replacement protection | Post-migration result | Manual regression | Difference and approval |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| BEH-S01 | Opening Search displays discovery results and the Discover projects title once data arrives. | `testFlow`, `testSearchLoaderIndicatorIsAnimating` | Confirmed | Passed, 67-test focused baseline | Retain assertions; add Feature success test | Native async Search checkpoint: automated tests passed; bounded manual evidence below | Agent observed discovery cards and title on iPhone Air, iOS 26.2, 26 Oct | None |
| BEH-S02 | Changing the query immediately clears old cards and displays loading while the replacement request waits. | `testFlow`, `testCancelingOfSearchResultsWhenEnteringNewSearchTerms` | Confirmed | Passed, 67-test focused baseline | ViewModel presentation and Feature replacement tests | Native async Search checkpoint: automated tests passed; bounded manual evidence below | See bounded smoke checks below; remaining checks pending | None |
| BEH-S03 | Rapidly changing the query never lets an obsolete result replace the newest result. | `testCancelingOfSearchResultsWhenEnteringNewSearchTerms`, `testOrderingOfPopularAndDelayedSearches` | Confirmed | Passed, 67-test focused baseline | Controlled adverse-order completion and cancellation tests | Native async Search checkpoint: automated tests passed; bounded manual evidence below | Pending | Network cancellation itself is not established by these tests |
| BEH-S04 | Clearing the query resets filters and sort and returns to discovery results; changing to another non-empty query retains filters. | `testClearSearchText_clearsFilters`, `testEmptySearchText_clearsFilters`, `testChangingSearchText_keepsOriginalFilters` | Confirmed | Passed, 67-test focused baseline | Existing presentation assertions plus direct Feature selection/reset tests | Native async Search checkpoint: automated tests passed; bounded manual evidence below | Pending | None |
| BEH-S05 | Changing a sort or filter reloads results for the new selection and keeps its visible selection consistent. | `test_flow_sort`, `test_flow_filterByCategory`; `SearchFiltersUseCaseTests` selection/reset cases | Confirmed | Passed, 67-test focused baseline | Feature selections and existing filter presentation tests | Native async Search checkpoint: automated tests passed; bounded manual evidence below | Pending | None |
| BEH-S06 | Reaching the pagination threshold appends subsequent results in order and stops when no next cursor exists. | `testFlow`; `PaginateTests.testPaginateFlow`, `testPagination_StopsWhenCursorIsNil`, interleaving cases | Confirmed | Passed, 67-test focused baseline | Feature cursor, overlap and replacement tests | Native async Search checkpoint: automated tests passed; bounded manual evidence below | Pending | Current threshold is three remaining rows; repeated equivalent loads must share completion |
| BEH-S07 | A successful empty response displays the empty-result message; loading a new query hides it. | `testShowNoSearchResults` | Confirmed | Passed, 67-test focused baseline | Feature empty success and ViewModel empty/loading tests | Native async Search checkpoint: automated tests passed; bounded manual evidence below | Pending | Empty success must remain distinct from failure |
| BEH-S08 | Selecting a card opens the same project/prelaunch destination with the appropriate first-card/query ref tag. | Four `testSearch…_RefTag` cases; controller route; existing framework prelaunch tests | Confirmed | Passed, 67-test focused baseline; framework snapshots not run | Keep route/ref-tag assertions | Native async Search checkpoint: automated tests passed; bounded manual evidence below | Pending | No new routing design |
| BEH-S09 | Search analytics distinguish page visits, completed queries and card clicks, without counting pagination or cancelled queries as completed searches. | `testProjectCardClicked`, `testSlowTyping`, page-view tests, `testFlow` | Confirmed | Passed, 67-test focused baseline | Preserve event values/counts through local tracking fake | Native async Search checkpoint: automated tests passed; bounded manual evidence below | Production analytics not exercised | Demo startup intentionally disables external SDKs |
| BEH-S10 | Leaving and returning to Search retains its current results rather than automatically fetching more. | `testFlow`, `testSearchPageViewed_ReturningAfterSearching` | Confirmed | Passed, 67-test focused baseline | ViewModel lifecycle and Feature ownership tests | Native async Search checkpoint: automated tests passed; bounded manual evidence below | Pending | Cancellation on disappearance must not discard completed results |
| BEH-S11 | The video-feed banner follows its feature flag and reachability, without repeated identical visibility events. | Three `testShowVideoFeedBanner…` cases | Confirmed | Passed, 67-test focused baseline | Preserve flag/reachability presentation tests | Native async Search checkpoint: automated tests passed; bounded manual evidence below | Pending | Do not replace real flags with demo assumptions |
| BEH-S12 | A failed initial request stops loading, and a later changed query can recover. | New `testFailedInitialSearchStopsLoadingAndRecoversOnChangedQuery`; existing discarded error output | Confirmed by new baseline test | Passed, 67-test focused baseline | Feature retained error/retry test and presentation contract | Native async Search checkpoint: automated tests passed; bounded manual evidence below | Pending | Silent error presentation is an existing defect candidate, not an approved final UX |

## Unresolved design and verification boundaries

- The current ViewModel has no error presentation for Feature failures. Preserve the distinction
  between an empty success and a failure in the new Feature. Do not invent a
  new error screen or claim that existing silence is the desired product UX.
- Existing names/comments describe "popular" discovery, but the filter
  implementation and its test default to `.magic`. Preserve actual tested
  selection; do not silently switch sort based on a comment.
- `viewWillAppearNotAnimated` currently filters `true`, despite its name.
  Preserve observed/tested lifecycle behaviour until explicitly resolved.
- Repeated filter reset emissions and debounce scheduling are observable in
  existing tests. Characterise their request and analytics effects before
  coalescing them; fewer calls alone is not proof of equivalence.
- Real-device timing, VoiceOver, logged-in filters, external APIs, all project
  destinations and snapshot comparisons remain separate validation gates.

## Bounded smoke checks after request extraction

On 26 October 2026, the agent observed discovery cards/title; Forest returning
three matches; a no-match query displaying the empty-state message; Cancel
restoring discovery; Newest selection showing its selected state; Paper Cities
opening the matching detail; and closing detail retaining Search cards/selection.
This supports parts of BEH-S01/S04/S05/S07/S08/S10, not every variant. No image
diff, rapid-typing timing measurement, complete filter journey, live API or
failure-UI test was performed. Newest ordering was not independently compared.

The Feature now retains errors separately from successful empty results. The
legacy ViewModel still has no new error presentation. Direct tests cover failed
first-page recovery, failed-page retry, cursor termination and obsolete
subscription completion suppression; they do not establish transport cancellation.

## Filter and async transport checkpoint (26 October 2026)

Historical checkpoint: this focused run passed 87 tests; the table now points
to the later native async checkpoint below. Three direct Feature tests now protect
BEH-S04/S05 query composition, reset-all retaining sort, empty-query resetting
sort, and toggle changes. The original presentation/analytics expectations remain
unchanged; a temporary analytics ordering regression was corrected in production
wiring before the filter commit (details in the ledger).

Ten additional tests protect Search's async transport and compatibility adapter:
exactly-once completion, cancellation before/during registration, cancellation
before invocation, GraphQL error precedence, nil/transport error mapping, mock
failure/recovery, Feature delivery, and query replacement cancelling its token
while ignoring late completion. This adds controlled transport evidence for
BEH-S03/S12, not a live-network or exhaustive async-screen verification claim.
Original baseline suites retain the legacy deterministic provider.

Fresh agent Simulator smoke on the async demo route observed discovery, Forest
returning three matches, Games narrowing to one, query clearing resetting category
and returning discovery, and the no-match message for Zzznomatch. This supports
BEH-S01/S04/S05/S07. No visual implementation changed; no pixel comparison was run.
Pagination/debounce, lookup cancellation and fully awaitable Feature commands
remain outstanding. Other manual gates in the table remain bounded as stated.
## Native awaitable pagination checkpoint (26 October 2026)

The current six-suite selection passes 93 tests. Existing ViewModel presentation,
navigation, lifecycle and analytics assertions now exercise the async provider and
native Feature execution, with a controlled result-delay clock rather than the
removed legacy provider. Three flow fixtures now install their service before
request admission; expectations were not weakened.

BEH-S02/S03/S06/S12 have direct adverse-order and retry coverage. Equivalent
in-flight first-page/page requests share one completion and append once. A new
query supersedes a pending page; its late completion cannot append or clear newer
loading. Explicit cancellation permits retry. Cancelled waiters do not cancel the
shared app-owned operation; they await its completion. Calls with no initial
query/next cursor are awaitable no-ops. Physical transport cancellation remains
covered by controlled callback/token tests, not live-network measurement.

Fresh agent smoke on the rebuilt Debug demo observed: Search discovery; scrolling
through later-page Edition 3 cards including Neighbourhood Sounds; query replacement
with Forest (three matches); Games (one match); clearing resets category/discovery;
Zzznomatch shows the existing no-results message; Solar Sketchbook detail opens and
closes back to Search. This supports BEH-S01/S04/S05/S06/S07/S08/S10 only for those
demo journeys. Pagination termination/repeated-load suppression is asserted in
tests, not inferred solely from a still screenshot. No pixel comparison, VoiceOver,
logged-in journey, error-UI injection or exhaustive destination check was run.

**Still incomplete:** category/location lookup execution and its races, remaining
reactive selection/presentation edges, full Search CFA review and broader validation.
Other app features remain outside this Search contract. Earlier checkpoint notes
about reactive pagination describe historical states, not the current implementation.
## Category/location lookup slice — automated verification passed

The initial baseline attempt was environment-blocked before compilation.
Matthew Thomas subsequently ran verify.zsh in Terminal. The agent inspected both
xcresult bundles: 114 tests passed (zero failures/skips), and the app build
succeeded. All 15 new tests passed. No fresh manual screen evidence is claimed.
See the ledger for paths, warning counts and runtime limitations.

| ID | Plain-English requirement | Legacy evidence | Evidence status | Baseline | Replacement protection | Post-migration result | Manual regression | Difference and approval |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| BEH-S13 | Opening filters reuses nonempty cached categories; an empty cache fetches, and a failed lookup can be retried. | FetchCategoriesUseCaseTests (three cases), existing KSCache key | Confirmed | Fresh run blocked before compilation | SearchLookupTests cache/failure/retry cases | Passed in 114-test run | Pending | Same cache and category delay; no new error UI |
| BEH-S14 | Default locations appear independently of category loading; location queries return suggestions and clearing immediately empties them. | FetchLocationsUseCaseTests (three cases), query limits 5/10 in source | Confirmed | Fresh run blocked before compilation | SearchLookupTests initial outputs, independent defaults and live fixture mapping | Passed in 114-test run | Pending | Native commands replace reactive execution |
| BEH-S15 | Clearing or replacing a location query prevents obsolete results and failures from changing the current suggestions or loading state. | Legacy empty-query branch bypasses switchMap cancellation; source-confirmed stale-response route | Confirmed user-requested correction | Source diagnosis; no runtime reproducer run | SearchLookupTests clear/late success, clear/late error, old/new ordering and cleanup tests | Passed in 114-test run | Pending | Intended approved change: user explicitly requested stale responses after clearing be addressed, 26 Oct 2026 |
| BEH-S16 | Failed nonempty location lookups retain existing suggestions; retry can recover, and whitespace remains a submitted query. | FetchLocationsUseCase materialize/values, nonempty filter | Inferred from source | Fresh run blocked | SearchLookupTests failure/retry, whitespace and cancelled-before-admission cases | Passed in 114-test run | Pending | Preserve silent UI errors; Feature retains errors separately |
| BEH-S17 | Equivalent pending lookups share one execution and completion; cancelling one waiter does not cancel another caller's shared request. | New explicit Feature overlap policy | Confirmed migration policy | Not an existing tested guarantee | SearchLookupTests shared query/options and cancelled waiter; SearchRequestCancellationTests location payload | Passed in 114-test run | Pending | Same policy as the preceding native Search pagination checkpoint |

No new visual design is authorized. Legacy and replacement lookup tests passed
together; remove the orphaned legacy location code only in a separately verified
cleanup. Manual filter smoke, whole-Search and whole-app completion remain open
at that checkpoint; see the subsequent bounded smoke below.

### Subsequent bounded filter smoke — 26 October 2026

Installed public demo, iPhone Air / iOS 26.2: category options loaded; Art
selection changed results and count; default locations appeared. Los returned
Los Angeles, clear removed the suggestion, and Port returned Portland.
Selecting Portland alongside Art showed the empty-results screen with two
filters. Reopening retained Portland's selected radio/text. Resetting location
restored results while preserving Art/count 1. Category Reset became disabled
after clearing its selection.

This covers the visible normal/clear/reopen/reset paths, not injected failures,
cache persistence, simultaneous waiter cancellation or forced late responses.
BEH-S14 has bounded manual confirmation; BEH-S15's race guarantee still relies
on controlled tests. Other automated-only checks remain so.
No screenshot regression, physical-device or live-API verification is claimed.

The orphan location implementation and its three tests have now been removed
from the working tree, recoverable from Git. These manual checks use the
pre-cleanup installed binary. Fresh cleanup build/tests remain blocked by
execution permissions (exit 74 before compilation), not passed.
Whole-Search and whole-app migration remain incomplete.

Post-cleanup follow-up confirmed 27 October 2026: the user-run Terminal check
in /private/tmp/kickstarter-search-lookup-cleanup.PQ3So7 passed all 111 tests
(zero failures/skips) and the app build. This supersedes the cleanup execution
blocker above. No Swift or project changes followed that successful run.
Manual smoke remains bounded to the pre-cleanup binary; broader validation
and the rest of the migration remain outstanding.

## Selection-state checkpoint — verification pending, 27 October 2026

Ordinary main-actor state replaces reactive filter storage. Direct Feature query
construction must be usable without subscriptions/initial signals, must not start
IO, and must preserve query text, every selected field, page size 15 and false
toggles represented as nil. New native API tests cover these requirements.

Compatibility requirements retained, inferred from current source:
the signal projection waits for initial selection; reset-all emits category,
state, percent, location, amount, goal, following, recommended, projects-we-love,
saved in that order, retaining sort. Clear resets sort last. Repeated identical
assignments still emit. New initial-barrier and ordered-emission tests protect
these details; they are not permission to redesign the UI or analytics.

Six new tests plus the 111-test baseline are pending runtime verification.
Syntax parsing passed but is not a type-check or test result. The build attempt
was sandbox-blocked before compilation. Earlier manual smoke does not validate
these newly changed files. Query/lifecycle and analytics adapters remain in use;
the overall migration is still in progress.

Follow-up verification on 27 October: all 123 focused tests passed and the app
built in `/private/tmp/kickstarter-search-selection-state.jLK7ZB`. This includes
the six selection-state tests and six adapter characterisation tests.
No production adapter changes preceded this result. The earlier pending status
is superseded for selection state only; UI/snapshot checks remain outstanding.

## Query/lifecycle adapter contract — 27 October 2026

| ID | Preserved requirement | Baseline protection | Status |
| --- | --- | --- | --- |
| SEARCH-ADAPTER-01 | Nonanimated appearance does not start discovery or track a page. First animated appearance initialises it once. | testNonAnimatedAppearanceDoesNotStartDiscoveryOrTrackPage | Confirmed by passing test; preserve existing animated flag semantics |
| SEARCH-ADAPTER-02 | Returning while loading retains the current request and tracks the latest query with the last published count. | testRepeatedAppearanceTracksWithoutReplacingInFlightRequest | Confirmed |
| SEARCH-ADAPTER-03 | First animated appearance replaces early text with discovery text without clearing filters. | testFirstAnimatedAppearanceReplacesEarlyQueryWithoutClearingFilters | Inferred intent, characterised and passing |
| SEARCH-ADAPTER-04 | Appearance before filter initialisation does not later backfill a page-view event. | testAppearanceBeforeLoadDoesNotBackfillPageView | Inferred intent, characterised and passing |
| SEARCH-ADAPTER-05 | Failed query adds no completion analytics; later appearance still tracks with retained count. | testFailedQueryDoesNotTrackCompletionButAppearanceStillTracks | Inferred error policy, characterised and passing |
| SEARCH-ADAPTER-06 | Card navigation preserves ref tags and click analytics include current query/filter parameters. | testCardClickAfterFilterChangeTracksCurrentParameters and existing ref-tag tests | Confirmed |

Post-change results for the upcoming adapter implementation are not yet available.

Adapter implementation now uses explicit input/lifecycle state and direct
appearance/card analytics. The six requirements above remain protected by the
same passing baseline tests; their post-change runtime results remain pending.
SEARCH-ADAPTER-07: reaching the final three rows requests a page once per threshold
crossing, including after a completed page; returning away from that threshold
allows a subsequent page. Protected by
testPaginationRequiresAnotherThresholdCrossingAfterPageCompletes (new, unverified)
and existing paging flow tests. No layout/navigation/copy changes intended.
Manual first appearance, return from detail, text/clear/filter changes, pagination
and banner checks remain required. Static parsing does not prove these outcomes.

Post-change verification confirmed 27 October 2026:
`/private/tmp/kickstarter-search-lifecycle-adapter.OvyAOX` contains 124 successful
tests with zero failures/skips and a successful app build. SEARCH-ADAPTER-01
through SEARCH-ADAPTER-07 therefore have passing focused post-change protection.
Manual UI and broader validation gaps above remain; migration is not complete.

## Completion analytics compatibility — pending verification, 27 October 2026

BEH-S09 describes the normal successful-page path. It is not a guarantee that
every pagination/error sequence emits no event: the legacy zero-count and
buffered-pairing behaviour below qualifies that wording. Do not silently fix
these potential analytics defects during an architecture-preserving migration.

| ID | Source-inferred legacy requirement | New protection | Status |
| --- | --- | --- | --- |
| SEARCH-ADAPTER-08 | Each empty non-discovery response emits zero-count analytics. | testEmptySearchesTrackZeroOncePerResponse | New test; runtime pending |
| SEARCH-ADAPTER-09 | Empty terminal pagination emits zero-count analytics while accumulated cards remain. | testEmptyTerminalPageTracksZeroWithoutDiscardingCards | New test; runtime pending |
| SEARCH-ADAPTER-10 | Unpaired empty/error settlements persist across queries; a later first-page ordinal may track before cards/loading=false publish. | testRecoveryAfterEmptyAndFailedQueriesPreservesAnalyticsPublicationTiming | New test; runtime pending |

The replacement explicitly owns the FIFO pairing and retains the independent
zero-count path. It uses current query/filter values when tracking, suppresses
discovery completion events, and does not change requests or UI. Three scenarios
are inferred from old source, not yet confirmed by differential runtime testing.
The 124-test/app-build baseline is acb105498d; that pass does not validate this
patch. The new 127-test check and app build await a Terminal run; local execution
was permission-blocked before compilation. No new manual/snapshot result.

Post-change follow-up: /private/tmp/kickstarter-search-completion-analytics.dVAhV6
contains 127 successful tests (zero failures/skips) and a successful app build.
SEARCH-ADAPTER-08 through -10 now have passing replacement protection. Their
legacy semantics remain source-inferred, not old-code differential confirmation.
No additional UI/snapshot/live-API/full-suite verification is claimed.

## Filter presentation lifetime — pending verification

- Lookup refresh/empty suggestions must replace option lists without clearing
  selected category/location or other filter values. Protected by
  testLookupRefreshAndClearPreserveSelectedFilters (new).
- Repeated lookup arrays must retain existing presentation notifications:
  testRepeatedLookupOutputsRetainPresentationNotifications (new).
- Observations belong to SearchFiltersUseCase. Releasing it detaches even if a
  caller retains SearchFilters: testReleasedAdapterStopsUpdatingRetainedPresentationModel
  (new owner-lifetime guarantee, not an active-screen behavioural redesign).
- Existing modal mapping, toggle/no-modal behaviour, logged-in/out pills, reset
  and selection tests remain unchanged. observeForUI scheduling remains.

Static checks passed; the 130-test runtime check and app build are pending.
No new UI layout, copy, storage, identifier or navigation changes.

Post-change confirmation: the Terminal run in
/private/tmp/kickstarter-filter-presentation.iBVlAx passed 130 tests with zero
failures/skips, including these three cases, and the app build. Both builds
report three warnings. Active-screen manual and snapshot validation remain open.

## Explicit query admission — runtime-unverified

SearchViewModel now owns per-screen input readiness and calls native Feature
parameter construction/admission explicitly. Selection policy, request lifetime
and cancellation still belong to SearchFeature.

| ID | Preserved requirement | Added regression protection |
| --- | --- | --- |
| SEARCH-QUERY-01 | Early query text waits for initial selection and then uses the current filters. | testEarlyQueryWaitsForInitialSelectionThenUsesCurrentFilters |
| SEARCH-QUERY-02 | Repeated load does not replace text or selected filters with discovery defaults. | testRepeatedLoadRetainsQueryAndSelection |
| SEARCH-QUERY-03 | A second screen using the shared Feature waits for its own selection publication before admitting a query. | testNewScreenWaitsForItsOwnSelectionPublication |

New tests are source-inferred, not runtime-confirmed. Reset-order and duplicate
request coverage now exercises SearchViewModel rather than the deleted legacy
signal-query overload. Parameter publication must precede admission/loading/cancellation;
query UI notification follows admission, and typed clear resets fields last.
Static parsing passed. The fresh 133-test/app-build attempt exited 74 before
compilation due to session permissions; no new runtime or manual pass claimed.

### Consolidated Search close-out

- `testFilterResetAdmitsRequestsInFieldOrderAndRetainsSort` protects the real
  screen-to-Feature reset route. Nine changed parameter sets admit requests;
  the unchanged nil-location notification shares the pending request.
- `testDuplicateFilterSharesPendingRequestButRefreshesAfterCompletion` protects
  equivalent in-flight sharing without swallowing a later intentional refresh.
- Initial-readiness coverage remains in SEARCH-QUERY-01 through -03. Native
  filter/query tests read ordinary Feature state without subscription setup.
- Remaining signals are UI compatibility: filter notifications/readiness,
  presentation projections, reachability/banner delivery and analytics pairing.
  They do not replace Feature-owned async request/pagination/lookup execution.
  Removing every reactive operator is not a Search exit requirement.
- Expected focused count remains 133 (two projection-only tests replaced by two
  live-route tests). This is a source count, not a recorded test pass.
- A direct Xcode escalation attempt was rejected by the session permission
  policy before execution. Runtime/type-check, strict-concurrency diagnostics
  and final manual/snapshot checks remain open. The current target uses Swift 5
  language mode; syntax parsing alone does not establish concurrency safety.

## Explore baseline preparation — no implementation change yet

Source review of DiscoveryViewModel and DiscoveryPageViewModel establishes these
requirements for the next complete feature, subject to baseline runtime checks:

- Four independently retained sort pages: Magic, Popular, Newest, Ending Soon.
  Page requests wait for user/parameters/visibility readiness. Returning without
  changed user/parameters does not imply a fresh request; pull-to-refresh,
  environment changes and blocked-user events explicitly refresh.
- Retain cards during refresh (`clearOnNewRequest: false`). Append distinct
  projects using the existing pagination URL, not Search's GraphQL cursor.
  Filter-change clearing and empty-state emission have separate ordering rules.
- Fetch an activity sample on signed-in appearance. Preserve seen-activity
  storage and the existing logout/navigation clearing rules and destinations.
- Preserve recommendation opt-in defaults, onboarding/personalisation flags,
  loading animations, playlist/ref-tag navigation and analytics timing.

One concrete DiscoveryFeature should own page-keyed collections and request
identities, constructed in AppModel; it must not share Search's collection or
cancel another sort page's work through one global request slot. Session and
seen-activity persistence retain their existing authoritative owners. Keep
existing controllers and presentation bindings. First validate the existing
DiscoveryViewModelTests and DiscoveryPageViewModelTests, then convert page and
sample requests as one integrated feature with cancellation/stale-result tests.
Both Discovery suites contain only logic/output assertions. Their existing
per-suite reference-simulator opt-out is now enabled (55 test methods); the
shared TestCase and all visual suites retain the reference-device guard. The
consolidated verification selects these alongside Search's expected 133 tests:
188 expected total, followed by the app build. This preparation is not a claim
that Explore is migrated or baseline-tested.


## Pledge mutation ownership — 28 October 2026

- Preserve create/update input fields: amount, reward/add-on identifiers, location,
  payment source, Apple Pay input, incremental mode, setup intent and create ref tag.
  Use the existing GraphQL input adapters and checkout/SCA response mappings.
- Preserve current cancellation wire behavior: backing ID is sent; the legacy
  client does not transmit its optional cancellation note. No new payload implied.
- Preserve reward-received REST route, project/backer IDs and Boolean value.
- PledgeFeature owns admitted writes independently of screen observation. Equivalent
  pending tails share; distinct commands execute in admission order within one
  account generation, including across create/update/cancel/received screens.
- Disposal/caller cancellation suppresses presentation but does not undo an admitted
  server write. Failed writes do not automatically retry or block later commands.
  This is local pending-request sharing, not a server idempotency guarantee.
- Account changes invalidate queued commands before admission and suppress old
  success/error delivery, including after artificial presentation delays. Already
  sent writes settle; a new generation has an independent command queue.
- Preserve existing loading/error/navigation, Apple Pay and SCA presentation,
  analytics and reward checkbox behavior. Public demo rejects all four writes.
- Original screen assertions remain; async test fixtures wait for owned operations
  before temporary environments end. Only the three nonvisual suites opt out of
  the reference-simulator gate. Real payments and visual/device parity remain open.


## Backing management and post-campaign checkout — 28 October 2026

- ManagePledge retains its REST project load followed by GraphQL rewards/payment-
  plan metadata, plus the separate backing query with increments, add-ons, refunds
  and expanded shipping rules. Keep the initial-project cache and backing refresh
  behavior, menu options, totals, payment display, banners and 300ms refresh animation.
- Feature-owned read routes share equivalent pending requests, supersede changed
  inputs and cancel on screen release/session changes. Screens have independent
  project/backing routes. A refresh waits for preceding writes and does not share
  a pre-write pending read. Completed reads are not cached by the Feature.
- The artificial API delay is applied once to the combined project response;
  formerly the project and rewards requests each applied it. Its production default
  remains zero. The actual sequential request dependencies and refresh animation
  remain; simulated latency is not a live-service performance measurement.
- PostCampaignCheckout creation, card/Apple Pay validation and completion use the
  same account-generation command owner as pledge mutations. Preserve amount,
  repeated reward IDs, location/ref tag, checkout-ID conversion, payment source,
  nullable reuse/Apple Pay fields and payment-intent secret. Never log these inputs.
- Validation retains the valid flag and server messages/error mapping. The complete
  mutation retains its raw GraphQL response contract, including existing downstream
  success/error interpretation. There is no automatic retry or server idempotency
  guarantee. Disposing observation does not undo an admitted financial write.
- Preserve existing Stripe authorization, checkout-terminated presentation, loading,
  button enablement, error/navigation and analytics bindings. This migration does
  not assert live Stripe, Apple Pay/3DS or server mutation verification.
- Existing checkout completion assertions now await the command. The old project-
  retry test omitted backing data; it now explicitly fails both reads and asserts
  two error/header events before a successful retry. Other business assertions are
  retained. Only the nonvisual ManagePledge suite newly opts out of the reference-
  simulator gate; visual/snapshot checks remain separate.


## Pledge-manager navigation and reward add-ons — 28 October 2026

| ID | Requirement | Baseline / protection | Scope limit |
| --- | --- | --- | --- |
| BEH-PM-01 | Opening a native update from pledge-manager loads its project and then its update; failures remain silent and never navigate with a partial pair. | 14 original PledgeManagerWebViewModel tests; new PledgeFeature paired-request, replacement, close and session tests. | Live web/server navigation remains unverified. |
| BEH-RA-01 | No-reward, missing reward and rewards without add-ons do not fetch add-ons; a successful nullable add-on response retains bonus-only behavior. | Original selection tests; Feature eligibility and nullable-result tests; native mock nil/empty/failure checks. | API fixture coverage does not prove live integration. |
| BEH-RA-02 | Preserve standard versus fast-query choice, reward ID, shipping location/country and country fallback. Preserve backed/unavailable, digital, local-pickup and shipping eligibility rules. | Original selection tests; Feature provider-input/fast-country cases and existing GraphQL mapper suite. | No product redesign or experiment-default change. |
| BEH-RA-03 | Preserve quantities, amounts, loading, pull-to-refresh error/retry, bonus support and continue navigation. | 15 original RewardAddOnSelectionViewModel tests; asynchronous completion awaited, business assertions retained. | Logic suite opts out of the snapshot reference-device gate; visual checks remain separate. |
| BEH-RA-04 | Replacing a request, releasing a screen or replacing its session prevents obsolete data/errors reaching the current screen. Equivalent pending reads share; explicit refresh after completion starts a new request. | Controlled noncooperative providers, cancelled-caller test and request/configuration coherence test. | Local sharing is not persistent caching or server idempotency. |

The unused RewardsUseCase enrollment helper had no application or test callers.
It is removed; the active ProjectDetailsFeature enrollment sequence and its tests
remain. Existing four login-gating tests remain intact. Add-on API delay now belongs
to the owned async task, so cancellation/account checks also cover that delay.
The display adapter retains each result's requesting project/reward/shipping data.

## Curated and post-backing recommendations — 28 October 2026

- Onboarding queries each selected category with live state and integer 30/category
  page budget, combines successful results, retains duplicates, and shuffles them.
  A failed category contributes no projects; an empty combined response displays
  the existing generic error. Empty category input performs no request/output.
- Thanks first loads the root category, then tries recommended (six), similar
  (three), and staff-picked category projects (three), in that order. Exclude the
  backed project, deduplicate by ID, and stop after three alternatives. A discovery
  failure allows the next source; a failed category or empty final list emits no
  recommendation section. Keep the existing recommended-list shuffle algorithm.
- Pair each list with its own category. Reconfiguration, route release and account
  replacement suppress obsolete results, including providers that ignore cancellation.
  Equivalent pending inputs on the same route share; independent screens do not
  cancel one another. Closing a screen cancels its pending recommendation reads.
- Preserve navigation/ref tags, newsletter settings ownership, analytics payloads,
  alerts, labels and layouts. Reactive outputs remain presentation adapters only.
- The 24 original CuratedProjects/Thanks logic tests passed before production edits.
  CuratedProjects alone newly opts out of the visual reference-device gate; no
  snapshot suite or global gate changes. Live recommendations remain unverified.

## Project attribution — 28 October 2026

Preserve one page-view mutation per ProjectPage instance, the current event name,
project graph ID and optional ref-info properties. Failure remains silent with no
automatic retry. The Feature owns admission; closing a page does not undo an event
already sent. An account change before dispatch rejects the obsolete event.
The native Apollo boundary retains cancellation/error handling. Existing unrelated
cold third-party advertising producers are not activated by this migration.

UpdateDraft's 29 original logic tests pass as the baseline for the next stage.
Only that nonvisual suite opts out of the reference-simulator gate; snapshot suites
retain their existing checks.

## Creator draft editing and images — 28 October 2026

- Preserve draft read, title/body/public fields, update number, focus/placeholder
  behavior, picker choices, error outputs, and Preview/Close destinations.
- CreatorDraftsFeature owns a native read route and a per-project/account command
  queue. Equivalent pending edits share; changed saves, uploads and deletions execute
  in admission order. A save uses the latest completed attachment state. Unchanged
  fields avoid an unnecessary server write. Failures permit an explicit later retry.
- Read replacement/release and account changes reject obsolete outcomes. Admitted
  writes settle after observation ends; account changes prevent queued dispatch.
  A save result retains its initiating action. Replaced save observation cannot
  trigger navigation for a newer action before that newer command completes.
- Correct attachment-state defects exposed by ownership: a later upload does not
  restore a deleted attachment; current attachments participate in Preview validation.
  Unsupported video deletion uses the existing failure output instead of trapping.
- REST paths, verbs, field names, authentication and response decoding remain.
  Image transport uses native URLSession async data, with multipart preparation
  off the UI actor, valid CRLF framing and errors for unreadable/empty/non-file input.
  Public demo rejects creator reads/writes rather than claiming live success.
- Baseline 29 original logic tests passed. They now await owned operations with
  original assertions retained. This retained model has no application constructor
  call found in the current checkout; actual editor reachability and device/image
  picker behavior are not established by these tests.

## Startup, navigation and creator blocking — 28 October 2026

Preserve config refresh triggers, visitor cookies, debug feature overrides, five-second
push debounce, Braze delivery, shortcut ordering/failure fallback, category matching,
and every existing deep-link controller stack. A resolved link is one operation:
project, optional update and optional replies must belong to the same destination.
A newer link (including a synchronous tab link), session change or delegate release
invalidates old navigation, including a resolved action waiting for UIKit.
Equivalent pending destinations share work.

Root Tabs retains the selected destination when it exists in the new layout.
Removing the selected Activity tab returns to Discovery. In the floating
layout an explicit Activity route opens the existing Activity screen on
Discovery's stack.

Root Tabs reads the effective floating-tab setting from the composed
SettingsFeature on initial load and foreground entry. A local override takes
precedence over the remote client and the absence of both remains false. The
controller rebuilds its layout only when that effective value changes.

Pledge Manager navigation continues to allow Stripe actions and prepared supported
requests, redirect supported unprepared requests through the authenticated request
path, route recognized native Kickstarter destinations, and cancel other
Kickstarter URLs. An otherwise unrecognized external URL is allowed only when the
effective Pledge Manager bypass setting is enabled; local override, remote client,
then false remain the policy precedence.

Push registrations are admitted writes: equivalent pending tokens share; changed
tokens execute in order, without automatic retries. Stale account completions cannot
publish. Project creator blocking cooperates with the existing DiscussionFeature;
screen release only stops observation of an admitted block. Preserve success
notifications, errors and analytics. No screen design or live service action is part
of verification; use controlled providers and public demo fixtures.


## Developer pagination and rich-text examples — 29 October 2026

- Pagination first appearance requests default discovery parameters; pull-to-refresh
  uses staff picks/magic. Preserve rows while loading, append duplicates on the next
  page, stop at an empty page, and retain the original status/error strings. A failed
  page clears rows/cursor; an explicit refresh retries. Terminal next-page commands
  return immediately instead of waiting for a nonexistent publisher event.
- Rich-text list preserves order, nullable-node filtering, localized error text and
  nonempty caching when visiting a selected project and returning. Empty/error lists
  can retry. Accept the same raw owner/slug and project URL formats.
- Equivalent pending requests share within one screen route. Refresh replaces an
  old page; edited/cleared slug, screen suspension and session replacement reject late
  responses. Independent routes cannot cancel each other. No automatic write or live
  service verification. ViewModels are owned inline by their Views; request and cache
  policy belongs to DeveloperExamplesFeature composed in AppModel.
- All layout, text, navigation callbacks, colors and preview content are retained.
  Existing generic Paginator remains for other consumers; this example no longer uses
  its Combine request/next-event loop. Physical-device and visual parity remain gates.

### Pagination sentinel integration — 29 October 2026

A visible pagination row must re-evaluate after the initial page supplies rows,
and must disappear once the example reaches a terminal page. The waiter belongs
to the SwiftUI row; Feature owners coalesce repeated requests. Keep the existing
list, cell, status and spinner styling. The demo's first-six-row stall was observed
and corrected; one terminal-state regression and the shared PPO suites passed.

### Email-click redirects — 29 October 2026

Resolve the first HTTP redirect only, preserving default URLSession configuration
and existing silent failure/no-destination behavior. Never follow its target as
part of this resolution. A navigation route owns one current read: equivalent
pending URLs share, changed links supersede, ordinary new navigation and session
reset reject obsolete results. Deliver to the existing navigation input on MainActor.
The delegate only declines redirect following; it never touches UI or ViewModels.

### Root avatar — 29 October 2026

Preserve the cache-first tabbar-avatar-image hash filename, default URLSession
configuration, atomic best-effort cache write, existing circle/size/border rendering
and silent read failure. Cached bytes now arrive asynchronously, consistently with
downloaded bytes after tab styles are installed. A visible placeholder may therefore
appear briefly on a cache hit. Do not let a changed account/session, avatar URL,
logout or rebuilt tab index accept an obsolete image. The Profile Feature shares
equivalent pending reads; canceling a presentation waiter need not cancel a shared
cache fill. Logout/reset cancels the Feature read. Disk work runs on a storage actor.

## Permission/onboarding/configuration ownership — 29 October 2026

- PERMISSION-01: Preserve notification options and registration only on grant.
  Share equivalent pending prompts; serialize differing options. Observer cancellation
  suppresses delivery but never claims to retract admitted system consent.
- ONBOARDING-01: Keep pages, styling, navigation/analytics and already-authorized
  behavior. Appearance owns subscriptions; close/advance invalidates async completion.
  ATT keeps its existing authorization/ad-identifier updates.
- REMOTECONFIG-01: Keep public-demo guards, defaults, activation success/failure inputs
  and Crashlytics filtering. Retain/remove the SDK listener; realtime updates remain
  log-only. Share pending refreshes per client and reject replaced-client completion.
  An SDK activation already accepted may still change its cache.
- PERMISSION-02: Controlled tests do not prove physical-device consent UI or live
  Firebase behavior; those gates remain open.

## Video-feed player lifetime — 29 October 2026

- PLAYER-01: Keep the three-second startup/recovery policies, once-per-item failure,
  progress/watch counter calculations and existing scrub/loop UI. Repeated stalls
  share the first pending recovery window.
- PLAYER-02: Stop/reuse/release invalidate timers and per-item progress observation.
  Seek replacement, pause and stop reject obsolete completions. Current seek failure
  still reaches recovery UI; invalid-duration completion now arrives asynchronously.
- PLAYER-03: Platform notifications/periodic observations remain AVFoundation
  callbacks on their explicitly configured main queue; player/UI state is MainActor
  isolated. Controlled tests are not populated-video, audio hardware or visual proof.


## Checkout and managed-pledge response values — 29 October 2026

- Convert checkout validation, completion, payment-plan, managed backing and reward
  responses on the existing Apollo callback executor before resuming async callers.
  Preserve native cancellation, first GraphQL error precedence, request inputs and
  no automatic retry. A server-accepted write is not reversed by local cancellation.
- Checkout validation keeps server messages and distinguishes a missing checkout
  (parse failure) from a present invalid checkout (validation failure).
- Checkout completion consumes no nested payload: any successful root data still
  acknowledges completion. Missing root data or GraphQL errors still fail. Existing
  Feature write sharing/session checks and observer-disposal behavior remain intact.
- An absent project/payment plan is a successful nil plan. An ineligible plan is
  retained, including an empty installment list. Invalid installment dates are
  omitted as before; valid installment order, currency, formatted amount, collection
  date and unknown refund state remain unchanged. UI preselection still uses the
  request's project and current eligibility; stale amounts cannot replace a newer plan.
- Managed backing retains payment/refund/badge, add-on, reward, shipping and order
  values; missing required backing data remains a parse failure. Managed rewards
  retain shipping/local-pickup and optional payment-plan explanations. Missing project
  data retains the existing empty/disabled fallback. No new eligibility rules.
- Checked Sendable conformances apply only to reviewed value graphs; generated
  Apollo types and mutable services are not declared unchecked Sendable. Legacy
  reactive service signatures/fixtures remain compatible. UI and storage are unchanged.
- Verification covers 1,979 selected tests and an app build, not all repository
  snapshots or live checkout/payment integration. Final visual/device gates remain open.

- Pledge read tasks carry completion only. Mixed project/update results remain in
  a MainActor-owned result slot. Equivalent pending reads still share success/error;
  canceled callers cannot consume a shared result, while other live waiters can.
  Route/session invalidation, read-after-write ordering and original errors remain.

## Pledged-project overview response snapshots — 2 November 2026

- Preserve incomplete-card rejection, currency formatting, address line ordering,
  tier-specific actions and confirm-address fallback to surveys.
- Preserve reward-toggle feature gating and all existing analytics values, including
  event-time relative date calculations. Preserve initial project-page content.
- Preserve coalescing, pagination, cancellation and stale route/session rejection.
- Copy generated response data before native callback continuation transfer; keep
  presentation decisions in the Feature and image-loader objects in the view.
- Validation: 50 selected tests passed with zero failures/skips: 17 Library, 30 framework and 3 API. App build succeeded with zero errors and five warning entries (generated asset-name collisions and Crashlytics script).

## Project and story value boundaries — 2 November 2026

Preserve fast parallel base/extras failure cancellation and legacy enrollment → project →
backing → rewards ordering. Preserve missing/empty rich text, nested image normalization,
links, media metadata and HTML components. Preserve no-reward insertion position and the
missing-project result without invoking insertion. Account/reporting/block acknowledgements
still accept root data; mapped parse failures retain their existing error. Session feature
enums round-trip their raw names on the owning actor. The verified migration checkpoint
and non-additive test counts are recorded in MIGRATION_LEDGER.md.

## Remaining response providers — 2 November 2026

Profile backed/saved pagination, video feed/watch, comment/reply/post, recommendation categories,
rich-text examples, report options and Search results/lookups now project generated GraphQL data
before native continuation transfer. Checked snapshots include cards, pagination, analytics,
navigation IDs, video inputs and story elements. UI formatting, ID-only Search equality,
result event ordering, missing-envelope errors and Feature cancellation/session policies remain.
The unused raw cancellableQuery overload was removed. Generic Service.fetch/AsyncApolloClient
remain compatibility APIs; the application roots have no direct `.fetch(query:)` call sites.
Session setup stores feature raw names with a compatible mutable enum accessor/decoder; recommendation
child tasks use an explicitly actor-isolated sleeper and Sendable provider contract.

Verification: 1,439 Library and 399 framework regression tests passed. API regression initially
passed 146 with one new test failing because an old JSON fixture lacked projectTags; that test now
uses the existing typed project-card mock. Final runs passed 157 focused Library tests and 41 API
tests, including five new value/decoding tests. Counts overlap and must not be summed as unique
coverage. App build with complete concurrency checking passed in Swift 5 mode. Other diagnostics,
full visual/device and live-operation validation remain open. This is not migration completion.

## REST and UI isolation — 2 November 2026

The shared native REST wrapper now inherits caller isolation through request preparation and
response decoding, matching the existing URLSession helper. It no longer sends Service/Route
values to an unrelated executor. Messaging, configuration, draft/update, discovery parameters,
deep-link destinations and empty acknowledgements have checked Sendable value graphs. Feature
pending result types are constrained accordingly. Recommendation children capture checked values
and an explicitly Sendable main-actor sleeper; provider calls still hop to their actor.

Nine additional UI delegate protocols now declare MainActor. Activity, backed/saved Profile and
root-tab session/user notifications use MainActorNotificationObservation with synchronous delivery,
weak controller captures and owned automatic removal. Other root-tab platform observers are retained.
No UI redesign or persistence change is included.

Integrated validation passed 1,986 tests (1,439 Library, 399 framework, 148 API), zero failures/skips.
Final targeted validation and complete-concurrency compilation are recorded in the external evidence.
An initial duplicate actor annotation was corrected; Simulator preflight failed once and recovered
by booting the existing iPhone Air. No user intervention was needed. The public demo launched and
rendered populated Explore artwork/cards; this is a limited smoke check, not full visual parity.
Other compiler diagnostics and live/device checks remain; app-wide migration is not complete.

## Notification extension lifetime — 2 November 2026

RichPushNotifications now owns an async URLSession download per delivery. A narrowly locked
request object claims notification content/completion exactly once. Expiry, replacement,
cancellation, attachment failure and success cannot deliver twice; late downloads cannot
replace the original after expiry. Completion and task cancellation occur outside the lock.
Missing/invalid payloads and failed attachments retain the original notification. The lock-backed
unchecked conformance documents SDK content/handler ownership, not blanket payload sendability.
Seven executable macOS checks using the actual source passed: missing payload, expiry before
start, failed download, non-cooperative late completion, concurrent expiry, successful PNG
attachment and reentrant completion. Complete-checking iOS Simulator extension/app build passed;
existing project/asset warnings remain. Actual APNs/system expiry integration remains unverified.

### UIKit SDK delegate contract checkpoint — 2 November 2026

PassKit and mail-composer delegate isolation preserves callback bodies, synchronous reply
policy, dismissal and analytics ordering. The payment-plan UI delegate is main-actor owned.
Twenty-six selected payment lifetime tests passed; snapshots were compiled but not run on
the unavailable reference runtime. No live mail/payment validation is implied.

### Push and UI contracts — 2 November 2026

Native async notification callbacks preserve badge updates, banner/list presentation options,
root-controller availability guard and existing PushEnvelope navigation mapping. Decoding
happens before the main-actor hop; SDK completion follows awaited UI handling. The dictionary
ViewModel input remains for compatibility and routes through the same decoded envelope.
Local simulated foreground push changed Activity badge to 3. Notification tap/live APNs remain
unverified. UI protocol changes preserve bodies and reference snapshot checks.

### UI owner contracts — 2 November 2026

Discovery filter output ordering, feature-flag updates, backing date presentation, device-ID
fallback, application URL opening and analytics values retain their existing assertions.
194 nonvisual tests passed. Demo category expansion/selection and project FAQ/Risks navigation
were observed on iPhone Air iOS 26.2; this is not reference snapshot parity.

## Analytics ownership — 2 November 2026

Analytics state and emissions are main-actor-owned. The default owner can be constructed
without accessing UIKit; device orientation is read at emission time, not captured at startup.
Explicit user/configuration/consent updates preserve the previous in-place identity changes
and event ordering. Login/OAuth persistence closures declare their actor without introducing
asynchronous event reordering. UIKit device identifier reads remain in UI-owned methods.
Existing event names/payloads, consent gating, native UI and persistence keys are unchanged.
The global Environment stack is not certified concurrency-safe by this checkpoint.

## Formatting shared state — 2 November 2026

Date and numeric cache lookup, creation and rendering are synchronous protected operations;
no lock spans an await. Mutable formatter objects do not escape through the current cache
call sites. Attributed currency formatting constructs a request-local formatter so one
request's style cannot overwrite another's. Existing locale, currency-code disambiguation,
rounding and fraction-digit behavior is retained. New value-only rendering overloads allow
callers to supply resolved locale/time-zone/currency inputs without the global Environment.
Analytics project calculations now receive captured Date/Calendar values from the actor.
The legacy formatting convenience APIs still read Environment and are not certified as
safe for arbitrary concurrent environment mutation.

## Activity platform composition — 17 November 2026

- ActivityFeature receives survey resolution, application-badge access and page
  response timing through an explicit Platform composed by AppModel. The Feature no
  longer reaches into AppEnvironment for those dependencies.
- Page pagination and survey resolution remain independently owned tasks. Existing
  sorting, empty-page refresh, retry, logged-out admission, session replacement and
  late-result rejection behavior is unchanged.
- Response timing is captured when a page is admitted and applied after a successful
  provider response before publication. Survey requests and badge reads retain their
  existing timing and presentation boundaries.
- Controlled Feature coverage proves all three injected policies reach the owned
  behavior. Bounded Library and presentation selections cover the AppModel graph,
  screen adapter, routing, shared following state and root presentation consumers.
- This checkpoint does not establish live survey, push-badge, visual or whole-suite
  behavior, and it is not a claim of full CFA compliance.

## Creator Drafts response-policy composition — 17 November 2026

- CreatorDraftsFeature receives response timing through explicit AppModel
  composition and no longer reads AppEnvironment when admitting reads or writes.
- A draft read captures policy at admission, waits for an already-admitted edit,
  then delays successful publication. Each ordered save, upload or removal captures
  policy at admission and delays attachment publication after durable mutation.
- Equivalent saves still share work; different edits remain ordered. Route release,
  reset and session replacement continue to reject obsolete presentation results
  without claiming to undo an admitted server mutation.
- Controlled coverage proves both read and write timing boundaries. Live uploads,
  server persistence, visual behavior and the whole Library suite remain outside
  this checkpoint.

## OAuth authorization composition — 17 November 2026

- AuthenticationFeature's platform now supplies the OAuth web base URL and client
  identifier. The screen-owned OAuth adapter asks the Feature to construct the
  authorization URL instead of reading AppEnvironment.
- The path, redirect scheme, response type, email scope, PKCE S256 method and code
  challenge are unchanged. Token exchange, matching-user fetch, pre-commit login
  analytics and exactly-once session establishment retain their existing ownership.
- Canceling or releasing the adapter still rejects late redirects and session commits;
  external session replacement still invalidates an admitted authorization.
- Controlled coverage verifies the injected URL/client ID and existing redirect,
  cancellation, failure and success cases. The system browser, live OAuth server and
  end-to-end external callback remain unverified.

## Onboarding tracking eligibility ownership — 17 November 2026

- The same composed tracking adapter now answers both onboarding prompt eligibility
  and the application-owned authorization request. Eligibility remains true only
  while the advertising identifier is absent and authorization may be requested.
- The localized onboarding item source remains responsible only for its five display
  items. Button analytics, prompt presentation, prompt sharing, cancellation and
  completion behavior are unchanged.
- Controlled coverage verifies eligible, already-identified and unavailable-adapter
  cases. Live system consent UI, visual behavior and the whole Library suite remain
  outside this checkpoint.

## Apple Pay request policy composition — 17 November 2026

- PaymentsFeature receives supported Apple Pay networks from AppModel and supplies
  them to the request formatter for crowdfunding and post-campaign checkout.
- Merchant identifier, 3DS capability, project country/currency, shipping type,
  reward, bonus, shipping and total summary-item behavior are unchanged.
- Checkout controllers use the same PaymentsFeature instance as their view models.
  Live Apple Pay presentation, authorization, Stripe confirmation and physical-device
  wallet behavior remain outside this checkpoint.

## Pledged Projects formatting-locale composition — 17 November 2026

- PledgedProjectsFeature receives locale through AppModel composition and captures it
  when admitting each page request. Every card produced by that response uses the same
  captured locale; card parsing no longer reads AppEnvironment.
- Existing pledge amount, currency-code disambiguation, address, image, analytics and
  navigation behavior is preserved. Pagination, refresh, request sharing, account
  replacement and late-result rejection retain their existing Feature ownership.
- Controlled coverage proves two supplied locales produce their corresponding currency
  presentations. Live account data, visual parity and the whole Library suite remain
  outside this checkpoint.

## Settings application-version ownership — 17 November 2026

- AppModel supplies the installed application version to SettingsFeature. The
  Settings view model combines that raw metadata with the localized footer label;
  SettingsSectionType remains static section-layout metadata.
- The existing footer visibility policy and version text are unchanged. Other
  settings destinations, refreshes and preference writes retain their existing
  Feature ownership and task behavior.
- Controlled coverage proves the supplied version reaches the rating footer and
  unrelated sections have no footer text. Visual rendering and release-bundle
  metadata remain outside this checkpoint.

## Stripe publishable-key ownership — 17 November 2026

- AppModel supplies the current Stripe publishable key to PaymentsFeature. Pledged
  Projects, crowdfunding checkout, post-campaign checkout and payment settings read
  the same Feature-owned value rather than independent AppEnvironment closures.
- Existing staging/production selection, Apple Pay merchant identifier, SDK setup
  timing, card selection and checkout task ownership are unchanged. PaymentsFeature
  remains the application boundary; Stripe SDK mutation remains presentation work.
- Controlled Feature and Pledged Projects tests prove the supplied value reaches
  presentation. Live Stripe, wallet, authorization and reference-device snapshots
  remain outside this checkpoint.

## Payments presentation-platform ownership — 17 November 2026

- PaymentsFeature supplies pledge currency context, Apple Pay card eligibility and
  response timing alongside its Stripe and Apple Pay network policies. Crowdfunding,
  post-campaign, Manage Pledge and payment-settings presentation consume that Feature
  rather than accepting parallel environment closures.
- Currency symbols and locale, eligibility decisions, response-delay timing, checkout
  task ownership, card selection and admitted mutation behavior are preserved. Missing
  test-only platform values retain inert defaults rather than a hidden global fallback.
- Controlled coverage proves independently composed platform values. Affected checkout,
  Manage Pledge, AppModel and native-payment regressions preserve existing behavior.
  Live transactions, wallet authorization and reference-device snapshots remain outside
  this checkpoint.

## Reward-received mutation ownership — 17 November 2026

- PledgeFeature owns the Manage Pledge reward-received mutation's analytics, ordered
  request admission, session validation and configured presentation delay. The controller
  supplies the shared Feature and the view model observes its result.
- Toggle ordering, duplicate sharing, current-account user selection, delayed presentation,
  replacement-backing suppression and analytics context remain unchanged. Cancellation of
  screen observation does not abandon an already admitted write.
- Controlled Feature coverage proves composed tracking and delay policy. Focused and
  bounded Pledge, AppModel and Manage Pledge tests preserve existing behavior. Live account
  mutation, visual rendering and the whole Library suite remain outside this checkpoint.

## Manage Pledge presentation composition — 17 November 2026

- PledgeFeature receives Manage Pledge page-view tracking from AppModel composition.
  ManagePledgeViewModel reports the loaded project, reward and checkout properties
  through that Feature instead of accepting a global analytics accessor.
- ManagePledgeViewController no longer reads AppEnvironment. Its iPad form-sheet
  choice remains presentation-owned and reads UIKit's current device idiom directly;
  navigation, modal style and analytics payload behavior are unchanged.
- Controlled Feature and view-model coverage proves the composed tracking path and
  preserves the existing page-view event. Live analytics delivery, visual rendering
  and the whole Library suite remain outside this checkpoint.

## Discovery application dependency composition — 17 November 2026

- AppModel supplies DiscoveryFeature's authenticated service, category loader,
  local and ubiquitous preference stores, server/build metadata and response timing.
  AsyncDiscoveryProvider retains the supplied service rather than resolving a global.
- Favorite categories still read both stores and toggle each independently. Tip
  claiming still marks both stores; personalization, onboarding-category and activity
  sample preferences retain their existing local-store behavior.
- Feed request identity, pagination, cancellation, session replacement and delayed
  response rejection are unchanged. Controlled coverage verifies direct service,
  store and metadata composition; live discovery data and visual behavior remain
  outside this checkpoint.

## Search and discovery-category composition — 17 November 2026

- AppModel supplies SearchFeature's lookup provider, whose authenticated service and
  cache are explicit retained dependencies. Search request, lookup overlap,
  cancellation and stale-result ownership remain in SearchFeature.
- DiscoveryFeature composes the category-loading use case from its category loader,
  cache, response timing and sleep policy. DiscoveryFiltersViewModel observes that
  composed use case and no longer constructs one from the process environment.
- Existing cache-first behavior, retries, response timing, category presentation and
  Search screen behavior are preserved by 36 focused and 188 bounded passing tests.
  Live services, visual rendering and the whole Library suite remain outside this
  checkpoint.

## Help web request composition — 17 November 2026

- HelpFeature owns mapping a HelpType onto the configured web host and preparing the
  authenticated URL request. AppModel supplies both application dependencies.
- HelpWebViewController composes its screen model with the shared HelpFeature;
  HelpWebViewModel retains only the selected HelpType and asks the Feature for the
  request when the view loads.
- Cookie, Help Center, How It Works, Privacy and Terms paths are unchanged. Focused
  AppModel and Help presentation tests pass; live web loading and visual rendering
  remain outside this checkpoint.

## Pledge status web-host composition — 17 November 2026

- PledgeFeature exposes the web host already supplied through its platform. The Manage
  Pledge summary controller passes that value into PledgeStatusLabelView's legitimate
  screen-specific view model.
- PledgeStatusLabelView no longer resolves AppModel.shared or borrows Project Details
  composition. Existing pledge-state copy, badge visibility and backing-details links
  are unchanged.
- Focused status, summary and Pledge Feature tests and the bounded Manage Pledge/AppModel
  selection pass. Live navigation and visual rendering remain outside this checkpoint.

## Onboarding analytics composition — 17 November 2026

- AppModel supplies OnboardingFeature's page, CTA, system-dialog and permission-result
  analytics capability. The Feature remains the shared owner of completion and system
  permission requests and is now also the reporting boundary for that workflow.
- OnboardingViewModel retains appearance bindings and presentation sequencing but no
  longer resolves analytics through AppEnvironment. Existing event names, contexts,
  prompt ordering, authorization gating and completion behavior are unchanged.
- Direct Feature coverage proves every composed analytics callback. Focused Onboarding,
  bounded AppModel/root and presentation-root selections pass; live SDK delivery and
  visual rendering remain outside this checkpoint.

## Login Tout composition — 17 November 2026

- AppModel supplies AuthenticationFeature's response-delay policy plus Login Tout page
  and login-initiation analytics alongside its existing login platform dependencies.
- LoginToutViewModel still owns transient loading and presentation cancellation, but
  captures timing from AuthenticationFeature at admission and reports through the
  Feature. It no longer reads AppEnvironment.
- Apple/Facebook success, error, two-factor and confirmation routing, OAuth initiation,
  single appearance tracking and response-delay ordering are unchanged. Focused and
  bounded Authentication selections pass; live providers and visual behavior remain
  outside this checkpoint.

## Search request transport composition — 17 November 2026

- AppModel supplies AsyncSearchProjectsProvider with the authenticated service at the
  composition boundary. The provider no longer resolves AppEnvironment when a request
  begins.
- Search query mapping, cancellation checks, response conversion, pagination and stale
  result ownership are unchanged. Test-only request closures remain explicit seams for
  controlled overlap and environment-fixture scenarios.
- Focused Search provider, lookup, filter and view-model coverage passes 100 tests; the
  bounded SearchFeature and AppModel selection passes 29 tests. Live service behavior,
  visual rendering and the whole Library suite remain outside this checkpoint.

## Payment country-policy composition — 17 November 2026

- PaymentsFeature supplies launched-country data to Apple Pay network selection and
  payment-request currency resolution. These reusable policies no longer consult the
  process environment.
- Currency-symbol, project-country and device-identifier pledge rules now require their
  resolved country/device inputs. The unused ambient overloads were removed; payment
  country-code fallback and supported-network behavior are unchanged.
- Focused policy coverage passes 103 tests, a direct supplied-country proof passes 5,
  the bounded AppModel plus pledge/reward presentation selection passes 220 tests, and
  final PaymentsFeature/AppModel composition verification passes 26 tests. Live Apple
  Pay authorization and physical-device behavior remain outside this checkpoint.

## Rewards Apple Pay eligibility composition — 17 November 2026

- AppModel supplies Apple Pay eligibility to RewardsFeature alongside its reward-loading
  platform policy. Rewards Collection and Reward Add-On Selection ask that Feature for
  eligibility when constructing pledge navigation data.
- Both screen models retain presentation and navigation state but no longer accept an
  independent platform closure. Their controllers no longer read AppEnvironment for
  Apple Pay policy.
- Focused RewardsFeature and presentation-model coverage passes 53 tests. The bounded
  AppModel, PaymentsFeature and pledge-flow selection passes 178 tests. Live Apple Pay
  authorization, visual rendering and the whole Library suite remain outside this checkpoint.

## Rewards analytics composition — 17 November 2026

- AppModel supplies RewardsFeature with reward-selection analytics and the advertising
  identifier/platform-version context used by its third-party event. Rewards Collection
  and Reward Add-On Selection now send semantic commands to the owning Feature.
- RewardsFeature constructs the reward-selection event from its composed context and
  SessionFeature user. The screen models retain presentation and navigation state, but
  no longer resolve analytics, tracking-transparency or bundle globals.
- Focused RewardsFeature and presentation-model coverage passes 54 tests. The bounded
  AppModel, PaymentsFeature and pledge-flow selection passes 178 tests. Live analytics
  delivery, visual rendering and the whole Library suite remain outside this checkpoint.

## Rewards controller composition — 17 November 2026

- Rewards Collection requires its owning RewardsFeature at construction and passes that
  same instance into Reward Add-On Selection. Neither controller resolves AppModel.shared
  or AppEnvironment; the navigation factory also receives device idiom as an input.
- Project Page and Manage Pledge remain the current flow-composition callers. Controller
  presentation, navigation and feature behavior are otherwise unchanged.
- Focused RewardsFeature and screen-model coverage passes 54 tests. The bounded Project
  Page and Manage Pledge selection passes 114 tests. Both PresentationTests controller
  suites compile, but their snapshot harness requires an unavailable iPad mini (A17 Pro)
  simulator on iOS 18.6; visual snapshots remain unverified in this checkpoint.

## Project Page presentation-trait policy — 17 November 2026

- ProjectPageViewController now derives iPad presentation decisions from its own trait
  collection for login, pledge manager and checkout navigation. It no longer asks the
  process environment for device idiom.
- Full-screen, form-sheet and page-sheet behavior is unchanged for the active traits. A
  weak asynchronous login callback now binds the controller before reading those traits.
- Focused Project Page coverage passes 64 tests. The bounded AppModel, Rewards, Manage
  Pledge and checkout selection passes 214 tests. Visual snapshots and the whole Library
  suite remain outside this checkpoint.

## Project Page analytics composition — 17 November 2026

- AppModel supplies ProjectDetailsFeature with project-view and block-user analytics plus
  the advertising identifier/platform-version context for the third-party page-view event.
- ProjectPageViewModel now sends semantic project-view and block-user commands to its
  owning Feature. It no longer receives analytics, tracking or bundle closures and uses
  the Feature's SessionFeature identity when the third-party payload is constructed.
- Focused ProjectDetailsFeature and Project Page coverage passes 95 tests, including a
  direct composed-payload proof. The bounded AppModel, Rewards, Manage Pledge and checkout
  selection passes 214 tests. Live analytics delivery, visual snapshots and the whole
  Library suite remain outside this checkpoint.

## Project Page feature graph — 17 November 2026

- AppModel exposes one ProjectPageComposition containing the exact Project Details,
  Project Media, Rewards and Project Reporting feature instances owned by the application.
- ProjectPageViewController builds its view model and downstream Rewards and reporting
  flows from that one graph. Existing static factories still default to the AppModel
  composition boundary so legacy callers retain their behavior while accepting an
  explicit graph for tests and future caller migration.
- Focused AppModel and Project Page coverage passes 72 tests. The bounded AppModel,
  Rewards, Manage Pledge and checkout selection passes 214 tests. Visual snapshots and
  the whole Library suite remain outside this checkpoint.

## Pledge checkout feature graph — 17 November 2026

- AppModel exposes one PledgeCheckoutComposition containing the exact Pledge,
  Authentication and Payments feature instances plus the analytics provider owned by
  application composition.
- PledgeViewController and PostCampaignCheckoutViewController construct their models from
  that graph. Their existing no-argument factories remain compatibility boundaries that
  default to AppModel composition while allowing explicit injection.
- Focused AppModel and checkout-model coverage passes 110 tests. The bounded AppModel,
  Rewards, Manage Pledge and checkout selection passes 214 tests. Visual snapshots and
  the whole Library suite remain outside this checkpoint.

## Root Tabs feature graph — 17 November 2026

- AppModel exposes one RootTabComposition containing the exact Session, Profile, Activity
  and Settings feature instances plus analytics, badge timing and accessibility policy.
- RootTabBarViewController preserves storyboard construction and creates RootViewModel
  from that one composition instead of independently resolving seven application globals.
- Focused AppModel coverage passes 8 tests and focused Root Tabs presentation coverage
  passes 32 tests. Broader presentation, visual and whole Library suites remain outside
  this checkpoint.

## Manage Pledge feature graph — 17 November 2026

- AppModel exposes one ManagePledgeComposition containing the exact Pledge, Payments and
  Rewards features plus the nested PledgeCheckoutComposition owned by the application.
- ManagePledgeViewController constructs its model from that graph, sends reward changes
  through its Rewards feature and carries the same checkout graph into payment changes.
  Existing factories retain AppModel composition defaults for legacy callers.
- Focused AppModel and Manage Pledge coverage passes 58 tests. The bounded AppModel,
  Rewards, Manage Pledge and checkout selection passes 214 tests. Controller snapshots
  and the whole Library suite remain outside this checkpoint.

## Pledge payment-method composition — 17 November 2026

- PledgeCheckoutComposition now owns payment-method response timing and advertising
  context alongside PaymentsFeature.
- Both checkout controllers pass that same composition to
  PledgePaymentMethodsViewController, which no longer resolves AppModel or AppEnvironment.
- Focused AppModel, payment-method and checkout coverage passes 146 tests. The bounded
  Rewards, Manage Pledge, payment-method and checkout selection passes 250 tests.
  Controller snapshots and the whole Library suite remain outside this checkpoint.
