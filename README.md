# DiskAnalyzer

A fast SwiftUI macOS utility that turns disk scans into **cleanup recommendations** — with optional AI-enhanced planning — and safely moves selected items to the Trash.

- Fast concurrent scan (one kernel call per directory, live progress)
- Local rule-based analysis: Xcode DerivedData, app caches, old installers, old downloads, simulator data, large files
- Recommendations grouped by risk: *Safe to reclaim · Review recommended · Manual judgment*
- Per-item evidence, risk labels, and Reveal in Finder
- Optional AI planning via your own API key (off by default, local-only otherwise)
- Review → confirm → **move to Trash** (nothing is ever permanently deleted in V1)
- Raw file browser kept as an evidence view (`Files` tab)
- `.app` bundle ~200 KB, no third-party dependencies

Requires macOS 13+ and Xcode 15+ (command-line tools are enough).

## Run from source

```bash
cd DiskAnalyzer
swift run -c release
```

A window titled "Disk Analyzer" will open. Choose a folder (or a goal), scan, then review recommendations.

## Build a double-clickable app

```bash
make app            # release build + assemble DiskAnalyzer.app (ad-hoc signed)
make run            # build and launch immediately
make install        # copy to /Applications
make clean          # remove .app + .build
make debug          # debug build only (CLI binary, no Dock icon)
```

`make app` runs `swift build -c release`, assembles the `.app` bundle and
Info.plist, and ad-hoc signs so Gatekeeper launches it without prompting.

Drag `DiskAnalyzer.app` into `/Applications` if you want it to stick around.

## How it works

1. **Scan** — the scanner walks the folder with `getattrlistbulk(2)` and live progress.
2. **Analyze** — local rules find candidates; only candidates get extra metadata (a second pass, never the hot loop).
3. **Recommend** — a local planner groups candidates by risk and suggests a default selection, optionally shaped by your space goal.
4. **Optional AI** — with a BYOK key, a redacted candidate summary is sent to an OpenAI-compatible endpoint to re-group and explain; the local plan is always the fallback.
5. **Review** — check boxes, read evidence, approve high-risk items explicitly.
6. **Clean** — a confirmation sheet lists the exact items; each is re-verified (inode/device/size/date, still inside the analyzed folder) right before moving to the **Trash**.
7. **Result** — moved / skipped / failed breakdown, per item.

## Privacy

Local-first: everything works offline. AI is opt-in and sends only a redacted
summary — no file contents, no complete tree, no usernames, no fingerprints,
at most 100 candidates per request. Keys live in the Keychain.
See [docs/ai-cleanup/PRIVACY.md](docs/ai-cleanup/PRIVACY.md).

## Tips for a nearly-full Mac

Start with these paths — they're where space usually hides:

- `~/Library/Caches` — safe to clear, apps rebuild
- `~/Library/Developer/Xcode/DerivedData` — huge on dev machines, auto-rebuilt
- `~/Library/Developer/CoreSimulator/Devices` — old iOS simulators
- `~/Library/Containers` — per-app sandbox data (Mail, Messages attachments)
- `~/Downloads`, `~/Movies`
- `/Library/Caches`, `/private/var/folders` (requires admin — launch via `sudo open`)

## Notes

- Sizes are reported as `totalFileAllocatedSize` (actual blocks on disk), matching Finder's "Size on disk" value.
- Symlinks are skipped to avoid cycles and double counting.
- App bundles and `.photoslibrary` packages are shown as leaves (no drill-in) but totals are accurate.
- Directories you can't read (permission denied) show size 0 without crashing.
- V1 moves to the Trash only; permanent deletion is intentionally not supported.
