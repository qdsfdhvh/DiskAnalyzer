# DiskAnalyzer — Agent Notes

SwiftUI macOS utility for visualizing disk usage. Built as a Swift Package (no `.xcodeproj`).

## Layout

```
DiskAnalyzer/
├── Package.swift                       # macOS 13+, single executable target
├── Sources/DiskAnalyzer/
│   ├── DiskAnalyzerApp.swift           # @main — WindowGroup only
│   ├── ContentView.swift               # ScanViewModel + top-level UI
│   ├── Models/
│   │   ├── FileNode.swift              # Tree node (class; identity-based)
│   │   └── DiskScanner.swift           # Concurrent scan + Counter actor-ish class
│   └── Views/
│       ├── FileRowView.swift           # One row: icon, bar, %, size, context menu
│       └── SizeFormatter.swift         # ByteCountFormatter + percent helper
├── build-app.sh                        # Wraps release binary into DiskAnalyzer.app
└── README.md                           # User-facing
```

## Build / run

```bash
swift run -c release          # opens a SwiftUI window
swift build                   # debug build only
./build-app.sh                # produces DiskAnalyzer.app (ad-hoc signed)
open DiskAnalyzer.app
```

There is no Xcode project. If you want one, run `swift package generate-xcodeproj` or open `Package.swift` in Xcode directly — both work.

## Design decisions worth preserving

- **Swift Package, not `.xcodeproj`.** Chosen so the repo is diffable and re-openable without Xcode state. The `.app` is produced by `build-app.sh`, which is the only supported distribution path.
- **`totalFileAllocatedSize`, not `fileSize`.** Matches Finder's "Size on disk" (block-aligned). Falls back to `fileSize` when unavailable.
- **Symlinks skipped.** Prevents cycles and double-counting — this is intentional. Do not "fix" by following them without also deduplicating by inode.
- **Packages treated as leaves.** `.app`, `.photoslibrary`, etc. report correct total size but don't expose children in the UI. Users don't typically care about the insides of `.app` bundles.
- **Top-level parallel, deep serial.** `scan(at:)` fans out one Task per top-level child in a `TaskGroup`; each task then recurses synchronously. Going all-in on Task-per-directory is slower due to Task overhead at depth.
- **Counter is `NSLock`-protected, not an actor.** Actors would force `await` on every file, which dominates when scanning 500K+ files. The class is `@unchecked Sendable` with a lock — measured ~3× faster than an actor on a ~200GB home scan.
- **Progress is polled, not pushed.** A background `Task.detached` snapshots the counter every 100ms; individual file scans don't touch `@MainActor`. Switching to per-file main-actor hops stalled the UI on SSD scans.
- **No sandboxing, no entitlements.** A sandboxed build can't traverse `~/Library` without prompting per-folder. The app is meant for local use — keep it unsandboxed.

## Non-goals

- Cross-platform. macOS only; the `AppKit` / `NSWorkspace` usage is deliberate.
- Network / iCloud awareness. Scanned sizes are local blocks; iCloud-evicted files show as small even when "logically" large, same as Finder.
- Writing to disk beyond trashing user-selected items from the context menu.

## Common gotchas

- `swift run` opens a window but the process stays a CLI binary — no Dock icon, ⌘Q works, but behaviors tied to `LSUIElement`/bundle identity (Launch Services, keychain) won't match the `.app` build.
- `NSOpenPanel().runModal()` must run on the main actor (it already does — `ScanViewModel` is `@MainActor`). Don't move it.
- `FileManager.default.contentsOfDirectory` throws on unreadable dirs; we swallow and return an empty node. Don't turn that into a fatal — `/private`, `/System/Volumes/Data/.Spotlight-V100` etc. will always fail for a normal user.
