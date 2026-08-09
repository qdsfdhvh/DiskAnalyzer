# DiskAnalyzer — Agent Notes

SwiftUI macOS utility for visualizing disk usage. Built as a Swift Package (no `.xcodeproj`).

## Layout

```
DiskAnalyzer/
├── Package.swift                       # macOS 13+, executable target + test target
├── Makefile                            # make app / run / install / clean
├── Sources/DiskAnalyzer/
│   ├── DiskAnalyzerApp.swift           # @main — WindowGroup only
│   ├── ContentView.swift               # NavigationSplitView: sidebar + detail
│   ├── AppViewModel.swift              # Manages multiple scan sessions
│   ├── Models/
│   │   ├── FileNode.swift              # Tree node (class; identity-based)
│   │   ├── DiskScanner.swift           # Concurrent scan + Counter actor + ScanLimiter
│   │   ├── BulkScan.swift              # getattrlistbulk(2) wrapper (no Foundation)
│   │   └── ScanSessionController.swift # One scan session: state + lifecycle
│   ├── Analysis/
│   │   ├── Models/                     # AnalysisPreferences/Report/Warning, CleanupCandidate…
│   │   ├── CandidateSeedDiscovery.swift# Single-pass seed discovery (no FS calls)
│   │   ├── CandidateEnricher.swift     # Bounded lstat enrichment + risk/evidence
│   │   ├── FileFingerprinting.swift    # lstat fingerprint seam (deviceID/inode/size/mtime)
│   │   ├── AnalysisEngine.swift        # Analyzing seam: discovery + enrichment
│   │   └── AnalysisFlowViewModel.swift # Flow state machine (review/clean lifecycle)
│   ├── Planning/
│   │   ├── Models/PlanningModels.swift # Draft/plan models (candidate IDs only in drafts)
│   │   ├── CleanupPlanner.swift        # CleanupPlanning seam
│   │   ├── LocalCleanupPlanner.swift   # Deterministic offline planning
│   │   ├── CleanupPlanValidator.swift  # SOLE draft→plan authority; copies facts from report
│   │   ├── PlanningCoordinator.swift   # Remote/local selection + fallback
│   │   └── AI/
│   │       ├── PrivacyRedactor.swift   # Path redaction → <private-N> labels
│   │       ├── RemotePlanningDTO.swift # Bounded upload payload (no URL/fingerprint)
│   │       ├── OpenAICompatibleClient.swift # BYOK chat-completions client
│   │       ├── RemoteCleanupPlanner.swift   # AI CleanupPlanning adapter
│   │       └── APIKeyStore.swift       # Keychain storage seam
│   ├── Cleanup/
│   │   ├── CleanupModels.swift         # ApprovedCleanupItem, PreflightRejection
│   │   ├── PreflightValidator.swift    # Root containment + fingerprint re-check
│   │   ├── CleanupExecutor.swift       # CleanupExecuting seam + outcomes
│   │   └── TrashCleanupExecutor.swift  # Trash mover + preflight + cancel
│   └── Views/
│       ├── DesignTokens.swift          # DT color/typography/metrics
│       ├── SizeFormatter.swift         # ByteCountFormatter + percent helpers
│       ├── HeroPanelView.swift         # Summary header (size + volume)
│       ├── FileRowView.swift           # One file row with bar/%/context menu
│       ├── SidebarView.swift           # Left panel: session list + add menu
│       ├── ScanDetailView.swift        # Right panel: Recommendations | Files toggle
│       ├── AppsView.swift              # Installed applications by size
│       └── Analysis/
│           ├── AnalysisStartView.swift # Goal + folder picker start screen
│           ├── AnalysisProgressView.swift
│           ├── CleanupPlanView.swift   # Plan groups + selection + Clean button
│           ├── CleanupCandidateRow.swift
│           ├── CleanupConfirmationView.swift
│           └── CleanupResultView.swift
├── Tests/DiskAnalyzerTests/            # ~140 tests; testable via `swift test`
├── docs/ai-cleanup/                    # ARCHITECTURE, IMPLEMENTATION_BACKLOG, AGENT_PLAYBOOK, PRIVACY
├── DESIGN.md                           # Architecture notes
└── README.md                           # User-facing
```

## Build / run

```bash
make app                # produces DiskAnalyzer.app (ad-hoc signed)
make run                # build + launch immediately
make install            # copy to /Applications
make clean              # remove .app + .build
swift run -c release    # debug launch (no Dock icon)
swift build             # debug build only
```

There is no Xcode project. If you want one, run `swift package generate-xcodeproj` or open `Package.swift` in Xcode directly — both work.

## Design decisions worth preserving

- **Swift Package, not `.xcodeproj`.** Chosen so the repo is diffable and re-openable without Xcode state. The `.app` is produced by `make app`, which is the only supported distribution path.
- **`getattrlistbulk(2)` for the hot loop, not `FileManager`.** One kernel call pulls 50–500 entries with their name/type/fsid/allocated-size in a packed buffer — replaces a `contentsOfDirectory` + N × `resourceValues` roundtrip that each go through CFURL / path resolution / a Foundation cache. Parsing is hand-rolled against the `<sys/attr.h>` bit-order + RETURNED_ATTRS rules; see `BulkScan.swift` for the reference. Keep reads under a 64 KiB stack buffer (`withUnsafeTemporaryAllocation`) — no heap per directory.
- **`ATTR_FILE_ALLOCSIZE`, not `fileSize`.** Same semantics as `URLResourceKey.totalFileAllocatedSizeKey`: block-aligned allocation across all forks. Matches Finder's "Size on disk". The old fallback to `fileSize` is gone because bulk always returns allocsize for regular files.
- **Symlinks skipped.** Prevents cycles and double-counting — this is intentional. Do not "fix" by following them without also deduplicating by inode.
- **Packages treated as leaves.** `.app`, `.photoslibrary`, etc. report correct total size but don't expose children in the UI. Users don't typically care about the insides of `.app` bundles.
- **Async fan-out at every depth, bounded by a semaphore.** `scanDir` uses a TaskGroup for subdirectory children at every level. A `ScanLimiter` actor caps concurrent readdir calls at ~CPU core count so the fan-out doesn't turn into thousands of simultaneous syscalls. Files are handled inline (no Task per file) — Tasks are scoped to directories only. Earlier bounded-depth implementations (`parallelDepth = 2`) left deep trees like DerivedData single-threaded and were measured slower.
- **Packages detected by extension, not `.isPackageKey`.** `.isPackageKey` triggers a LaunchServices UTI lookup per URL that dominates CPU on million-file scans. A hand-curated `packageExtensions` set covers ~all common bundle types at effectively zero cost. Package contents are summed with a stack-based bulk walker (`BulkScan.packageTotal`) instead of recursive scanning — we throw away their inner tree anyway.
- **Cross-mount filter via `fsid_t`, not `URLResourceKey.volumeIdentifierKey`.** The bulk scanner gives us FSIDs for free in the same syscall; comparing two `int32_t` pairs is cheaper than asking Foundation to hash an NSObject-typed volume identifier. The root's FSID is captured once via `getattrlist(2)` at the start of the scan.
- **Counter is `NSLock`-protected, not an actor.** Actors would force `await` on every file, which dominates when scanning 500K+ files. The class is `@unchecked Sendable` with a lock — measured ~3× faster than an actor on a ~200GB home scan.
- **Progress is polled, not pushed.** A background `Task.detached` snapshots the counter every 100ms; individual file scans don't touch `@MainActor`. Switching to per-file main-actor hops stalled the UI on SSD scans.
- **No sandboxing, no entitlements.** A sandboxed build can't traverse `~/Library` without prompting per-folder. The app is meant for local use — keep it unsandboxed.
- **Analysis is two-phase.** Discovery reads only the in-memory scan tree (path/size/type/position — zero filesystem calls, capped at 200 seeds); enrichment is the only stage allowed to `lstat`, exactly once per seed. Never put `stat`/`resourceValues` back into the scanner hot loop.
- **The validator is the sole draft→plan authority.** `CleanupPlanValidator` copies path/size/risk/action/evidence verbatim from the local report by candidate ID; a planner (local or AI) can only supply ordering, grouping, and bounded explanation text. Drafts cannot carry executable fields.
- **AI never touches files.** `RemoteCleanupPlanner` sends only the redacted DTO (max 100 candidates, `<private-N>` path labels, no URL/fingerprint/timestamps); the coordinator falls back to the local plan on any remote failure. Keys live in the Keychain.
- **All filesystem mutation goes through the executor seam.** Views and view models call `CleanupExecuting`/`AppViewModel.moveToTrash`; no View file calls `FileManager` directly (a grep guards this). Preflight re-verifies root containment, symlink policy, and fingerprint before every move.
- **V1 moves to Trash only.** No permanent deletion, no shell, no admin elevation. Every outcome (moved/skipped/failed) is reported per item.
- **Tests cover the seams, not the scanner internals.** ~140 tests exercise discovery, enrichment, planning, validation, preflight, the executor (with a fake trash mover), the flow view model, redaction, and the AI client (with a fake transport).

## Non-goals

- Cross-platform. macOS only; the `AppKit` / `NSWorkspace` usage is deliberate.
- Network / iCloud awareness. Scanned sizes are local blocks; iCloud-evicted files show as small even when "logically" large, same as Finder.
- Writing to disk beyond trashing user-selected items from the context menu.

## Common gotchas

- `swift run` opens a window but the process stays a CLI binary — no Dock icon, ⌘Q works, but behaviors tied to `LSUIElement`/bundle identity (Launch Services, keychain) won't match the `.app` build.
- `NSOpenPanel().runModal()` must run on the main actor (it already does — `ScanViewModel` is `@MainActor`). Don't move it.
- `open(O_RDONLY | O_DIRECTORY)` fails on unreadable dirs (EACCES on `/private`, `/System/Volumes/Data/.Spotlight-V100`, etc.); `BulkScan.readDirectory` returns nil and we produce an empty node. Don't turn that into a fatal — those failures are routine for a normal user without TCC grants.
- `getattrlistbulk` returned-attrs order: values are packed in bitmap order of the requested attrs, BUT `ATTR_CMN_RETURNED_ATTRS` is special-cased to appear first. Inside `commonattr` with our request: RETURNED → NAME → FSID → OBJTYPE → (fileattr) ALLOCSIZE. Re-ordering the request bits doesn't change this. If you add an attr, append it in bit-order at the right group; getting this wrong silently corrupts every entry.
- **Both** `getattrlist(2)` and `getattrlistbulk(2)` prepend a leading `u_int32_t` total-length field to the buffer. For bulk it's the per-entry length; for scalar stat it's the total bytes written. Always advance 4 bytes before reading `attribute_set_t`. Missing this in `stat()` once — bug manifested as `isDir=false` on `/Users/<name>` because the next read consumed the real returned-attrs bytes into the fsid slot and garbage into objtype.
