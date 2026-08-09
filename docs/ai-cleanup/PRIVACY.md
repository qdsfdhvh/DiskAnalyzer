# Privacy

DiskAnalyzer is local-first. The scan, analysis, recommendations, review, and
Trash execution all work with zero network access. AI enhancement is optional
and off by default.

## What stays on your Mac

Everything produced by scanning and local analysis:

- the full file tree and sizes
- paths, modification times, allocated sizes
- fingerprints (device IDs and inodes)
- your recommendations and execution history

None of this leaves the machine.

## What is uploaded when AI is enabled

AI is **opt-in** and uses a user-provided API key (bring-your-own-key). Only
then, and only when a plan is requested, does the app send a compact, redacted
summary — at most **100 candidates per request** — containing, per candidate:

- an opaque candidate ID (UUID)
- a redacted path label
- the cleanup category
- the size in bytes
- the risk level
- whether it is default-selected
- short evidence summaries

### Path redaction

Before anything is sent:

- your home directory is replaced with `~`;
- known system segments needed for classification are kept
  (`Library/Developer/Xcode/DerivedData`, `Library/Caches`, `Downloads`, …);
- every other path component is replaced with a deterministic label such as
  `<private-1>`, stable within one request;
- file extensions are kept (`<private-1>.dmg`), because they are not
  identifying and help the model reason about installers.

**Never uploaded:** file contents, the complete directory tree, sibling
listings, usernames, volume names, device IDs, inodes, exact timestamps, or
your API key. Raw paths only exist locally; the model only ever sees labels.

## API key storage

Your key is stored in the macOS **Keychain** (`KeychainAPIKeyStore`). It is
never written to `UserDefaults`, source code, plan history, logs, or request
fixtures.

## Trash semantics

V1 moves selected items to the **Trash** only — nothing is permanently
deleted. Every item is re-verified immediately before moving (still inside the
analyzed folder, same inode/device, same size/date), and partial failures are
shown explicitly. Restore from the Trash at any time.

## Limitations

- Symlinks are skipped, matching the scanner policy.
- Directories you cannot read show size 0; unreadable items are not candidates.
- A small window exists between the pre-flight check and the move (check-then-act
  is inherently racy); because moves go to the Trash, the practical risk is low.
- iCloud-evicted files show their local size, same as Finder.
- Plan history is not persisted across launches in V1.

## If you have questions

The full data-flow contract lives in `docs/ai-cleanup/ARCHITECTURE.md`;
the redaction rules and their tests live in
`Sources/DiskAnalyzer/Planning/AI/PrivacyRedactor.swift` and
`Tests/DiskAnalyzerTests/PrivacyRedactorTests.swift`.
