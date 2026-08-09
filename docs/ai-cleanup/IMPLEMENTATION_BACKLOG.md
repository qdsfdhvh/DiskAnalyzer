# AI Cleanup Implementation Backlog

Give a coding agent exactly one task ID at a time. Each task assumes `docs/ai-cleanup/ARCHITECTURE.md` is authoritative. Tasks are ordered to keep builds green and minimize simultaneous design work.

## Dependency Graph

```text
T00
 └─ T01
     ├─ T02 ─ T03 ─ T04 ─ T05
     │                    └─ T06 ─ T07
     └─ T08 ─ T09 ─ T10
                    └─ T11
T05 + T07 + T10 ─ T12 ─ T13
T09 + T13 ─ T14 ─ T15
T16 follows all shipped tasks
```

Do not parallelize tasks that edit the same production file. T02/T08 may run in parallel only after T01. T12 waits for both planning and execution contracts.

---

## T00 — Add the test target and fixture helper

**Goal:** establish a green test harness before feature code.

**Files:**
- modify `Package.swift`
- add `Tests/DiskAnalyzerTests/Support/TemporaryDirectoryFixture.swift`
- add `Tests/DiskAnalyzerTests/TemporaryDirectoryFixtureTests.swift`

**Implementation:**
- Add `.testTarget(name: "DiskAnalyzerTests", dependencies: ["DiskAnalyzer"])`.
- Fixture creates a unique temporary root and removes it in `deinit`/explicit cleanup.
- `createFile` creates parents, writes the requested byte count, and optionally sets modification date.
- Test file creation, nested parent creation, size, date, and cleanup.

**Do not:** edit production source or add dependencies.

**Acceptance:**
```bash
swift test
swift build
```
Both pass. Fixture tests never touch paths outside the generated temporary root.

---

## T01 — Add immutable analysis models

**Depends on:** T00

**Goal:** compile the domain contract without behavior.

**Files:**
- add `Sources/DiskAnalyzer/Analysis/Models/AnalysisModels.swift`
- add `Sources/DiskAnalyzer/Analysis/Models/CleanupCandidate.swift`
- add `Tests/DiskAnalyzerTests/AnalysisModelsTests.swift`

**Implementation:** define the models and enums from Architecture sections 3–4, including `AnalysisWarning` with `candidateLimitReached` and `metadataUnavailable` cases. Add `Comparable` for `RiskLevel`. Use value types and `Sendable`.

**Tests:** risk ordering, CandidateID Codable round trip, CleanupCandidate Codable round trip.

**Do not:** add analyzer protocols, filesystem calls, UI, or planner types.

**Acceptance:** `swift test` passes with no unchecked Sendable warning introduced by these types.

---

## T02 — Build candidate seed discovery

**Depends on:** T01

**Goal:** traverse a completed `FileNode` once and return bounded candidate seeds without filesystem metadata calls.

**Files:**
- add `Sources/DiskAnalyzer/Analysis/CandidateSeedDiscovery.swift`
- add `Tests/DiskAnalyzerTests/CandidateSeedDiscoveryTests.swift`

**Interface:**
```swift
struct CandidateSeedDiscovery: Sendable {
    func discover(root: FileNode, homeURL: URL, limit: Int = 200) -> SeedDiscoveryResult
}
```

**Implementation:** implement V1 path/size/extension matching from Architecture section 5 using node URL, size, type, and tree position. Specific rules outrank generic large-file. Sort specific candidates before generic, then size descending. Deduplicate standardized URLs. Return omitted count.

**Tests:** one fixture tree per rule, rule precedence, threshold edges, URL dedupe, 200-item bound, specific-before-generic ordering.

**Do not:** call `FileManager.resourceValues`, `stat`, `lstat`, hash files, or mutate FileNode.

**Acceptance:** tests demonstrate one traversal output and exact rule precedence.

---

## T03 — Enrich candidate seeds and create fingerprints

**Depends on:** T02

**Goal:** turn bounded seeds into immutable candidates using actual filesystem metadata.

**Files:**
- add `Sources/DiskAnalyzer/Analysis/CandidateEnricher.swift`
- add `Sources/DiskAnalyzer/Analysis/FileFingerprinting.swift`
- add `Tests/DiskAnalyzerTests/CandidateEnricherTests.swift`

**Interfaces:**
```swift
protocol FileFingerprinting: Sendable {
    func fingerprint(url: URL) throws -> FileFingerprint
}

struct CandidateEnricher: Sendable {
    func enrich(seeds: [CandidateSeed], preserveRecentDays: Int) -> EnrichmentResult
}
```

Provide real `LstatFileFingerprinter`. `CandidateEnricher` may obtain modification date and allocated size only for seeds. It assigns risk/default/evidence exactly as Architecture section 5. If metadata fails, omit candidate and emit warning.

**Tests:** real temp files for fingerprint behavior; fake fingerprinter for mapping; metadata failure warning; symlink rejection; recent installer is not classified as old.

**Do not:** alter `BulkScan`, `DiskScanner`, or all-file scanning.

**Acceptance:** test proves metadata calls are bounded by seed count and failures are isolated.

---

## T04 — Implement AnalysisEngine

**Depends on:** T03

**Goal:** expose one deep analysis interface combining discovery and enrichment.

**Files:**
- add `Sources/DiskAnalyzer/Analysis/AnalysisEngine.swift`
- add `Tests/DiskAnalyzerTests/AnalysisEngineTests.swift`

**Implementation:** define `Analyzing`; concrete `AnalysisEngine` accepts home URL, clock closure, discovery, and enricher. Return candidates, root URL, timestamp, and combined warnings. Reject or return explicit warning for a nil/non-final scan at caller level; engine itself accepts a root.

**Tests:** deterministic generatedAt with fake clock, warning composition, candidate ordering, empty report, 200 maximum.

**Do not:** reference SwiftUI, URLSession, AppViewModel, or cleanup execution.

**Acceptance:** callers can analyze through `Analyzing` without knowing internal rule types.

---

## T05 — Implement local cleanup planning

**Depends on:** T04

**Goal:** produce a useful offline plan draft.

**Files:**
- add `Sources/DiskAnalyzer/Planning/Models/PlanningModels.swift`
- add `Sources/DiskAnalyzer/Planning/CleanupPlanner.swift`
- add `Sources/DiskAnalyzer/Planning/LocalCleanupPlanner.swift`
- add `Tests/DiskAnalyzerTests/LocalCleanupPlannerTests.swift`

**Implementation:** define `CleanupPlanning`; group low/medium/high in fixed order; sort by size; reference candidate IDs only. Implement target-byte selection behavior without changing risk. Empty reports return empty groups.

**Tests:** grouping, sorting, target reached, no target behavior, empty input, high risk never default selected.

**Do not:** add remote/network code or validator behavior.

**Acceptance:** deterministic output for identical request; no filesystem access.

---

## T06 — Validate plan drafts

**Depends on:** T05

**Goal:** make every plan safe and locally grounded.

**Files:**
- add `Sources/DiskAnalyzer/Planning/CleanupPlanValidator.swift`
- add `Tests/DiskAnalyzerTests/CleanupPlanValidatorTests.swift`

**Implementation:** validator requirements from Architecture section 3.3. Define typed validation errors. Final plan item copies candidate-controlled fields from `AnalysisReport`; only title/explanation/order come from draft. Trim and cap text. Reject duplicate IDs across all groups.

**Tests:** valid draft, unknown ID, duplicate ID, oversized text, high-risk default, outside-root candidate, candidate field cannot be overridden.

**Do not:** silently drop invalid model output. Return a typed error so caller can fallback.

**Acceptance:** no code path can construct an executable plan item solely from draft text.

---

## T07 — Add planning coordinator with fallback

**Depends on:** T06

**Goal:** select remote/local planner while guaranteeing a validated local result.

**Files:**
- add `Sources/DiskAnalyzer/Planning/PlanningCoordinator.swift`
- add `Tests/DiskAnalyzerTests/PlanningCoordinatorTests.swift`

**Interface:**
```swift
struct PlanningCoordinator: Sendable {
    func makePlan(request: PlanningRequest, preferRemote: Bool) async -> PlanningOutcome
}
```

If remote is unavailable, throws, times out, or validation fails, validate and return local draft with a warning. Inject local and optional remote adapters plus validator. Do not create concrete adapters inside the method.

**Tests:** local success, remote success, remote throw fallback, invalid remote fallback, local failure surfaced.

**Acceptance:** remote failure never prevents a local plan when local input is valid.

---

## T08 — Implement preflight validation

**Depends on:** T01

**Goal:** verify a candidate still refers to the same filesystem item immediately before cleanup.

**Files:**
- add `Sources/DiskAnalyzer/Cleanup/PreflightValidator.swift`
- add `Sources/DiskAnalyzer/Cleanup/CleanupModels.swift`
- add `Tests/DiskAnalyzerTests/PreflightValidatorTests.swift`

**Implementation:** use `FileFingerprinting` from T03 if available; if T08 is developed in parallel, define only the consumer and reconcile after merge. Validate root containment, no symlink following, fingerprint equality, action support, explicit high-risk approval, and parent/child selection normalization.

**Tests:** unchanged success; replaced inode; changed size/date; outside root; symlink; high risk without explicit approval; selected parent removes selected child.

**Do not:** move or delete files.

**Acceptance:** every rejection has a typed reason suitable for UI.

---

## T09 — Implement TrashCleanupExecutor

**Depends on:** T08

**Goal:** execute approved moves safely with partial-result reporting.

**Files:**
- add `Sources/DiskAnalyzer/Cleanup/CleanupExecutor.swift`
- add `Sources/DiskAnalyzer/Cleanup/TrashCleanupExecutor.swift`
- add `Tests/DiskAnalyzerTests/TrashCleanupExecutorTests.swift`

**Implementation:** define `CleanupExecuting`. Run preflight immediately before each item. Move through an injected trash adapter so unit tests do not use the real Trash. Return one outcome per requested item. Stop starting new items after cancellation. Preserve completed outcomes.

**Tests:** all success, one preflight skip then continue, one move failure then continue, cancellation, progress monotonicity, output order.

**Do not:** permanently delete, invoke shell, request admin privileges, or swallow errors.

**Acceptance:** executor tests use a fake trash adapter; optional integration test may move only a temp fixture file.

**Strong-model review gate:** review T08–T09 for path containment, symlink behavior, TOCTOU limitations, and partial failure semantics before UI wiring.

---

## T10 — Add analysis flow view model

**Depends on:** T07 and T09

**Goal:** centralize the product state machine and orchestration.

**Files:**
- add `Sources/DiskAnalyzer/Analysis/AnalysisFlowViewModel.swift`
- add `Tests/DiskAnalyzerTests/AnalysisFlowViewModelTests.swift`

**Implementation:** `@MainActor` view model owns `AnalysisFlowState`, selected candidate IDs, target bytes, and user intents. Inject `Analyzing`, `PlanningCoordinator`, and `CleanupExecuting`. It may use an existing completed `ScanSessionController`, but views remain side-effect free.

**Tests:** valid state sequence; scan failure; analysis failure; plan selection; high-risk explicit approval; cleanup partial result; cancel; stale async result cannot overwrite a newer run.

**Do not:** place URLSession, FileManager trash calls, or candidate rules in the view model.

**Acceptance:** tests cover every state case and async generation token/cancellation behavior.

---

## T11 — Add recommendation UI without changing navigation

**Depends on:** T10

**Goal:** render a plan inside the existing scan detail while preserving the file browser.

**Files:**
- add `Sources/DiskAnalyzer/Views/Analysis/CleanupPlanView.swift`
- add `Sources/DiskAnalyzer/Views/Analysis/CleanupCandidateRow.swift`
- add `Sources/DiskAnalyzer/Views/Analysis/AnalysisProgressView.swift`
- minimally modify `Sources/DiskAnalyzer/Views/ScanDetailView.swift`

**Implementation:** add a local segmented choice `Recommendations | Files` after scan completion. Recommendations show totals and three groups. Rows show checkbox, size, reason/risk, evidence disclosure, and Reveal in Finder. High-risk rows are unselected and require explicit interaction.

**Do not:** redesign nav, apps page, design tokens, scanner, or execute cleanup in row callbacks.

**Acceptance:**
```bash
swift build
swift test
```
Manual checklist: empty plan, long path, all risk groups, disclosure, selection total, Files view unchanged.

---

## T12 — Add confirmation and result UI

**Depends on:** T11

**Goal:** connect selected plan items to safe execution.

**Files:**
- add `Sources/DiskAnalyzer/Views/Analysis/CleanupConfirmationView.swift`
- add `Sources/DiskAnalyzer/Views/Analysis/CleanupResultView.swift`
- modify `Sources/DiskAnalyzer/Views/Analysis/CleanupPlanView.swift`
- modify `Sources/DiskAnalyzer/Analysis/AnalysisFlowViewModel.swift`

**Implementation:** confirmation lists exact items and planned total; cleaning shows progress; result separates moved/skipped/failed. Use “Moved to Trash,” not “Deleted.” Disable repeated submission while executing.

**Tests:** extend view-model tests for duplicate submit suppression and result reset. UI compile plus manual checklist.

**Acceptance:** no direct `FileManager` mutation exists in any View file.

---

## T13 — Integrate the new start flow and navigation

**Depends on:** T12

**Goal:** make recommendations the primary experience without removing raw scan capability.

**Files:**
- modify `Sources/DiskAnalyzer/ContentView.swift`
- modify `Sources/DiskAnalyzer/AppViewModel.swift`
- add `Sources/DiskAnalyzer/Views/Analysis/AnalysisStartView.swift`
- optionally rename enum cases only where required

**Implementation:** primary tab label becomes `Analyze`; start view asks folder and optional target amount. Existing session starts scanning, then analysis automatically. Keep `Apps` intact. Keep Files as secondary evidence view.

**Do not:** delete quick locations, multi-session support, AppsView, or context menu behavior in this task.

**Acceptance:** manual path completes scan → local recommendations → review → confirmation → Trash result; `swift test` and `swift build` pass.

**Strong-model review gate:** review T10–T13 for state ownership, accidental side effects in views, and preservation of scanner behavior.

---

## T14 — Implement privacy redaction

**Depends on:** T06

**Goal:** produce a bounded AI payload with no raw private path components.

**Files:**
- add `Sources/DiskAnalyzer/Planning/AI/PrivacyRedactor.swift`
- add `Sources/DiskAnalyzer/Planning/AI/RemotePlanningDTO.swift`
- add `Tests/DiskAnalyzerTests/PrivacyRedactorTests.swift`

**Implementation:** exact transform from Architecture section 8. Deterministic labels exist only within one request. Keep known classification segments. Cap to 100 candidates. DTO excludes fingerprint and URL.

**Tests:** username removal, arbitrary project-name removal, known DerivedData classification retained, stable label within request, different private segments differ, cap 100, malicious filename remains inert JSON data.

**Acceptance:** snapshot-style encoded JSON test contains no fixture username or original private names.

---

## T15 — Implement OpenAI-compatible BYOK planner

**Depends on:** T07 and T14

**Goal:** optionally enhance grouping/explanations through a remote model.

**Files:**
- add `Sources/DiskAnalyzer/Planning/AI/OpenAICompatibleClient.swift`
- add `Sources/DiskAnalyzer/Planning/AI/RemoteCleanupPlanner.swift`
- add `Sources/DiskAnalyzer/Planning/AI/APIKeyStore.swift`
- add `Tests/DiskAnalyzerTests/RemoteCleanupPlannerTests.swift`
- add `Tests/DiskAnalyzerTests/APIKeyStoreTests.swift`

**Implementation:** inject `URLSession`-like transport and Keychain adapter. Request strict JSON output matching draft schema. Add a finite timeout. Parse IDs only. Never log request body, response body, or key. Coordinator handles fallback.

**Tests:** encoded request, valid response, unknown ID rejected by validator, malformed JSON, HTTP error, timeout, empty key, fake Keychain round trip. No real network calls.

**Do not:** hardcode a paid endpoint/key, add streaming/chat UI, or give the model filesystem tools.

**Acceptance:** local app behavior remains complete with AI disabled; all provider tests use fakes.

**Strong-model review gate:** security/privacy review before release.

---

## T16 — Documentation, polish, and release verification

**Depends on:** shipped feature tasks

**Goal:** align public docs and verify the complete product contract.

**Files:**
- update `README.md`
- update `DESIGN.md` only for new reusable UI patterns
- update `CLAUDE.md` layout and architectural decisions
- add `docs/ai-cleanup/PRIVACY.md`

**Implementation:** document local vs AI behavior, uploaded fields, BYOK storage, Trash semantics, limitations, and recovery. Update old `build-app.sh` README instructions to Makefile while touching README.

**Acceptance:**
```bash
swift test
swift build -c release
make app
```
Manual fixture run covers low/medium/high recommendations, AI off, AI malformed response fallback, changed item skip, partial Trash failure, cancel, and raw Files browser.

---

## Deferred Tasks (V2)

These are intentionally outside V1 and must not leak into earlier tasks:

- duplicate detection and hashing;
- persisted plan history;
- user preference learning;
- app usage recency and complete uninstall recipes;
- permanent deletion / secure erase;
- privileged system cleanup;
- model-downloaded local inference;
- cloud account, billing, telemetry, or managed provider backend.
