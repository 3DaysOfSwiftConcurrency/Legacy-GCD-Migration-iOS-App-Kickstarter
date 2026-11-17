# CFA audit and remaining validation

Author: Matthew Thomas. Updated 17 November 2026.

## Current audit — incomplete

The 3 November handover below records a historical milestone. Subsequent source
review found further CFA ownership work; it does not establish current full
compliance. The active audit covers only `Kickstarter-iOS/1 - View` and
`Kickstarter-iOS/2 - AppModel`, with supporting tests and project registration.
Swift packages are excluded.

- AppDelegate has no ViewModel. Lifecycle is not a Feature. AppDelegate receives
  incoming links and calls the presentation-layer DeepLinkRouter, which requests
  domain resolution through AppModel and existing Features. The router retains
  navigation delivery and UIKit construction. Other application events enter
  AppModel's Feature coordination methods directly.
- Account refresh now uses AppModel methods with Settings, Session and Discovery.
  The account-refresh coordinator and application-shortcut service are removed.
  Discovery owns recommendation requests; ShortcutItem defines native presentation.
- Device-token association with the current account belongs to SessionFeature.
  AppDelegate retains raw-token forwarding to Braze; AppModel forwards account
  registration to Session. The standalone device-registration service is removed.
- ProjectMediaFeature owns video-feed availability and privately retains the
  connectivity service. Search and Discovery receive that Feature explicitly;
  Environment no longer exposes connectivity or starts the application graph.
- AppModel's stored-property boundary now consists of its singleton, concrete
  Features and the private launch guard. Configuration services are retained below
  SettingsFeature, which owns effective configuration reads, overrides, refresh
  and activation commands. Flag tools and Settings' App Store action use that
  Feature. This satisfies the inspected property boundary, not the full CFA audit.
- Current Config and DebugData remain the storage authority through injected
  accessors. No second Config cache was introduced. The tool mutation path preserves
  unknown keys, false overrides, DebugData precedence and rapid edits against the
  latest configuration. The existing one-second screen reload remains presentation
  behavior. The client-specific Statsig helper now queries its own client.
- SettingsFeature now exposes the effective App Store rating and newsletter
  country policies. Recommendations receives its prompt store, response delay and
  third-party-event transport through an explicit platform. The newsletter cell
  and Thanks screen obtain policy and save timing from Settings. Neither
  RecommendationsFeature nor SettingsNewslettersCellViewModel reads Environment.
- PledgedProjectsFeature now owns its V2/V4 runtime policy through SettingsFeature.
  Tier selection, reward-toggle parsing and PPO presentation use that owner; PPO
  Views no longer call global flag helpers. The removed V2/V4 convenience functions
  cannot be restored without failing the CFA gate.
- Next: migrate the remaining runtime helpers independently: Root Tabs floating-tab
  policy and Pledge Manager bypass policy. Project rich-text and video-feed Statsig
  inputs are already composed into their Features but still use global helper
  closures at composition. Bootstrap keychain reads must remain independent of
  AppModel; do not route them through SettingsFeature.
- Bootstrap/keychain flag reads intentionally remain independent of AppModel
  construction. Environment configuration persistence, whole-config DebugData
  precedence, cookie installation and SDK integration remain contracts to preserve
  through further migration. The signed persistence suite is
  `Library-Keychain-iOSTests/AppEnvironmentTests` in the Library-iOS scheme; its
  latest executed result belongs in the dated ledger, not a broad completion claim.
- Discovery recommendation reads check session generation. Feed pagination and
  activity sampling still use user-ID checks; review same-user session replacement
  and related task lifetimes separately.
- Continue reviewing global environment access, authoritative state, feature
  boundaries and presentation-owned work across the in-scope source. Focused green
  tests establish only their tested scenarios, not an exhaustive compliance audit.

Use the dated entries at the end of `MIGRATION_LEDGER.md` for current verified
checkpoints. The full Library suite previously hung; run focused main-module
selections followed by bounded affected regressions. Device, visual, live-service
and release validation remain subject to the limits recorded below.

## Historical handover — 3 November 2026

**CFA application implementation and physical structure are complete for handover.**
The app is ready for the separate concurrency-analysis and new-test phase requested
by Matthew Thomas. No new race-condition tests were started in the final pass.
See [MIGRATION_COMPLETION_REPORT.md](MIGRATION_COMPLETION_REPORT.md) for exact scope,
timing, model provenance, evidence and limitations.

## Final execution plan — completed

1. Recompile all core source with complete checking and classify diagnostics: complete.
   App-attributed concurrency warning lines reduced from 210 to zero. Four unattributed
   SDK attribute-key-path warnings remain; dependencies were not fully rebuilt.
2. Audit physical source/target ownership and remove superseded paths: complete.
   765 core Swift files compile exactly once directly in the app target; no missing
   membership, old app-library imports/manifests or stale nib module names remain.
   Five local packages retain services/generated APIs/reusable non-core components.
3. Run existing regression and broader applicable suites: complete. 2,929 passed,
   zero failures/skips; app builds and representative public-demo startup passed.
4. Record architecture, retained boundaries, rework, timestamps and limitations:
   complete in the report, ledger and external kickstarter-cfa-completion evidence.

AppModel/Features own Search/Explore, project/rewards/checkout/backing, media/comments,
Activity/Profile, session/authentication/settings, messaging, friends/following,
recommendations/reporting/creator drafts, lifecycle and platform integration.
UIKit and presentation publishers remain deliberately; screens were not redesigned.
Core application code is no longer housed in Library/Kickstarter-Framework packages.

## Next phase — not started

- Evaluate concurrency invariants and add new race-condition tests against isolated
  AppModel composition and Feature/provider seams. Existing passing regression does
  not establish freedom from races. Do not silently expand into this phase.
- Assess retained generic service compatibility APIs, dependencies/test fixtures and
  the four SDK diagnostics before any claim of warning-free Swift 6 language mode.
  Migrated Feature providers use checked value responses; old generic service APIs
  are retained for compatibility and are not certified as migrated application paths.

## Explicitly deferred validation

- Physical device: deferred by Matthew Thomas; no post-consolidation device result claimed.
- Full snapshots/visual/accessibility validation: reference iPad mini iOS 18.6 runtime
  unavailable; reference-device guard retained. Representative simulator smoke is not
  full visual parity.
- Live Stripe/Apple Pay/3DS, authenticated account/backing mutations, APNs and other
  live-service journeys: unverified. No implicit permission for real transactions.
- Release-configuration and representative performance validation remain separate
  release-readiness checks.

These limits do not conceal remaining file moves or an app library awaiting removal.
The implementation handover timestamp is recorded; full release-validation completion
remains unset until the explicitly deferred work has actually been performed.
