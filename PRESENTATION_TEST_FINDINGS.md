# Presentation test findings

## Retirement decision — 27 November 2026

The direct-view snapshot target, stored reference images and root-project
`SnapshotTesting` dependency were removed from this migration checkout. The
test target mixed ordinary behavioural coverage with synthetic image checks; the
behavioural tests and their JSON fixtures now belong to App Unit Tests, while the
image checks were retired.

This is not a claim that real product UI coverage has been replaced. The surviving
`UISnapshotTests` target uses the normally launched app and currently proves only
the product root. Meaningful journey screenshots require Kickstarter-owned,
deterministic signed-in fixture data and remain deliberately out of scope until
that foundation exists.

## Manage Pledge snapshot-test readiness — 27 November 2026

`PresentationTests` contains UIKit snapshot tests. They instantiate a view
controller, render it under selected device and language traits, then compare the
rendered image with a checked-in reference image. They are not UI-automation tests.

Two Manage Pledge cases previously had a deterministic readiness flaw:

- `ManagePledgeViewControllerTests/testView_ErroredBacking()`
- `ManagePledgeViewControllerTests/testView_ErroredBacking_noPaymentMethod()`

Each started asynchronous loading and immediately attempted to scroll a table
row. The test did not observe completion; its only indication was the comment
`// Network request completes`.

The old reference screenshots captured a transient, pre-settled rendering. In
particular, they showed the reward-received switch even though both fixtures
set the backing status to `.errored`. The production presentation rule hides
that switch unless the backing is `.collected`. The new fully loaded render is
therefore the correct error-state screen: it includes the profile, payment
error, and fix-payment action, but no reward-received switch.

### Correction applied

The tests now:

- await the existing Manage Pledge read tasks;
- lay out the controller after those reads complete, which lets its ordinary
  table-header sizing code run;
- assert that the header is installed and has a nonzero laid-out height; and
- assert the complete table structure: one section containing two rows (the
  selected reward and its add-on).

The tests no longer scroll the table. A TODO identifies a separate future test
for an intentional payment-action scroll state, if that behaviour needs its own
coverage.

This uses no elapsed-time synchronization and does not restore a production
response delay.

### Scope and caution

This finding explains the two Manage Pledge out-of-bounds failures and the two
stale snapshot mismatches observed on 27 November 2026. It does not establish
the cause of other PresentationTests failures; those require their own evidence
before attribution.

## Shipping Locations microphone — test-host finding — 27 November 2026

The Shipping Locations reference contains a system dictation microphone in the
native SwiftUI search field. The original pre-migration framework test passed
against that reference on the pinned iPad mini (A17 Pro), iOS 18.6 simulator.
The migrated app-hosted test renders the same direct `UIView` snapshot without
the microphone on that same simulator.

This rules out an operating-system version change as the explanation. The
screen's source still declares only `.searchable(...)`; it does not draw or
configure a microphone. The changed test-host/rendering context is therefore
the current evidence-backed cause of the mismatch. Removing the migration's
test-only blank-root launch branch did not restore the glyph, so that branch
was a separate invalid test-harness change rather than the proven direct cause.

Do not add a fake icon, microphone permission, or redundant dictation setting
to make this legacy direct-view image pass. The next valid evidence is a normal
simulator-driven app journey with an approved deterministic pledge fixture.
