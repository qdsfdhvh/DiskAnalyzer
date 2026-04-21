# Quiet Data — Design Language

One-line principle: **let the data be the design.** Bright paper ground, near-black text, a single warm accent used sparingly. Fewer elements, tighter alignment, more whitespace. If a decoration has to justify itself, it loses.

The entire system lives in `Sources/DiskAnalyzer/Views/DesignTokens.swift` (enum `DT`). Prefer `DT.*` over raw values anywhere in the app.

---

## Palette

All values are light-mode only. The app forces `.preferredColorScheme(.light)` — switching to dark would require a second palette that has not been drawn yet; don't fake it with `Color(light:dark:)` adapters.

| Token | Hex | When to use | Don't use for |
|---|---|---|---|
| `DT.bg` | `#FAF9F6` | The window ground. Every full-area background. | Cards or lifted panels. |
| `DT.surface` | `#FFFFFF` | Pure-white lifted surfaces (buttons, chip fills). | Main background — too cold without the warm paper. |
| `DT.surfaceAlt` | `#F7F6F4` | Alternating-row or footer-like sections when needed. | Hover — use `DT.hover`. |
| `DT.hover` | `#F3F2EF` | Row and button hover fill. | Pressed state — let button style handle opacity. |
| `DT.line` | `#E9E7E3` | 1px dividers, empty bar tracks, subtle separators. | Borders on interactive elements — use `lineStrong`. |
| `DT.lineStrong` | `#D3D0CA` | Secondary button borders, chip outlines. | Anywhere you need the eye to go — accent does that. |
| `DT.fg` | `#111113` | Primary text, primary-button fill, emphasized values. | Bars (the single-accent/neutral distinction matters). |
| `DT.fgMuted` | `#727274` | Labels, secondary text, muted numbers. | Primary calls-to-action. |
| `DT.fgSubtle` | `#B8B8B9` | Placeholder dashes, "of 500 GB" units, status labels. | Actual data values. |
| `DT.accent` | `#D17B4F` | **Exactly one job per screen**: the #1 row per directory, over-capacity warnings, active hover states. | Branding, ornament, or generic "interesting" highlighting. |
| `DT.accentSoft` | `#F0DED3` | Quick-chip hover fill. | As a default tint — it disappears against paper white. |

**Accent budget.** The warm terracotta is the scarcest resource in this system. Burning it on non-signal elements (a checkbox, a link color, a nav indicator) is the single fastest way to break the whole aesthetic. If it appears in three places on one screen, delete one.

**Tier colors.** `DT.tier(forBytes:)` returns four levels — muted gray below 10 GB, soft accent below 50 GB, full accent above. The intent is **size magnitude shows as bar width first, color second.** Don't introduce a fifth tier. Don't map it to file type.

---

## Typography

Single family: **SF Pro** for everything, **SF Mono** only where columns must line up. No serif — `.serif` was tried in the "Data Editorial" direction and rejected. Don't reintroduce it without a palette change to match.

| Scale | Font | Where | Notes |
|---|---|---|---|
| 44 / light | `DT.text(44, weight: .light)` | Hero total ("413 GB"), scanning counter | Always paired with a smaller unit label at 16pt regular. |
| 22 / semibold | `DT.text(22, weight: .semibold)` | Empty-state headline | One per screen. |
| 16 / regular | `DT.text(16)` | Hero unit suffix | Muted. Never bold. |
| 13 / medium | `DT.text(13, weight: .medium)` | Row #1 (anchor) name, toolbar title | Use medium sparingly — one weight step signals importance cheaply. |
| 13 / regular | `DT.text(13)` | Body, non-anchor row names, empty-state subcopy | Default body weight. |
| 12 / medium | `DT.text(12, weight: .medium)` | Buttons, chip labels | Buttons are always medium. |
| 11 / regular | `DT.text(11)` | Hero subline, status values | |
| 10 / regular | `DT.text(10)` | Tiny labels on status pairs | The floor — nothing smaller than 10pt. |

Mono: `DT.mono(size)` → `SF Mono`. Use for **every number that sits in a column** (sizes, percents, times, item counts, free space). Do not use mono for decorative numbers or single figures on their own — the hero "413" uses `DT.text` because it doesn't need to align with anything below it.

Apply `.monospacedDigit()` to mono `Text` showing changing values (scanning counter, elapsed time). It stops digits from reflowing as the value ticks up.

---

## Components

### Buttons — `QuietButtonStyle(variant:)`

Three variants, no fourth.

- **`.primary`** — black fill, white text. Exactly one per screen. The single action that matters most right now ("Scan Home" in empty state, "Choose Folder" nowhere — that's secondary).
- **`.secondary`** — transparent fill, `DT.lineStrong` 1px border, `DT.fg` text. The everyday button. Multiple per screen is fine.
- **`.ghost`** — no border, no fill, text only. Tertiary actions that live in toolbars ("Rescan" after a scan exists). Hover adds `DT.hover` fill.

All buttons use `cornerRadius: 6`. Don't go higher (pill-shaped) except on chips — rounded-rectangle buttons with 6pt radius read as "native macOS, restrained."

### Rows — `FileRowView`

One layout for every row regardless of nesting depth:

```
[chevron 14pt] [name, flex]    [bar, flex 3pt tall]  [percent 48pt mono]  [size 92pt mono right]
```

- Row #1 of each parent is `weight: .medium` on name, `semibold` on size, and its bar is full accent regardless of the actual byte count. This creates **one focal point per folder** — the eye knows where to land.
- Rows 2+ use regular weight; bar color comes from `DT.tier(forBytes:)`.
- Hover adds `DT.hover` background, `cornerRadius: 6`.
- Row vertical padding is `DT.rowVPadding` (10pt). Tightening this further makes the app feel like a spreadsheet; loosening it wastes the scroll area.

### Hero — `HeroPanelView`

Two blocks, top of content area, separated by hair-thin dividers above and below:

- **Left**: the scan total as a big light-weight number plus a muted unit. Below it, the scanned path (truncated middle).
- **Right**: used-of-volume percent + a 260×3pt thin meter. The meter fills `DT.fg` normally and switches to `DT.accent` above 85% — that's the one place the accent surfaces without being a row anchor.

Don't add charts, legends, or additional stats here. If you need more, it goes in the list.

### Quick Chips — `QuickChip`

Pill-shaped (`cornerRadius: 999`), white fill, `DT.lineStrong` border, hover flips to `DT.accentSoft` fill + `DT.accent` text + `DT.accent` border at 30% opacity. Used only in the empty state for shortcuts to common heavy-hitters (DerivedData, Caches, etc.).

### Status bar

A single row at the bottom, `DT.bg` background, top border `DT.line`. Each field is a label/value pair: tiny 10pt subtle label + 11pt mono value. The `Skipped` field uses `DT.accent` as its value color — this is the one exception to "accent = row anchor", and it earns it because "we excluded N things from your number" is a trust-affecting claim that should catch the eye.

---

## Anti-patterns

These failed in earlier iterations. Don't reintroduce them without an explicit redesign.

- **`.accentColor` blue.** The macOS system accent is on purpose nowhere in this app. Using it will make the app look like every other SwiftUI demo.
- **Rainbow tier bars.** Red/orange/yellow/green by size bucket reads as "status badge" and dulls the accent. Two tones (muted / accent) is enough.
- **Rounded cards with shadows.** Every grouped surface used to get a rounded card treatment — it shredded the whitespace. Dividers only.
- **Serif display.** Tried "Data Editorial" direction; user rejected as "不好看". SF Pro only.
- **Giant icons in empty states.** A 48pt `externaldrive.badge.questionmark` SF symbol feels like AI-generated landing pages. The empty state leads with one sentence of type.
- **Stacked bar chart in the hero.** Visually loud, didn't add information the list doesn't already show.
- **`.textCase(.uppercase) + tracking(3)` on everything.** Editorial all-caps labels felt like a financial terminal. Sentence case reads calmer.

---

## Cross-app reuse (future)

Right now `DesignTokens.swift` is a single file in DiskAnalyzer. If a second app in the monorepo adopts Quiet Data:

1. Don't copy-paste the file. Extract it into a Swift Package sibling (e.g. `Personal/projects-monorepo/projects-monorepo/QuietDataKit/`) and add it as a `.package(path: "../QuietDataKit")` dependency.
2. Keep the palette and type scale identical across apps. App-specific colors (domain data visualizations) go in the consuming app, not in the shared kit.
3. This doc moves to the shared kit at that point; each app can extend it with app-specific component notes.

Not now. Premature abstraction is a bigger threat than duplication at N=1.
