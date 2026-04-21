# DiskAnalyzer

A fast SwiftUI macOS utility for seeing what's eating your disk.

- Concurrent directory scan with live progress
- Per-folder size, percentage-of-parent bars, tree drill-down
- Right-click: Reveal in Finder · Copy Path · Move to Trash
- `.app` bundles in ~200 KB, no dependencies

Requires macOS 13+ and Xcode 15+ (command-line tools are enough).

## Run from source

```bash
cd DiskAnalyzer
swift run -c release
```

A window titled "Disk Analyzer" will open. Click **Scan Home** or **Choose Folder…**.

## Build a double-clickable app

```bash
./build-app.sh
open DiskAnalyzer.app
```

The script runs `swift build -c release`, assembles `DiskAnalyzer.app/Contents/{MacOS,Resources,Info.plist}`, and ad-hoc signs so Gatekeeper launches it without prompting.

Drag `DiskAnalyzer.app` into `/Applications` if you want it to stick around.

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
- Directories you can't read (permission denied) show size 0 without crashing. Run the app as a user with access if you need deeper numbers.
