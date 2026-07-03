# Design System (M1)

The implementation-ready visual design system for the Crowly M1 iOS app and `systemMedium` widget. This doc realizes the interaction spec in [`ux.md`](ux.md), renders the contract in [`schema.md`](schema.md), and respects the architecture in [`architecture.md`](architecture.md). It is opinionated, Apple-native, and intended to be built from directly — the coder will adapt these sketches, but the tokens, components, and screen hierarchies are decisions, not options.

## Scope & constraints (locked)

- **Deployment target: iOS 26.** Liquid Glass APIs (`.glassEffect()`, `GlassEffectContainer`, `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)`) are usable freely. Each API site that requires iOS 26 is flagged inline as `[iOS 26]` so M2 (potentially lower minimum) can `@available`-gate later. Do not add gates now.
- **Demo Mode first.** Every component renders entirely from canned model values; nothing here depends on a live companion or network.
- **The triad is the product:** (1) Inbox list cell, (2) Digest detail view, (3) `systemMedium` widget entry. Everything else exists to serve these three.
- **Fixed warm brand identity (2026-07-02 redesign).** Crowly ships a *fixed* visual identity sampled from the app icon / onboarding art — a cream field, ink-black serif display, and a single orange accent. The app is **light-locked** (`.preferredColorScheme(.light)` at the scene root); the identity does **not** invert under dark mode. This is a deliberate move away from adaptive system colors so the crow-on-cream look reads the same on every device.
- **Liquid Glass for chrome, not the brand.** Toolbars still get system glass, but *primary* CTAs are the flat orange brand pill (`CrowlyPrimaryButtonStyle`), not `.buttonStyle(.glass)`. Digest cards and detail body stay opaque so prose is legible against any wallpaper or beneath glass chrome. Glass may still appear on minor chrome (e.g. the undo toast, demo-mode banner).

---

## 1. Design tokens

### 1.1 Semantic colors — the fixed Brand palette

The identity is a **fixed, light-locked palette** sampled from the app icon and onboarding art. Literal sRGB values live in **one** place — the `Brand` enum in `Shared/Theme/Tokens.swift` — and the semantic `Color.crowly*` tokens are re-pointed at it so every call site inherits the identity for free. Use the **semantic name** at the call site; `Color(red:green:blue:)` is sanctioned *only* inside the `Brand` enum itself. There is no dark-mode variant table: the app runs at `.preferredColorScheme(.light)` and the identity is stable across devices.

| Semantic name | Brand token | sRGB | Where used |
|---|---|---|---|
| `crowly.background` | `Brand.cream` | `#FEF8F1` | Inbox list backdrop, settings root — the cream field behind everything |
| `crowly.groupedBackground` | `Brand.creamDeep` | `#F7F0E6` | Grouped-list backdrop; cards lift off it |
| `crowly.surface` | `Brand.paper` | `#FFFDFA` | Digest cell + detail card fills (opaque, by rule) — warm near-white |
| `crowly.surface.elevated` | `Brand.paper` | `#FFFDFA` | Sheets, bottom-bar buttons not on glass |
| `crowly.ink` | `Brand.ink` | `#0B0F14` | The crow + primary text |
| `crowly.inkSoft` | `Brand.inkSoft` | `#3A3630` | Body copy / meta — warm dark grey, not pure grey |
| `crowly.inkFaint` | `Brand.inkFaint` | `#6B645A` | Captions, disabled glyphs, muted state |
| `crowly.hairline` | `Brand.hairline` | `#D8CEBF` | Warm hairline borders, inactive page dots |
| `crowly.accent` | `Brand.orange` | `#F5871F` | **The single accent** — CTAs, active page dot, links, unread dots, the signature divider |
| `crowly.success` | `Color.green` | system | Success glyph (callout variant only) |
| `crowly.destructive` | `Color.red` | system | Urgent-urgency glyph, `critical` callout |
| `crowly.muted` | `Brand.inkFaint` | `#6B645A` | Archive swipe, archived-state status dot |

The `AccentColor` asset is brand orange; the scene root applies `.tint(Brand.orange)` + `.preferredColorScheme(.light)` (`App/CrowlyApp.swift`), so `.accentColor`, `.tint`, and system control tints all resolve to orange app-wide.

> **Rules:**
> 1. Text on cards still uses `Color.primary` / `.secondary` where system semantics fit (Dynamic Type + Increased Contrast inherit). Where a call site needs the brand ink explicitly (warm-on-cream surfaces), use `Color.crowlyInk` / `Color.crowlyInkSoft` / `Color.crowlyInkFaint`.
> 2. The light lock is a design decision, not a bug — do **not** re-introduce a dark palette or add an adaptive asset without reopening the identity discussion.

#### 1.1.1 Urgency colors

Maps `digest.urgency` → an accent used only on the cell's leading exclamation glyph (when high/urgent) and the widget's urgency rail. Body text never tints by urgency (legibility). In the fixed palette both `normal` and `high` land on brand orange — the accent is already a warm alert color, so there's no separate "warning yellow." Urgent escalates to red.

| `urgency` | Color | SF Symbol cue |
|---|---|---|
| `low` | `Brand.inkFaint` @ 0.6 (subtle) | none |
| `normal` | `Brand.orange` (`.crowlyAccent`) | none |
| `high` | `Brand.orange` (`.crowlyAccent`) | `exclamationmark` (small, leading the timestamp) |
| `urgent` | `.crowlyDestructive` (red) | `exclamationmark.2` |

```swift
extension Color {
    static func urgency(_ u: Urgency) -> Color {
        switch u {
        case .low:    Brand.inkFaint.opacity(0.6)
        case .normal: Brand.orange
        case .high:   Brand.orange
        case .urgent: .crowlyDestructive
        }
    }
}
```

#### 1.1.2 Job-color derivation (deterministic, no config)

Per the invariant in `ux.md` — **same `job_id` always yields the same color, with no per-job config in M1.** Hash → hue; saturation and lightness are fixed so the palette is visually consistent across jobs and stays legible in both light and dark mode.

**Algorithm:**

1. Compute a stable 64-bit unsigned hash of `job_id` (FNV-1a — simple, deterministic, no `Foundation.hash` randomization across launches).
2. `hue = (hash mod 360) / 360.0` — full 0..1 hue wheel.
3. Saturation and lightness are **fixed per appearance** (HSL → HSB conversion below):
   - Light mode: `S = 0.55`, `L = 0.45` → mid-saturation, mid-lightness (good contrast on white).
   - Dark mode: `S = 0.65`, `L = 0.65` → slightly more saturated and lighter (good contrast on near-black).
4. Convert HSL → SwiftUI's `Color(hue:saturation:brightness:)` (HSB) via the standard transform.

```swift
import SwiftUI

enum JobColor {
    /// Deterministic per-job color. Same `job_id` → same color on any device,
    /// for the lifetime of the schema. Stable across app launches.
    static func color(for jobId: String, in scheme: ColorScheme) -> Color {
        let h = fnv1a64(jobId)
        let hue = Double(h % 360) / 360.0
        let (s, l): (Double, Double) = scheme == .dark ? (0.65, 0.65) : (0.55, 0.45)
        let (hsbS, hsbB) = hslToHsb(s: s, l: l)
        return Color(hue: hue, saturation: hsbS, brightness: hsbB)
    }

    // FNV-1a 64-bit. Deterministic — does NOT use Swift's randomized String.hashValue.
    private static func fnv1a64(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash &= 0xFFFFFFFFFFFFFFFF
            hash = hash &* prime
        }
        return hash
    }

    // HSL (CSS-style) → HSB (Apple-style). Same hue, different S/B.
    private static func hslToHsb(s sl: Double, l: Double) -> (Double, Double) {
        let b = l + sl * min(l, 1 - l)
        let sb = b == 0 ? 0 : 2 * (1 - l / b)
        return (sb, b)
    }
}
```

**Why FNV-1a not `String.hashValue`:** Swift randomizes the seed of its native hash per process, so the same `job_id` would change color across launches — unusable.

#### 1.1.3 Callout-variant colors (schema v2 content blocks)

A v2 `callout` block (`schema.md` § 1.3) carries a `variant` that maps to a tint + SF Symbol. The tint is used **only** on the callout's leading icon and its left accent bar — the callout body text stays `.primary` (the legibility rule: emphasis via chrome, never by tinting prose). Kept distinct from urgency: a callout's emphasis is authored per-block, independent of the digest's overall `urgency`. Implemented as `Color.callout(_:)` + `CalloutVariant.symbolName` in `Shared/Theme/Tokens.swift`.

| `variant` | Color token | SF Symbol |
|---|---|---|
| `info` (default) | `Brand.orange` (`.crowlyAccent`) | `info.circle.fill` |
| `warning` | `Brand.orange` (same accent) | `exclamationmark.triangle.fill` |
| `success` | `.crowlySuccess` (green) | `checkmark.circle.fill` |
| `critical` | `.crowlyDestructive` (red) | `exclamationmark.octagon.fill` |

Under the fixed brand palette, `info` and `warning` both resolve to brand orange — the accent is already a warm alert color, and the SF Symbol (info circle vs. triangle) carries the distinction. `success` and `critical` still get their own tints because they mean semantically different things (positive confirmation vs. hard alert). Unknown/missing `variant` → `info` (tolerant default, per `schema.md` § 1.3).

#### 1.1.4 Unread-dot states (two; never a badge stack)

`UnreadDot` is the single source of truth for cell read/unread state. Per `ux.md` § Inbox.

| State | Fill | Stroke | Diameter | Notes |
|---|---|---|---|---|
| `unread` | `Brand.orange` (via `.accentColor`) | none | 10pt | Digest hasn't been opened |
| `read` | n/a | n/a | hidden | Dot is not rendered |

(Archived digests live in their own section and don't render a dot at all — the section header *is* the state.)

Per-urgency tinting layers on top: if `digest.urgency >= .high` and state is `unread`, the dot inherits `Color.urgency(digest.urgency)` — which in the fixed palette means the dot stays orange for `high` and escalates to red for `urgent`. One signal, not two badges.

### 1.2 Typography

Map every text role to a `Font.TextStyle` — never a fixed point size, with a single exception below — so Dynamic Type scales the whole app for free. The redesign introduces a **serif display face** (`.serif` — New York, ships with iOS) for hero titles, cell titles, and section headings; body/UI copy stays SF Pro. Serif carries the brand personality without a licensed webfont.

| Token | Face | TextStyle | Weight | Used for |
|---|---|---|---|---|
| `crowlyDisplay` | `.serif` | `.largeTitle` | `.bold` | Onboarding / hero titles |
| `crowlyDisplayLarge` | `.serif` | 40 pt (fixed) | `.bold` | The 40pt serif hero on the first onboarding screen (the one place a fixed size is sanctioned — a deliberate typographic beat) |
| `crowlyTitle` | `.serif` | `.title` | `.semibold` | Screen-level titles |
| `crowlySectionTitle` | `.serif` | `.title3` | `.semibold` | Section headings in detail (from `sections[].heading`) |
| `crowlyCellTitle` | `.serif` | `.headline` | (headline default) | Digest cell title |
| `crowlyCellBody` | SF Pro | `.body` | `.regular` | Cell `bottom_line`, detail summary/section bodies |
| `crowlyDetailCallout` | SF Pro | `.callout` | `.regular` | Detail "Bottom line" callout block |
| `crowlyChip` | SF Pro | `.caption` | `.semibold` | Chips, pills, small labels |
| `crowlyChipSmall` | SF Pro | `.caption2` | `.medium` | Widget meta, tightest chips |
| `crowlyDetailQ` | SF Pro | `.body` | `.medium` | Emphasis body in detail |
| meta | SF Pro | `.footnote` | `.regular` | Cell timestamp, secondary meta |
| mono.id | SF Pro | `.caption2.monospaced()` | `.regular` | Debug surfaces / Settings only — never in main flow |

```swift
extension Font {
    // Display — serif carries the brand
    static let crowlyDisplay:      Font = .system(.largeTitle, design: .serif).weight(.bold)
    static let crowlyDisplayLarge: Font = .system(size: 40, weight: .bold, design: .serif)
    static let crowlyTitle:        Font = .system(.title, design: .serif).weight(.semibold)
    static let crowlySectionTitle: Font = .system(.title3, design: .serif).weight(.semibold)
    static let crowlyCellTitle:    Font = .system(.headline, design: .serif)
    // Body / UI — SF Pro
    static let crowlyCellBody:     Font = .body
    static let crowlyDetailCallout: Font = .callout
    static let crowlyChip:         Font = .caption.weight(.semibold)
    static let crowlyChipSmall:    Font = .caption2.weight(.medium)
    static let crowlyDetailQ:      Font = .body.weight(.medium)
}
```

Line limits: cell `bottom_line` is `lineLimit(2)` with `.truncationMode(.tail)`. The cell never truncates the title — it sits on one line via `lineLimit(1)` on the headline.

### 1.3 Spacing & corner radii

Eight-pt-grid; same scale everywhere.

| Token | pt | Used for |
|---|---|---|
| `space.xs` | 4 | Job stripe width, intra-meta padding |
| `space.s` | 8 | Cell vertical rhythm between rows |
| `space.m` | 12 | Cell horizontal padding, section gutter |
| `space.l` | 16 | Card insets, bottom-bar button spacing |
| `space.xl` | 24 | Section break in detail |
| `space.xxl` | 32 | Detail-view top-of-section breathing room |

| Token | pt | Used for |
|---|---|---|
| `radius.card` | 14 | Inbox cell card surround, callout block |
| `radius.surface` | 18 | Sheet handles, detail callout |
| `radius.widget.row` | 12 | Widget row backgrounds (where used) |
| `radius.pill` | 28 | The full-width brand pill CTA (`CrowlyPrimaryButtonStyle`) — onboarding, pairing, primary detail actions |

```swift
enum Space { static let xs:CGFloat=4, s:CGFloat=8, m:CGFloat=12,
                  l:CGFloat=16, xl:CGFloat=24, xxl:CGFloat=32 }
enum Radius { static let card:CGFloat=14, surface:CGFloat=18,
                   widgetRow:CGFloat=12, pill:CGFloat=28 }
```

Minimum tap target: **44pt × 44pt** everywhere (HIG). Visual size may be smaller; `.contentShape(Rectangle())` extends the hit region.

### 1.4 Glass vs. brand pill — chrome hierarchy

The product invariant: **glass = system chrome; opaque = content; brand pill = primary action.** Decision rules below; if a surface isn't on the table, default to opaque.

| Surface | Treatment | Why |
|---|---|---|
| Navigation bar | System default (glass) | Apple-native; no override |
| Bottom toolbar (`.bottomBar`) | System default (glass) | Apple-native |
| **Primary CTAs** (onboarding "Connect my inbox", pairing "Pair", QR-unavailable "Enter manually") | `.buttonStyle(.crowlyPrimary)` — flat orange pill, ink-on-orange label | The brand identity; replaces `.buttonStyle(.glass)` for the *primary* action so the identity is consistent app-wide |
| Detail `⋯` menu | Plain `Menu` (system chrome) | Secondary; system-default is fine |
| Undo toast, minor chrome overlays | `.glassEffect(.regular)` `[iOS 26]` is still allowed | Chrome that isn't the primary action |
| Widget background | `.containerBackground(for: .widget) { Color.clear }` so system renders glass beneath | WidgetKit invariant |
| Cell card | **Opaque** `Brand.paper` (`crowly.surface`) on `Brand.cream` field | Prose legibility; `bottom_line` reads against any wallpaper |
| Detail body | **Opaque** `Brand.paper` | Same reason |
| Detail "Bottom line" callout | Opaque tinted block — `Brand.orange @ 0.08` fill at `Radius.surface` | Visual emphasis without glass; legible |
| Demo-mode banner | `.glassEffect(.regular.tint(.orange))` `[iOS 26]` in a Capsule | Chrome on top of inbox; tint signals "not real data" |

**Three hard rules** (changing any is a design change):

1. **Never put `.glassEffect()` on a view that owns the main reading text** — cell title, `bottom_line`, summary, section body. Glass-behind-prose fails the legibility bar against busy wallpapers.
2. **Primary CTAs are the orange brand pill, not glass.** `.buttonStyle(.crowlyPrimary)` is the *only* primary CTA in the app. `.buttonStyle(.glass)` / `.glassProminent` are reserved for secondary/chrome, or removed outright in favor of the pill.
3. **No widget buttons.** The widget is read-only; `Button(intent:)` is not used in any widget surface. (This is the reader-pivot's hardest constraint; rest of the design follows from it.)

---

## 2. Component inventory

Each entry: purpose · props · states · SwiftUI sketch. Sketches are real code — adapt for naming/file layout but keep the modifier order and the binding shape.

### 2.1 `UnreadDot`

**Purpose.** The two-state read indicator on every cell. Single source of truth.

**Props.**
```swift
struct UnreadDot: View {
    let isUnread: Bool
    var urgency: Urgency = .normal   // tints unread state when .high/.urgent
}
```

**States.** See §1.1.4.

**Sketch.**
```swift
struct UnreadDot: View {
    let isUnread: Bool
    var urgency: Urgency = .normal

    var body: some View {
        Group {
            if isUnread {
                Circle().fill(dotColor)
            } else {
                EmptyView()
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityLabel(isUnread ? a11yLabel : "")
    }

    private var dotColor: Color {
        urgency == .high || urgency == .urgent ? .urgency(urgency) : .accentColor
    }

    private var a11yLabel: String {
        switch urgency {
        case .urgent: "Unread, urgent"
        case .high:   "Unread, high priority"
        default:      "Unread"
        }
    }
}
```

### 2.2 `JobColorStripe`

**Purpose.** The 4pt leading edge stripe on every cell (and widget row), colored deterministically from `job_id`.

**Props.**
```swift
struct JobColorStripe: View {
    let jobId: String
}
```

**Sketch.**
```swift
struct JobColorStripe: View {
    let jobId: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(JobColor.color(for: jobId, in: scheme))
            .frame(width: Space.xs)
            .accessibilityHidden(true)
    }
}
```

### 2.3 `UrgencyGlyph`

**Purpose.** Leading exclamation glyph on a cell or detail header when `urgency` is `high` or `urgent`. Vanishes at `normal`/`low`.

**Props.**
```swift
struct UrgencyGlyph: View {
    let urgency: Urgency
}
```

**Sketch.**
```swift
struct UrgencyGlyph: View {
    let urgency: Urgency
    var body: some View {
        switch urgency {
        case .urgent:
            Image(systemName: "exclamationmark.2")
                .font(.footnote)
                .foregroundStyle(Color.urgency(.urgent))
                .accessibilityLabel("Urgent")
        case .high:
            Image(systemName: "exclamationmark")
                .font(.footnote)
                .foregroundStyle(Color.urgency(.high))
                .accessibilityLabel("High priority")
        default:
            EmptyView()
        }
    }
}
```

### 2.3a `CrowlyDivider` — the signature mark

**Purpose.** The onboarding art's signature mark: a short orange rule broken by a center dot — `——●——`. Reused under hero headlines (onboarding) and as a section rule (above "Sources" in digest detail). Small, deliberate, unmistakably Crowly; the visual equivalent of a comma in the brand's voice.

**Props.**
```swift
struct CrowlyDivider: View {
    var width: CGFloat = 132
}
```

**Sketch.** Lives in `Shared/Theme/Tokens.swift`; two orange capsule lines flanking a 6pt orange dot, laid out in an `HStack(spacing: Space.s)`. Accessibility-hidden — it's decorative.

### 2.3b `CrowlyPrimaryButtonStyle` — the brand pill CTA

**Purpose.** The flat, full-width orange pill lifted from the onboarding screenshot. The **only** primary CTA style in the app; replaces `.buttonStyle(.glass)` / `.glassProminent` wherever the previous design used them for the primary action. Ink-on-orange label, subtle press-dim, honors Dynamic Type via `.body.weight(.semibold)`.

**Usage.**
```swift
Button("Connect my inbox") { … }
    .buttonStyle(.crowlyPrimary)
```

**Where it appears (as of 2026-07-02):** onboarding last-screen CTA, `PairCompanionView` "Pair", the QR-unavailable "Enter manually" fallback. Not on every button in the app — only *primary* CTAs; secondary actions stay plain, and minor chrome may still use glass.

**Rules.**
- One `.crowlyPrimary` per screen at most (it's a primary; a screen with two of them has an information-architecture problem).
- Never on destructive actions — the pill is orange (brand), not red.
- Never inside the widget (no buttons in the widget, period).

### 2.4 `DigestCell`

**Purpose.** The inbox row — the first must-build of the triad.

**Props.**
```swift
struct DigestCell: View {
    let digest: Digest
    let isUnread: Bool
}
```

**States.** Inherits from `UnreadDot`. Swipe states are handled by `swipeActions` on the enclosing `List`.

**Sketch.**
```swift
struct DigestCell: View {
    let digest: Digest
    let isUnread: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            JobColorStripe(jobId: digest.jobId)

            VStack(alignment: .leading, spacing: Space.s) {
                // Title row
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(digest.title)
                        .font(.crowlyCellTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    UnreadDot(isUnread: isUnread, urgency: digest.urgency)
                }

                // Meta row
                HStack(spacing: Space.xs) {
                    UrgencyGlyph(urgency: digest.urgency)
                    Text(digest.createdAt, format: .relative(presentation: .named))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                // Bottom line
                if !digest.bottomLine.isEmpty {
                    Text(digest.bottomLine)
                        .font(.crowlyCellBody)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            .padding(.vertical, Space.s)
        }
        .padding(.horizontal, Space.m)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color("crowly.surface"))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
    }

    private var a11yLabel: String {
        var parts = [digest.title]
        if isUnread { parts.append("Unread") }
        if digest.urgency >= .high { parts.append("\(digest.urgency.rawValue) priority") }
        parts.append(digest.bottomLine)
        return parts.joined(separator: ". ")
    }
}
```

### 2.5 Content-block renderers (schema v2)

The detail view renders a digest's `content` array (`schema.md` § 1.3) as a stack of per-type views (`App/Views/ContentBlockView.swift`). Each reuses the existing token vocabulary — `Space`, `Radius`, the `Font` roles, and the semantic colors above — so blocks sit inside the reader's visual grammar rather than beside it. Inline text (paragraph / callout / list items) runs through `CrowlyMarkdown.attributed(_:)` for the restricted `**bold**` / `*italic*` / `` `code` `` / `[link](url)` subset; block text stays `.primary` (legibility). Empty / whitespace-only blocks are filtered out before rendering (`ContentBlock.isRenderable`), and an unknown block type surfaces its `text` as a plain paragraph if it has one, else nothing — never raw JSON.

| Block | Rendering | Tokens used |
|---|---|---|
| `paragraph` | Inline-markdown `Text`, `.body`, full-width leading | `Font.body` |
| `heading` | `Font.crowlyCellTitle` (`.headline`), small top pad | `Space.xs` |
| `list` | Marker + item rows; marker is `•` (bullet) or `1.` `2.` … (ordered), `.secondary` | `Space.s` |
| `callout` | Icon + optional bold `title` + body in a tinted card with a **left accent bar**; fill is `Color.callout(variant).opacity(0.10)`, bar + icon are `Color.callout(variant)` (§1.1.3) | `Radius.surface`, `Space.l`, `Space.m` |
| `metrics` | Two-column `LazyVGrid` of value-over-label cards; value `.title3.semibold`, label `.caption` uppercase `.secondary`; card fill `crowly.surface.elevated` | `Radius.card`, `Space.m` |
| `divider` | System `Divider` with vertical padding | `Space.xs` |

The callout card is the one block that draws a colored surface — and it draws it as **chrome around** the prose (tinted fill + accent bar + icon), never by tinting the reading text. This keeps the "glass/tint = chrome, opaque = content" rule intact: a callout is emphasis, not an action (`schema.md` § What's deliberately not in the schema).

---

## 3. The triad — concrete screens

All three sketches assume canned demo data flowing through a `DigestStore` (an `@Observable` view-model) with `Digest` and `Section` types mirroring `schema.md`. No backend in M1's first runnable milestone.

### 3.1 `InboxView` (must-build #1)

```swift
struct InboxView: View {
    @Environment(DigestStore.self) private var store
    @State private var query: String = ""

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            List {
                ForEach(store.sectionedDigests(matching: query)) { section in
                    Section {
                        ForEach(section.digests) { digest in
                            NavigationLink(value: digest.id) {
                                DigestCell(
                                    digest: digest,
                                    isUnread: store.isUnread(digest)
                                )
                            }
                            .listRowInsets(EdgeInsets(
                                top: Space.xs, leading: Space.m,
                                bottom: Space.xs, trailing: Space.m))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button {
                                    store.archive(digest)
                                } label: {
                                    Label("Archive", systemImage: "tray.and.arrow.down")
                                }
                                .tint(.gray)
                            }
                        }
                    } header: {
                        Text(section.title)            // Today / Yesterday / This week / Earlier
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color("crowly.background"))
            .navigationTitle("Inbox")
            .navigationDestination(for: Digest.ID.self) { id in
                if let digest = store.digest(byId: id) {
                    DigestDetailView(digest: digest)
                        .onAppear { store.markRead(digest) }
                }
            }
            .searchable(text: $query)
            .searchToolbarBehavior(.minimize)
            .refreshable { await store.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                if store.isInDemoMode {
                    DemoModeBanner()
                        .padding(.horizontal, Space.m)
                        .padding(.vertical, Space.s)
                }
            }
            .overlay {
                if store.isEmpty(forQuery: query) {
                    ContentUnavailableView(
                        store.isInDemoMode
                            ? "No digests yet"
                            : "No matches",
                        systemImage: "tray",
                        description: Text(store.isInDemoMode
                            ? "Send your first one from Hermes."
                            : "Try a different search.")
                    )
                }
            }
        }
    }
}
```

**Notes.**
- `List` with `.plain` style + transparent row backgrounds — the card surface comes from `DigestCell`'s own `.background`, so cells visually float over `crowly.background`.
- `.scrollContentBackground(.hidden)` lets the inbox backdrop show through.
- `.relative(presentation: .named)` on the timestamp gives "Today at 7 PM" / "Yesterday" natively.
- Demo banner uses `.safeAreaInset(.top)` per `ux.md`.
- **Read state flips on `onAppear` of the detail destination** — the user opening the digest *is* the read signal. No "mark read" button anywhere.

### 3.2 `DigestDetailView` (must-build #2)

```swift
struct DigestDetailView: View {
    let digest: Digest
    @Environment(DigestStore.self) private var store
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {

                // Bottom line callout (opaque, tinted — not glass)
                if !digest.bottomLine.isEmpty {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Bottom line")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(digest.bottomLine)
                            .font(.crowlyDetailCallout)
                            .foregroundStyle(.primary)
                    }
                    .padding(Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.surface, style: .continuous)
                            .fill(Color.accentColor.opacity(0.08))
                    )
                }

                // Summary (prose body)
                if !digest.summary.isEmpty {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Summary")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(digest.summary)
                            .font(.body)
                            .foregroundStyle(.primary)
                    }
                }

                // Body sections (rendered in emitter order)
                if !digest.sections.isEmpty {
                    VStack(alignment: .leading, spacing: Space.l) {
                        ForEach(digest.sections) { s in
                            VStack(alignment: .leading, spacing: Space.s) {
                                Text(s.heading).font(.crowlySectionTitle)
                                Text(s.body).font(.body)
                            }
                        }
                    }
                }

                // Sources
                if !digest.sources.isEmpty {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Sources")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        ForEach(digest.sources) { src in
                            Button {
                                openURL(src.url)         // SFSafariViewController via UIApplication
                            } label: {
                                Label(src.title, systemImage: "arrow.up.right.square")
                                    .font(.callout)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.l)
        }
        .background(Color("crowly.background"))
        .navigationTitle(digest.title)
        .navigationBarTitleDisplayMode(.large)
        .navigationSubtitle(digest.subtitle)               // "Sun, Jun 29 · 7:00 PM · low"
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Spacer()
                Button {
                    store.archive(digest)
                    dismiss()
                } label: {
                    Label("Archive", systemImage: "tray.and.arrow.down")
                }
                // Plain system toolbar button — the toolbar itself is glass
                // chrome. Archive is the *only* action on this screen, so it
                // doesn't need a brand pill to compete with anything.
            }
        }
    }
}
```

**Notes on detail.**
- Order is locked: bottom line → summary → sections → sources. No reordering, no priority weighting.
- No "Mark read" button — opening this view is the read transition (handled by the inbox's `onAppear`).
- `⋯` menu is the *only* secondary surface; everything else is Archive.

### 3.3 `CrowlyWidgetEntryView` — `systemMedium` (must-build #3)

The marketing artifact. Two-to-three latest digests + unread count, one tap to read.

```swift
import WidgetKit
import SwiftUI

struct CrowlyWidgetEntryView: View {
    let entry: CrowlyEntry                          // contains latest digests + unread count

    @Environment(\.widgetFamily)        private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        switch family {
        case .systemMedium: mediumLayout
        case .systemSmall:  smallLayout
        case .systemLarge:  largeLayout                 // shipped 2026-07-02 (was a cut-target)
        default:            mediumLayout
        }
    }

    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            // Header: app id + unread count
            HStack(spacing: Space.s) {
                Image(systemName: "tray.full")
                    .widgetAccentable()
                Text("Crowly").font(.caption.weight(.semibold))
                Spacer()
                if entry.unreadCount > 0 {
                    Text("\(entry.unreadCount) unread")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .widgetAccentable()
                }
            }

            // Up to three latest digests
            VStack(spacing: Space.s) {
                ForEach(entry.latestDigests.prefix(3)) { d in
                    Link(destination: URL(string: "crowly://digest/\(d.id)")!) {
                        WidgetDigestRow(digest: d)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(Space.m)
        .containerBackground(for: .widget) { Color.clear }  // system renders glass beneath
    }

    private var smallLayout: some View {
        Link(destination: URL(string: entry.latestDigests.first.map { "crowly://digest/\($0.id)" } ?? "crowly://inbox")!) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack {
                    Image(systemName: "tray.full").widgetAccentable()
                    Spacer()
                    if entry.unreadCount > 0 {
                        Text("\(entry.unreadCount)").font(.headline).widgetAccentable()
                    }
                }
                Spacer(minLength: 0)
                if let latest = entry.latestDigests.first {
                    Text(latest.bottomLine)
                        .font(.subheadline)
                        .lineLimit(3)
                        .foregroundStyle(entry.unreadCount > 0 ? .primary : .secondary)
                } else {
                    Text("All clear.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Space.m)
            .containerBackground(for: .widget) { Color.clear }
        }
    }

    private var largeLayout: some View {                    // shipped M1 (2026-07-02): same header, up to 5 rows + a "View all N →" footer → crowly://inbox
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Image(systemName: "tray.full").widgetAccentable()
                Text("Crowly").font(.caption.weight(.semibold))
                Spacer()
                if entry.unreadCount > 0 {
                    Text("\(entry.unreadCount) unread")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .widgetAccentable()
                }
            }

            VStack(spacing: Space.s) {
                ForEach(entry.latestDigests.prefix(5)) { d in
                    Link(destination: URL(string: "crowly://digest/\(d.id)")!) {
                        WidgetDigestRow(digest: d)
                    }
                }
            }

            if entry.totalCount > 5 {
                Link(destination: URL(string: "crowly://inbox")!) {
                    Text("View all \(entry.totalCount) →")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(Space.m)
        .containerBackground(for: .widget) { Color.clear }
    }
}

struct WidgetDigestRow: View {
    let digest: WidgetDigestEntry
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme)         private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            // Job color stripe (suppressed in accented mode → goes white)
            RoundedRectangle(cornerRadius: 2)
                .fill(renderingMode == .accented
                      ? Color.white
                      : JobColor.color(for: digest.jobId, in: scheme))
                .frame(width: Space.xs, height: 36)
                .widgetAccentable()

            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.xs) {
                    Text(digest.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(digest.createdAt, format: .relative(presentation: .numeric))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(digest.bottomLine)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}
```

**Notes.**
- `.containerBackground(for: .widget) { Color.clear }` is the WidgetKit invariant for letting system glass show through.
- `widgetAccentable()` on the tray glyph, count badge, and job stripe → those go monochrome white in Accented mode while the body text tints cleanly.
- **The whole widget is `Link`s, not buttons.** A tap on a row deeplinks to that digest; a tap on the small widget deeplinks to its latest. There is no `Button(intent:)` anywhere in the widget — the reader has no actions to take from the home screen.
- Job color stripe gets explicitly replaced with white in accented mode; system tinting of arbitrary colors is unreliable for non-monochrome assets.

---

## 4. Accessibility, Dynamic Type, light/dark

These aren't an addendum — they're the design.

### 4.1 Dynamic Type

- **Every** font in the design system is `TextStyle`-based. No fixed `.system(size:)` in main flow surfaces.
- Cell `lineLimit(2)` on `bottom_line` is acceptable up to XXL; at AX1+ sizes the cell grows vertically — no special-casing needed because `List` is self-sizing.
- Widget rows use `.minimumScaleFactor(0.85)` on body text only (widget text can't reflow into more lines because the widget is fixed-size).

### 4.2 VoiceOver labels (per component)

| Element | Spoken |
|---|---|
| `UnreadDot` (unread) | "Unread" (or "Unread, urgent" / "Unread, high priority") |
| `UnreadDot` (read) | (empty — no element) |
| `UrgencyGlyph` (high) | "High priority" |
| `UrgencyGlyph` (urgent) | "Urgent" |
| `JobColorStripe` | Hidden — color is visual scanning only |
| `DigestCell` | Combined: title, unread state, urgency, bottom line. See `a11yLabel` in §2.4. |
| Sources link | Reads as the source title; trait `.isLink`. |

Combine the cell as one VoiceOver element via `.accessibilityElement(children: .combine)`; the tap target opens detail, which speaks the title on push.

### 4.3 Minimum tap targets

44 × 44 pt everywhere. Achieved via `frame(minHeight: 44)` on each `Button`'s label and `.contentShape(Rectangle())` on small visual elements that need wider hit zones. In the widget the digest rows span the full row width (≥44pt high in medium/large), and the small widget's whole surface is the tap target — both clear the HIG floor.

### 4.4 Motion & Reduce Motion

#### 4.4.1 Motion vocabulary & the governing rule

**Rich onboarding, calm everywhere else.** Crowly's motion philosophy is deliberately split (a design decision made with the owner, M2, branch `feat/onboarding-animations`):

- The **first-run onboarding carousel** is the one *rich* surface — staged element reveals, a morphing page indicator, a breathing `MeshGradient` field, a layered `KeyframeAnimator` crow, and a hero hand-off into the inbox. Motion carries the brand personality there because it's the one screen whose job is to make an impression. (Full behavior in `ux.md` § Onboarding.)
- The **reader — inbox, detail, widget — stays calm.** A dot vanish, a system row-removal, a widget timeline reload. No decorative motion, no custom transitions (§4.4.2). This is not an oversight; a reading queue earns trust by being quiet.

Timing lives in **one place** — the `Motion` enum in `Shared/Theme/Tokens.swift` — the same way color/spacing/type do. Never scatter inline `.snappy(…)` / `.spring(…)` literals at call sites; point them at a named curve. The vocabulary:

| Token | Curve | Used for |
|---|---|---|
| `Motion.pageAdvance` | `.snappy` | Crisp "something changed" — page advance, list updates |
| `Motion.press` | `.snappy(0.15)` | Button press-dim / scale (`CrowlyPrimaryButtonStyle`) |
| `Motion.settle` | `.snappy(0.25)` | A control settling — the page-indicator pill sliding between dots |
| `Motion.reveal` | `.spring(0.55, 0.82)` | Onboarding element entrance (hero → headline → divider → body) |
| `Motion.heroSettle` | `.spring(0.65, 0.9)` | The onboarding → inbox hero hand-off carry-through |
| `Motion.ambient` | `.easeInOut(2.2).repeatForever` | The crow's continuous ambient loop — **only** ever used gated on Reduce Motion |
| `Motion.stagger` / `Motion.revealDelay(_:)` | `0.08` s base | Per-element delay for a staggered reveal (element `n` at `n × stagger`) |

The calm surfaces reuse `press` / `settle`; onboarding layers on `reveal` / `heroSettle` / `ambient` / `stagger`. Adding a *new* rich-motion surface outside onboarding is a design change — flag it, don't just reach for these tokens.

#### 4.4.2 Reduce Motion

The consistent gate is **`Motion.maybe(_:reduceMotion:)`**, which returns `nil` (no animation) when the user has Reduce Motion on — one idiom rather than per-site `reduceMotion ? nil : …` ternaries. The onboarding motion, the page indicator, and `CrowlyPrimaryButtonStyle` all route through it; any *new* Reduce-Motion-sensitive animation should too.

- **Reader.** There are no decay animations — read state is a simple dot vanish, and Archive uses the system's default `List` row-removal (which honors Reduce Motion automatically); the undo toast slides on a `.snappy` transition. The reading queue is intentionally quiet.
- **Onboarding, all held / reduced under Reduce Motion:** the layered crow is rendered at rest (no per-frame keyframes), the `MeshGradient` field is static, the page-indicator pill moves instantly (no morph), staged reveals collapse to a plain cross-fade (no offset, no stagger), and the hero hand-off is skipped (the parent's opacity cross-fade still runs, so the flow always completes). Rich onboarding never comes at accessibility's expense.

### 4.5 Light-locked (no dark inversion)

**The app is light-locked by design.** `CrowlyApp.swift` applies `.preferredColorScheme(.light)` at the scene root, so the identity — cream field, ink text, orange accent — is the same on every device regardless of system appearance. There is no dark palette; there is no adaptive asset catalog. This is a deliberate identity decision (2026-07-02 redesign), not an omission.

Per-screen spot checks:

- **Inbox.** Backdrop `Brand.cream` `#FEF8F1`; cell `Brand.paper` `#FFFDFA`. Job stripe stays visible because the FNV-1a algorithm's fixed S/L was picked for legibility on the cream field.
- **Detail.** Same surface tokens. Bottom-line callout is `Brand.orange @ 0.08` on paper — a warm tinted band that reads as chrome, not text.
- **Widget.** Background is **system-managed** (glass), so light/dark/Accented all flow from `Color.clear` containerBackground. The widget itself follows the brand: cream/paper rows, ink text, orange stripes. Stripes get an explicit accented-mode override (§3.3) — system tinting of arbitrary colors is unreliable for non-monochrome assets.

**Widget note.** Because the widget lives on the user's home screen it *does* observe the system `colorScheme`, but its background is Clear-over-glass and its cell content uses the same fixed Brand palette; there is no separate dark styling to maintain.

**Accessibility still works.** Light-locked isn't the same as inaccessible: Dynamic Type, VoiceOver, Increased Contrast, Reduce Motion all still function (they're orthogonal to color scheme). Smart Invert and Classic Invert will invert colors — that's an OS-level accessibility feature, and the app doesn't fight it. `.accessibilityIgnoresInvertColors()` is *not* applied globally, so users who need inversion get it from the system.

### 4.6 Increased Contrast

`.accessibilityShowsButtonShapes` (handled by the system on glass button styles). When the system requests increased contrast, the bottom-bar Archive button's text weight bumps from `.medium` to `.semibold` via the environment:

```swift
@Environment(\.legibilityWeight) private var legibilityWeight
.font(.body.weight(legibilityWeight == .bold ? .semibold : .medium))
```

---

## Why this matches Apple docs (anchors for the coder's review)

- Liquid Glass is used for system chrome only (nav bar, bottom toolbar, demo banner via `.glassEffect(.regular.tint:)`); *primary* CTAs are the brand pill (`CrowlyPrimaryButtonStyle`) — a deliberate departure from `.buttonStyle(.glass)` for primary actions, per Apple's *Implementing Liquid Glass Design in SwiftUI* (custom button styles remain a first-class citizen).
- Widget rendering modes, `widgetAccentable()`, and `.containerBackground(for: .widget) { Color.clear }` follow *Implementing Liquid Glass Design in Widgets* (Accented vs Full Color).
- Bottom-bar action layout in detail follows *SwiftUI New Toolbar Features* (`ToolbarItemGroup(placement: .bottomBar)`).
- Read-only widgets with `Link` deeplinks follow the WidgetKit guidance for static-information widgets (in contrast to interactive `Button(intent:)` widgets, which are deliberately out of scope here).
- `.preferredColorScheme(.light)` at the scene root is the sanctioned way to opt out of dark-mode adaptation, per SwiftUI's `preferredColorScheme` documentation.

## Pitfalls (read before building)

- **Don't put `.glassEffect()` on the cell.** It will trash legibility against busy wallpapers and miss the invariant entirely. Cell = opaque, always.
- **Don't reach for `Color(red:green:blue:)` at a call site.** Literal sRGB values live *only* in the `Brand` enum. Everywhere else uses semantic tokens (`Color.crowlyInk`, `.crowlyAccent`, `Brand.orange` when the code is inside `Shared/Theme/`).
- **Don't re-introduce a dark palette or an adaptive asset catalog.** The light lock is a deliberate identity decision; changing it is a design change, not a refactor.
- **Don't use `String.hashValue` for job color.** It's seeded per process; you'll get different colors after every relaunch. The FNV-1a implementation in §1.1.2 is non-negotiable.
- **Don't gate `[iOS 26]` APIs now.** M1 target is iOS 26 — gates add noise. They go in for M2 when the public target may drop.
- **Don't use `.buttonStyle(.glass)` / `.glassProminent` for a primary CTA.** The brand pill (`.buttonStyle(.crowlyPrimary)`) is the *only* primary style. Glass on primary actions was the pre-2026-07-02 look.
- **Don't add buttons to the widget.** The widget is `Link`-only. Buttons in a reader widget invite the question "what does this do?" — and the answer should always be "open the app to read it."
- **Don't add a third unread state.** "Snoozed", "muted-but-open", etc., are M2. Two states (unread / not-unread) keep the cell scannable.
- **Don't reorder by urgency.** Urgency drives widget surfacing and the urgency glyph; the inbox is strictly chronological.
