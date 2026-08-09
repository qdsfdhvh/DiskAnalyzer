# AI Cleanup Architecture

This document is the source of truth for the AI cleanup implementation. `task_plan.md` tracks phase status; `IMPLEMENTATION_BACKLOG.md` defines task-sized changes.

## 1. Product Contract

DiskAnalyzer becomes a cleanup advisor, not an autonomous deletion agent.

```text
scan → analyze locally → optionally improve plan with AI → validate → review → execute → verify
```

A useful recommendation answers five questions:

1. What is the item?
2. How much space can be reclaimed?
3. Why is it a candidate?
4. What could break?
5. How can the user recover?

The user remains the authority. A model response is untrusted input.

## 2. Delivery Defaults

These defaults remove product ambiguity during implementation:

- Initial audience: macOS developers.
- Minimum system: macOS 13, unchanged.
- First working release: local deterministic recommendations.
- First executable action: move one selected candidate to Trash.
- Remote AI: OpenAI-compatible BYOK adapter, added only after local planning and execution are complete.
- Cloud payload: compact candidate summaries; no file contents and no complete directory tree.
- High-risk user data is never selected by default.
- Duplicate detection, permanent deletion, automated app-data removal, and preference learning are V2.

Changing one of these defaults is a product decision, not an implementation detail.

## 3. Deep Modules

### 3.1 AnalysisEngine

**Seam:** `Analysis/AnalysisEngine.swift`

```swift
protocol Analyzing: Sendable {
    func analyze(
        root: FileNode,
        preferences: AnalysisPreferences
    ) async -> AnalysisReport
}
```

Callers know only that analysis runs after a completed scan and returns an immutable report. Traversal, candidate limits, enrichment, rule ordering, and scoring remain implementation details.

```swift
struct AnalysisPreferences: Sendable, Equatable {
    var targetBytes: Int64?
    var preserveRecentDays: Int
}

struct AnalysisReport: Sendable, Equatable {
    let generatedAt: Date
    let rootURL: URL
    let candidates: [CleanupCandidate]
    let warnings: [AnalysisWarning]
}
```

**Invariant:** `analyze` is called only when `ScanSessionController.isScanning == false` and `root != nil`.

**Performance:** candidate discovery may traverse the in-memory tree once. Filesystem enrichment is limited to at most 200 candidate URLs per analysis. The scanner hot loop is unchanged.

### 3.2 CleanupPlanner

**Seam:** `Planning/CleanupPlanner.swift`

```swift
protocol CleanupPlanning: Sendable {
    func makeDraft(request: PlanningRequest) async throws -> CleanupPlanDraft
}
```

There are two adapters:

- `LocalCleanupPlanner`: deterministic, always available.
- `RemoteCleanupPlanner`: optional AI enhancement.

Both adapters return a draft containing candidate IDs only. `CleanupPlanValidator` is the sole module allowed to turn a draft into an executable `CleanupPlan`.

### 3.3 CleanupPlanValidator

**Seam:** `Planning/CleanupPlanValidator.swift`

```swift
struct CleanupPlanValidator: Sendable {
    func validate(
        draft: CleanupPlanDraft,
        against report: AnalysisReport
    ) throws -> CleanupPlan
}
```

It rejects:

- unknown or duplicate candidate IDs;
- reclaimable sizes differing from local evidence;
- risk lower than local analysis;
- unsupported actions;
- default selection of high-risk candidates;
- candidates outside the analyzed root;
- malformed or oversized model text.

The validator copies path, size, risk, action, and evidence from the local report. AI may supply only ordering, grouping, and bounded explanation text.

### 3.4 CleanupExecutor

**Seam:** `Cleanup/CleanupExecutor.swift`

```swift
protocol CleanupExecuting: Sendable {
    func execute(
        items: [ApprovedCleanupItem],
        progress: @escaping @Sendable (CleanupProgress) -> Void
    ) async -> CleanupResult
}
```

The first adapter is `TrashCleanupExecutor`. It handles validation, Trash moves, partial failures, and cancellation behind one interface.

**Invariant:** only `ApprovedCleanupItem` can cross this seam. UI selection alone is not executable; approval creation must pass preflight validation.

## 4. Domain Model

Create these files under `Sources/DiskAnalyzer/Analysis/Models/` unless noted otherwise.

```swift
struct CandidateID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UUID
}

enum CleanupCategory: String, Codable, Sendable {
    case developerCache
    case applicationCache
    case oldInstaller
    case oldDownload
    case simulatorData
    case largeFile
}

enum RiskLevel: Int, Codable, Comparable, Sendable {
    case low = 0
    case medium = 1
    case high = 2
}

enum CleanupAction: String, Codable, Sendable {
    case moveToTrash
}

enum EvidenceKind: String, Codable, Sendable {
    case knownRebuildablePath
    case ageInDays
    case allocatedSize
    case fileExtension
    case userDataLocation
}

struct CandidateEvidence: Codable, Hashable, Sendable {
    let kind: EvidenceKind
    let summary: String
}

struct FileFingerprint: Codable, Hashable, Sendable {
    let deviceID: UInt64
    let inode: UInt64
    let allocatedSize: Int64
    let modificationTime: Date?
}

struct CleanupCandidate: Identifiable, Codable, Sendable {
    let id: CandidateID
    let url: URL
    let displayPath: String
    let category: CleanupCategory
    let allocatedSize: Int64
    let risk: RiskLevel
    let defaultSelected: Bool
    let action: CleanupAction
    let fingerprint: FileFingerprint
    let evidence: [CandidateEvidence]
}
```

Conform `RiskLevel` to `Comparable` using raw values. Avoid inheritance and mutable reference models in the analysis/planning layers.

## 5. Candidate Rules for V1

Rules are evaluated in this order. A URL appears at most once; the earliest specific rule wins over `largeFile`.

| Rule | Match | Risk | Default | Explanation source |
|---|---|---:|---:|---|
| DerivedData | `~/Library/Developer/Xcode/DerivedData` or a direct child | low | yes | Xcode rebuilds generated artifacts |
| App cache | direct child of `~/Library/Caches`, size ≥ 250 MB | medium | no | Cache is usually rebuildable but may contain offline state |
| Old installer | extension `dmg`, `pkg`, `xip`, `zip`; in Downloads; age ≥ 30 days; size ≥ 100 MB | low | yes | Installer/archive can normally be downloaded again |
| Old download | direct child of Downloads; age ≥ 90 days; size ≥ 500 MB | medium | no | Old and large, but may be user-owned |
| Simulator data | direct child below `~/Library/Developer/CoreSimulator/Devices`; size ≥ 1 GB | medium | no | May contain app test data |
| Large file | regular file size ≥ 1 GB not matched above | high | no | Size only; no evidence it is disposable |

V1 does not analyze `Photos Library.photoslibrary`, source repositories, Documents, Desktop, app Containers, Mail, or Messages as safe candidates. Such items may appear only as high-risk `largeFile` evidence rows.

## 6. Candidate Discovery and Enrichment

Do not copy the entire `FileNode` tree into another full tree. `AnalysisEngine` performs one traversal and emits compact `CandidateSeed` values only.

Candidate limits:

- maximum 200 enriched candidates;
- keep specific-rule candidates before generic large files;
- within a rule, keep larger items first;
- emit `.candidateLimitReached(omittedCount:)` warning if truncated.

Use `lstat` for fingerprints and Foundation resource values only after seeds are limited. Failure to enrich one candidate produces a warning and omits that candidate; it does not fail the analysis.

Do not modify `BulkScan.Entry`, `DiskScanner.scanDir`, or the scanner callbacks for analysis metadata.

## 7. Planning Models

Files live under `Sources/DiskAnalyzer/Planning/Models/`.

```swift
struct PlanningRequest: Sendable {
    let report: AnalysisReport
    let targetBytes: Int64?
}

struct CleanupPlanDraft: Codable, Sendable {
    let groups: [CleanupPlanGroupDraft]
}

struct CleanupPlanGroupDraft: Codable, Sendable {
    let title: String
    let candidateIDs: [CandidateID]
    let explanation: String
}

struct CleanupPlan: Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let reportGeneratedAt: Date
    let groups: [CleanupPlanGroup]
}
```

`LocalCleanupPlanner` groups in this order:

1. Safe to reclaim (`low`)
2. Review recommended (`medium`)
3. Large items requiring manual judgment (`high`)

Within each group sort by allocated size descending. Stop default-selecting low-risk candidates once the target byte count is reached; if no target exists, preserve each candidate's local `defaultSelected` value.

## 8. Remote AI Contract

Remote AI receives JSON, not prose containing raw file listings.

```json
{
  "targetBytes": 20000000000,
  "candidates": [
    {
      "id": "UUID",
      "pathLabel": "~/Library/Developer/Xcode/DerivedData/…",
      "category": "developerCache",
      "sizeBytes": 8400000000,
      "risk": "low",
      "defaultSelected": true,
      "evidence": ["Known rebuildable Xcode output"]
    }
  ]
}
```

Privacy transform:

- replace the home prefix with `~`;
- retain known system path segments needed for classification;
- replace unknown user-created path components with deterministic labels such as `<private-1>` within one request;
- omit inode, device ID, exact timestamps, file contents, sibling listings, username, and volume name;
- cap candidates at 100 for a remote request.

The response schema contains only group title, explanation, and candidate IDs. Explanations are capped at 300 characters per group. The adapter never receives an executor.

Credentials use Keychain. Never store API keys in `UserDefaults`, source, plan history, logs, or request fixtures.

## 9. Execution Contract

`PreflightValidator` runs immediately before each move:

1. URL remains under the analyzed root.
2. `lstat` succeeds without following symlinks.
3. device ID and inode match.
4. allocated size and modification time match the recorded fingerprint.
5. no selected child is executed after its selected parent; parent selection subsumes children.
6. high-risk items require an explicit per-item approval flag.

On mismatch, skip the item with `.changedSinceAnalysis`. Continue remaining items. Never convert a partial result into success.

```swift
enum CleanupItemOutcome: Sendable {
    case movedToTrash(originalURL: URL, trashURL: URL?)
    case skipped(reason: CleanupSkipReason)
    case failed(message: String)
}
```

Cancellation prevents the next item from starting; an in-progress `trashItem` is allowed to finish.

## 10. UI State Machine

`AnalysisFlowViewModel` owns one state enum:

```swift
enum AnalysisFlowState {
    case idle
    case scanning
    case analyzing
    case reviewing(CleanupPlan)
    case preflighting
    case cleaning(CleanupProgress)
    case completed(CleanupResult)
    case failed(UserFacingError)
}
```

Invalid transitions are ignored and logged in debug builds. Views render state and send intents; views do not perform analysis, planning, networking, or filesystem mutation.

V1 screens:

- `AnalysisStartView`: choose folder, target space, start.
- `AnalysisProgressView`: reuse scan progress, then show analysis progress.
- `CleanupPlanView`: summary and three risk groups.
- `CleanupCandidateRow`: checkbox, size, reason, risk, evidence disclosure, Reveal in Finder.
- `CleanupConfirmationView`: exact selected items and total.
- `CleanupResultView`: moved, skipped, failed, actual planned bytes.
- `FileBrowserView`: current tree UI retained as a secondary evidence tab.

Follow `DESIGN.md`; AI is represented through useful copy, not gradients, chat bubbles, mascots, or decorative sparkle icons.

## 11. Persistence

V1 persists only settings and optional credentials:

- target byte preference: `UserDefaults`;
- AI enabled/provider setting: `UserDefaults`;
- API key: Keychain.

Plan history persistence is deferred until the execution model is stable. Keep in-memory history during the first release.

## 12. Testing Strategy

Add `DiskAnalyzerTests` to `Package.swift`. Tests import the executable module with `@testable import DiskAnalyzer`.

Required fixture helper:

```swift
struct TemporaryDirectoryFixture {
    let root: URL
    func createFile(_ relativePath: String, size: Int, modifiedAt: Date?) throws -> URL
    func createDirectory(_ relativePath: String) throws -> URL
}
```

Test through module interfaces rather than private helpers.

Minimum suites:

- `AnalysisEngineTests`
- `CandidateRuleTests`
- `LocalCleanupPlannerTests`
- `CleanupPlanValidatorTests`
- `PrivacyRedactorTests`
- `RemoteCleanupPlannerParsingTests`
- `PreflightValidatorTests`
- `TrashCleanupExecutorTests`
- `AnalysisFlowViewModelTests`

Trash executor integration tests must operate only inside a temporary directory. They must never target real home paths.

## 13. Global Guardrails

- Preserve Swift Package structure; do not add an Xcode project.
- Keep the app unsandboxed.
- Preserve symlink skipping and cross-volume behavior.
- Keep package directories as leaves in the scanner.
- No third-party dependency is needed for local V1.
- No broad UI redesign outside the analysis flow.
- Every task must leave `swift build` passing.
- Logic tasks must add tests in the same task; UI-only tasks must at least compile and include a manual verification checklist.
