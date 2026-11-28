# CFA migration working agreement

CFA workflow: established-product maintenance.

- Migrate to Cooperative Feature Architecture and Swift Concurrency one feature
  at a time. Preserve existing UIKit/SwiftUI screens, navigation, branding,
  accessibility, storage and target identifiers. No redesign is implied.
- Keep behaviour requirements in `MIGRATION_BEHAVIOUR_CONTRACT.md` and execution
  ownership/progress in `MIGRATION_LEDGER.md`.
- Keep opt-in migration case-study evidence outside this application checkout,
  in the sibling `Migration Evidence` workspace. Never copy credentials or raw
  push/device identifiers into that evidence.
- Commit completed, verified checkpoints. Do not automatically push or publish.
- Attribute new authored material to Matthew Thomas.
- Keep public demo configuration Debug-only. Never stage `Secrets.swift`.
- Do not disable snapshot reference-device checks globally to run logic tests.
  Only explicitly non-visual suites may opt out; record their actual runtime.
- Tests must exercise the normal application launch and root interface. Never
  add a test-only environment switch, launch branch, root-view-controller
  replacement, window replacement, or blank test host. Isolate data through
  the owning Feature/provider boundary; do not alter the application UI or
  lifecycle to manufacture a test state. `make verify-test-host-integrity`
  enforces this before every Xcode test run.
- `UISnapshotTests` is the no-space UI-testing target, module, product and scheme
  for real product screenshots. Run it only through
  `make test-ui-snapshots RESULT_BUNDLE=<new>.xcresult` on the pinned iPad mini
  (A17 Pro) / iOS 18.6 simulator, then inspect the saved result bundle before
  reporting results.




<!-- CFA-CODING-TASK-ORCHESTRATOR:START -->
## CFA task orchestration
- For code-changing CFA work with build, test, audit, or delivery acceptance criteria, use `coding-task-orchestrator`.
- Maintain the requested scope until applicable checks complete and their authoritative results are inspected. Do not require the developer to prompt “continue” after an interrupted, incomplete, or failing run.
- Recover routine non-destructive runner interruptions autonomously. A reproducible failure becomes the next diagnostic or repair action; ask only for a meaningful decision, new authority, or a blocker that remains after bounded safe recovery.
- Never change the product, normal application launch/root interface, test criteria, or test host merely to make a runner or test pass.
<!-- CFA-CODING-TASK-ORCHESTRATOR:END -->
