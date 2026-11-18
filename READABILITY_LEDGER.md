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

## Current slice

- CreatorDrafts Feature, including the Update Draft screen and focused tests.
