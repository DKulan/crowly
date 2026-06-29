# Design System (M1)

The implementation-ready visual design system for the Crowly M1 iOS app and `systemMedium` interactive widget. This doc realizes the interaction spec in [`ux.md`](ux.md), renders the contract in [`schema.md`](schema.md), and respects the routing model in [`architecture.md`](architecture.md). It is opinionated, Apple-native, and intended to be built from directly — the coder will adapt these sketches, but the tokens, components, and screen hierarchies are decisions, not options.

## Scope & constraints (locked)

- **Deployment target: iOS 26.** Liquid Glass APIs (`.glassEffect()`, `GlassEffectContainer`, `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)`) are usable freely. Each API site that requires iOS 26 is flagged inline as `[iOS 26]` so M2 (potentially lower minimum) can `@available`-gate later. Do not add gates now.
- **Demo Mode first.** Every component renders entirely from canned model values; nothing here depends on a live companion or network.
- **The triad is the product:** (1) Inbox list cell, (2) Digest detail view, (3) `systemMedium` widget entry. Everything else exists to serve these three.
- **Liquid Glass for chrome, not content.** Toolbars, the widget surface, and answer buttons get glass; digest cards and detail body stay opaque so prose is legible against any wallpaper or beneath glass chrome.

---

## 1. Design tokens

### 1.1 Semantic colors

Defined as `Color` extensions backed by an Asset Catalog with `light` and `dark` variants. Use the **semantic name** at the call site — never raw hex, never `Color(red:green:blue:)` outside the asset catalog. Hex values below are the canonical light/dark pairs; the asset catalog mirrors them.

| Semantic name | Light | Dark | Where used |
|---|---|---|---|
| `crowly.background` | `#F2F2F7` (systemGroupedBackground) | `#000000` | Inbox list backdrop, settings root |
| `crowly.surface` | `#FFFFFF` | `#1C1C1E` (secondarySystemGroupedBackground) | Digest cell + detail card fills (opaque, by rule) |
| `crowly.surface.elevated` | `#FFFFFF` | `#2C2C2E` | Bottom-bar buttons not on glass, sheets |
| `crowly.label` | `#000000` (label) | `#FFFFFF` | Primary text |
| `crowly.label.secondary` | `#3C3C43` @ 0.60 | `#EBEBF5` @ 0.60 | Timestamps, meta, sub-labels (== `Color.secondary`) |
| `crowly.label.tertiary` | `#3C3C43` @ 0.30 | `#EBEBF5` @ 0.30 | Disabled glyphs, separators |
| `crowly.separator` | `#3C3C43` @ 0.36 | `#54545899` | Hairlines |
| `crowly.accent` | `#0A84FF` (systemBlue) | `#0A84FF` | Tint, status-dot unread fill, primary verbs |
| `crowly.success` | `#34C759` | `#30D158` | "Mark handled" swipe, resolution success glyph |
| `crowly.warning` | `#FF9F0A` | `#FF9F0A` | "Mute job" swipe |
| `crowly.destructive` | `#FF3B30` | `#FF453A` | Reserved (M2; M1 doesn't destroy) |
| `crowly.muted` | `#8E8E93` (systemGray) | `#8E8E93` | "Archive" swipe, archived-state status dot |

> **Rule:** all foreground text on cards uses `Color.primary`/`.secondary` so Dynamic Type + Smart Invert + Increased Contrast inherit for free.

#### 1.1.1 Urgency colors

Maps `digest.urgency` → an accent used only on the status dot and the widget's urgency rail. Body text never tints by urgency (legibility).

| `urgency` | Color | SF Symbol cue |
|---|---|---|
| `low` | `crowly.label.tertiary` (subtle) | none |
| `normal` | `crowly.accent` | none |
| `high` | `crowly.warning` | `exclamationmark` (small, leading the timestamp) |
| `urgent` | `crowly.destructive` | `exclamationmark.2` |

```swift
extension Color {
    static func urgency(_ u: Urgency) -> Color {
        switch u {
        case .low:    .secondary.opacity(0.5)
        case .normal: .accentColor
        case .high:   Color("crowly.warning")
        case .urgent: Color("crowly.destructive")
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

#### 1.1.3 Status-dot states (four; never a badge stack)

`StatusDot` is the single source of truth for cell read/handled/archived state. Per `ux.md` § Inbox.

| State | Fill | Stroke | Diameter | Notes |
|---|---|---|---|---|
| `unread` | `.accentColor` filled | none | 10pt | Digest hasn't been opened |
| `readOpen` | `Color.clear` | `.accentColor` 1.5pt ring | 10pt | Opened but has ≥1 open loop |
| `handled` | `Color.secondary` filled | none | 10pt | All loops handled or pure-info digest |
| `archived` | n/a | n/a | hidden | Cell lives in Archive section; dot is not rendered |

Per-urgency tinting layers on top: if `digest.urgency >= .high` and state is `unread`, the dot inherits `Color.urgency(digest.urgency)` instead of `.accentColor` (one signal, not two badges).

### 1.2 Typography

Map every text role to a `Font.TextStyle` — never a fixed point size — so Dynamic Type scales the whole app for free.

| Token | TextStyle | Weight | Used for |
|---|---|---|---|
| `title.large` | `.largeTitle` | `.bold` | Navigation title (large) on Inbox + Detail |
| `title.section` | `.title2` | `.semibold` | Section headers in Detail ("Questions", "Action items") |
| `title.cell` | `.headline` | `.semibold` (default) | Digest cell title |
| `body.lead` | `.body` | `.regular` | Cell `bottom_line`, detail body |
| `body.callout` | `.callout` | `.regular` | Detail "Bottom line" callout block |
| `body.question` | `.body` | `.medium` | Question text in detail + widget |
| `meta` | `.footnote` | `.regular` | Cell timestamp, secondary meta |
| `chip` | `.caption` | `.medium` | Intent chips on cell + meta in detail |
| `chip.small` | `.caption2` | `.medium` | Cell intent-chip counts |
| `mono.id` | `.caption2.monospaced()` | `.regular` | Debug surfaces / Settings only — never in main flow |

```swift
extension Font {
    static let crowlyCellTitle:    Font = .headline
    static let crowlyCellBody:     Font = .body
    static let crowlyChip:         Font = .caption.weight(.medium)
    static let crowlyChipSmall:    Font = .caption2.weight(.medium)
    static let crowlyDetailQ:      Font = .body.weight(.medium)
    static let crowlyDetailCallout: Font = .callout
}
```

Line limits: cell `bottom_line` is `lineLimit(2)` with `.truncationMode(.tail)`. Question text in cells is **never truncated** below the chip row — if the cell's `bottom_line` is empty (rare), the question text replaces it.

### 1.3 Spacing & corner radii

Eight-pt-grid; same scale everywhere.

| Token | pt | Used for |
|---|---|---|
| `space.xs` | 4 | Job stripe width, intra-chip padding |
| `space.s` | 8 | Cell vertical rhythm between rows |
| `space.m` | 12 | Cell horizontal padding, section gutter |
| `space.l` | 16 | Card insets, button cluster spacing |
| `space.xl` | 24 | Section break in detail |
| `space.xxl` | 32 | Detail-view top-of-section breathing room |

| Token | pt | Used for |
|---|---|---|
| `radius.chip` | 999 (`Capsule`) | Intent chips, answer buttons, route buttons |
| `radius.card` | 14 | Inbox cell card surround, callout block |
| `radius.surface` | 18 | Sheet handles, detail callout |
| `radius.widget.row` | 12 | Widget row backgrounds (where used) |

```swift
enum Space { static let xs:CGFloat=4, s:CGFloat=8, m:CGFloat=12,
                  l:CGFloat=16, xl:CGFloat=24, xxl:CGFloat=32 }
enum Radius { static let card:CGFloat=14, surface:CGFloat=18, widgetRow:CGFloat=12 }
```

Minimum tap target: **44pt × 44pt** everywhere (HIG). Visual size may be smaller; `.contentShape(Rectangle())` extends the hit region.

### 1.4 Liquid Glass usage rules

The product invariant: **glass = chrome; opaque = content.** Decision rules below; if a surface isn't on the table, default to opaque.

| Surface | Treatment | Why |
|---|---|---|
| Navigation bar | System default (glass) | Apple-native; no override |
| Bottom toolbar (`.bottomBar`) | System default (glass) | Apple-native |
| Answer buttons (`Yes` / `No`) | `.buttonStyle(.glassProminent)` (affirmative) + `.buttonStyle(.glass)` (dismissive) `[iOS 26]` | The bound-loop affordance — light, tactile, monochromes well in widget Accented mode |
| Route buttons ("Add as task" etc.) | `.buttonStyle(.glass)` `[iOS 26]` | Same family as answers; secondary action role |
| Widget background | `.containerBackground(for: .widget) { Color.clear }` so system renders glass beneath | WidgetKit invariant |
| Widget answer cluster | `GlassEffectContainer` wrapping the buttons `[iOS 26]` | Lets the two answers visually merge under one glass volume |
| Cell card | **Opaque** `crowly.surface` | Prose legibility; `bottom_line` reads against any wallpaper |
| Detail body | **Opaque** `crowly.surface` callout | Same reason |
| Detail "Bottom line" callout | Opaque tinted block — `.background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: Radius.surface))` | Visual emphasis without glass; legible |
| Demo-mode banner | `.glassEffect(.regular.tint(.orange))` `[iOS 26]` in a Capsule | Chrome on top of inbox; tint signals "not real data" |

**Two hard rules** (changing either is a design change):

1. **Never put `.glassEffect()` on a view that owns the main reading text** — cell title, `bottom_line`, question text, summary. Glass-behind-prose fails the legibility bar against busy wallpapers.
2. **Always use `GlassEffectContainer`** when ≥2 glass views sit within `space.l` of each other (answer pair, route-button cluster, widget button cluster). Single-glass uses don't need it.

---

## 2. Component inventory

Each entry: purpose · props · states · SwiftUI sketch. Sketches are real code — adapt for naming/file layout but keep the modifier order and the binding shape.

### 2.1 `StatusDot`

**Purpose.** The four-state read indicator on every cell. Single source of truth.

**Props.**
```swift
struct StatusDot: View {
    enum State { case unread, readOpen, handled, archived }
    let state: State
    var urgency: Urgency = .normal   // tints unread state when .high/.urgent
}
```

**States.** See §1.1.3.

**Sketch.**
```swift
struct StatusDot: View {
    let state: State
    var urgency: Urgency = .normal

    var body: some View {
        Group {
            switch state {
            case .unread:
                Circle().fill(unreadColor)
            case .readOpen:
                Circle().strokeBorder(Color.accentColor, lineWidth: 1.5)
            case .handled:
                Circle().fill(Color.secondary)
            case .archived:
                EmptyView()
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityLabel(a11yLabel)
        .accessibilityAddTraits(state == .unread ? .isHeader : [])
    }

    private var unreadColor: Color {
        urgency == .high || urgency == .urgent ? .urgency(urgency) : .accentColor
    }

    private var a11yLabel: String {
        switch state {
        case .unread:   "Unread\(urgency == .urgent ? ", urgent" : urgency == .high ? ", high priority" : "")"
        case .readOpen: "Read, has open items"
        case .handled:  "Handled"
        case .archived: ""
        }
    }
}
```

### 2.2 `IntentChip`

**Purpose.** A pill that says "this cell has N open items of intent X." Vanishes at zero — the "did the work" decay.

**Props.**
```swift
struct IntentChip: View {
    let intent: Intent       // .task | .note | .followup | .none | .terminal
    let openCount: Int
    var style: Style = .cell // .cell (count + symbol) | .detail (verb + symbol)
}
```

**States.**
- `openCount == 0` → returns `EmptyView()` (caller responsibility to filter, but defensive)
- `openCount > 0` → shows `[symbol] \(count) \(intent.noun)` ("1 question", "2 tasks")
- Tinted variant when intent has `urgency >= .high` (drives the cell's eye-line)

**Sketch.**
```swift
struct IntentChip: View {
    let intent: Intent
    let openCount: Int
    var style: Style = .cell

    var body: some View {
        if openCount == 0 { EmptyView() }
        else {
            Label {
                Text(label)
                    .font(.crowlyChipSmall)
            } icon: {
                Image(systemName: intent.symbol)
                    .font(.crowlyChipSmall)
            }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs)
            .background(
                Capsule().fill(Color.secondary.opacity(0.10))
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(openCount) open \(intent.noun(pluralFor: openCount))")
        }
    }

    private var label: String {
        switch style {
        case .cell:   "\(openCount) \(intent.noun(pluralFor: openCount))"
        case .detail: intent.verb
        }
    }
}
```

`Intent` lives in §5 — single source of truth.

### 2.3 `RouteButton`

**Purpose.** The route-aware verb button for action items (in detail and via a `RouteResolver`-driven label). Capability-aware: hidden if `resolver.isAvailable(intent) == false` — never greyed.

**Props.**
```swift
struct RouteButton: View {
    let resolution: RouteResolution   // {verb, sublabel, symbol, intent, enabled}
    let action: () -> Void
    var prominence: Prominence = .secondary   // .primary (answer) | .secondary (route)
}
```

**States.**
- `enabled == false && resolution.intent != .terminal` → **not rendered** (caller drops it). Terminal "Log in inbox" always renders.
- Pressed → standard glass press feedback (`.glassEffect(.regular.interactive())` on the button via `.buttonStyle(.glass)`).
- Post-action → callers transition to `ResolutionPreview` ("Saved as note").

**Sketch.**
```swift
struct RouteButton: View {
    let resolution: RouteResolution
    let action: () -> Void
    var prominence: Prominence = .secondary

    var body: some View {
        Button(action: action) {
            Label {
                Text(resolution.verb)
                    .font(.body.weight(.medium))
            } icon: {
                Image(systemName: resolution.symbol)
            }
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(prominence == .primary ? .glassProminent : .glass) // [iOS 26]
        .controlSize(.large)
        .accessibilityHint(resolution.sublabel ?? "")
    }
}
```

### 2.4 `ResolutionPreview`

**Purpose.** Renders "Will create a Todoist task" beneath an answer button — the affordance that earns trust in the bound loop. Computed by the single `RouteResolver`; the same view renders pre-tap previews and post-tap confirmations.

**Props.**
```swift
struct ResolutionPreview: View {
    enum Mode { case willResolve, didResolve, failed }
    let mode: Mode
    let resolution: RouteResolution
}
```

**States.**
- `.willResolve` → `Image(systemName: resolution.symbol).foregroundStyle(.secondary)` + "Will \(resolution.verb.lowercased())…"
- `.didResolve` → `Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)` + "Answered: yes — \(resolution.confirmation)"
- `.failed`     → `Image(systemName: "arrow.clockwise").foregroundStyle(.orange)` + "Tap to retry"

**Sketch.**
```swift
struct ResolutionPreview: View {
    let mode: Mode
    let resolution: RouteResolution

    var body: some View {
        Label {
            Text(text).font(.footnote)
        } icon: {
            Image(systemName: symbol).font(.footnote)
        }
        .foregroundStyle(color)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityLabel(text)
    }

    private var symbol: String {
        switch mode {
        case .willResolve: resolution.symbol
        case .didResolve:  "checkmark.circle.fill"
        case .failed:      "arrow.clockwise"
        }
    }
    private var color: Color {
        switch mode {
        case .willResolve: .secondary
        case .didResolve:  .green
        case .failed:      .orange
        }
    }
    private var text: String {
        switch mode {
        case .willResolve: "Will \(resolution.verb.lowercased())"
        case .didResolve:  "Answered — \(resolution.confirmation)"
        case .failed:      "Tap to retry"
        }
    }
}
```

### 2.5 `OpenLoopGlyph`

**Purpose.** The leading glyph on each open-loop row in detail and widget. Per the invariant in `ux.md`: **shape stays put — only fill changes** so resolution decay is visible without redrawing.

**Props.**
```swift
struct OpenLoopGlyph: View {
    enum Kind { case question, action }
    let kind: Kind
    let isResolved: Bool
}
```

**States.**
- `question, !resolved` → `questionmark.circle` outlined, `.accentColor`
- `question,  resolved` → `questionmark.circle.fill`, `.secondary`
- `action,   !resolved` → `circle`, `.accentColor`
- `action,    resolved` → `checkmark.circle.fill`, `.secondary`

**Sketch.**
```swift
struct OpenLoopGlyph: View {
    let kind: Kind
    let isResolved: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.title3)                        // scales with Dynamic Type
            .foregroundStyle(isResolved ? .secondary : .accentColor)
            .symbolRenderingMode(.hierarchical)
            .accessibilityHidden(true)            // the row label carries semantics
    }

    private var symbol: String {
        switch (kind, isResolved) {
        case (.question, false): "questionmark.circle"
        case (.question, true):  "questionmark.circle.fill"
        case (.action,   false): "circle"
        case (.action,   true):  "checkmark.circle.fill"
        }
    }
}
```

### 2.6 `JobColorStripe`

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

### 2.7 `DigestCell`

**Purpose.** The inbox row — composes everything above. The first must-build of the triad.

**Props.**
```swift
struct DigestCell: View {
    let digest: Digest
    let openLoopCounts: [Intent: Int]   // computed from action_items + open questions
    let state: StatusDot.State
}
```

**States.** Inherits from `StatusDot`. Long-press / swipe states are handled by `swipeActions` on the enclosing `List`.

**Sketch.**
```swift
struct DigestCell: View {
    let digest: Digest
    let openLoopCounts: [Intent: Int]
    let state: StatusDot.State

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
                    StatusDot(state: state, urgency: digest.urgency)
                }

                // Meta row
                HStack(spacing: Space.xs) {
                    if digest.urgency == .high || digest.urgency == .urgent {
                        Image(systemName: digest.urgency == .urgent
                              ? "exclamationmark.2" : "exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(Color.urgency(digest.urgency))
                            .accessibilityHidden(true)
                    }
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

                // Intent chips (open-loop strip) — only renders non-zero counts.
                if hasAnyOpenChips {
                    HStack(spacing: Space.s) {
                        ForEach(Intent.cellOrdering, id: \.self) { intent in
                            if let count = openLoopCounts[intent], count > 0 {
                                IntentChip(intent: intent, openCount: count)
                            }
                        }
                    }
                    .padding(.top, Space.xs)
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

    private var hasAnyOpenChips: Bool {
        openLoopCounts.values.contains { $0 > 0 }
    }

    private var a11yLabel: String {
        var parts = [digest.title]
        parts.append(state.a11y)
        if digest.urgency >= .high { parts.append("\(digest.urgency.rawValue) priority") }
        parts.append(digest.bottomLine)
        let chips = openLoopCounts
            .filter { $0.value > 0 }
            .map { "\($0.value) open \($0.key.noun(pluralFor: $0.value))" }
        parts.append(contentsOf: chips)
        return parts.joined(separator: ". ")
    }
}
```

---

## 3. The triad — concrete screens

All three sketches assume canned demo data flowing through a `DigestStore` (an `@Observable` view-model) with `Digest`, `Question`, `ActionItem`, and `RouteResolution` types mirroring `schema.md`. No backend in M1's first runnable milestone.

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
                                    openLoopCounts: store.openLoopCounts(for: digest),
                                    state: store.statusDotState(for: digest)
                                )
                            }
                            .listRowInsets(EdgeInsets(
                                top: Space.xs, leading: Space.m,
                                bottom: Space.xs, trailing: Space.m))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    store.markHandled(digest)
                                } label: {
                                    Label("Mark handled", systemImage: "checkmark.circle")
                                }
                                .tint(.green)
                            }
                            .swipeActions(edge: .trailing) {
                                Button {
                                    store.archive(digest)
                                } label: {
                                    Label("Archive", systemImage: "tray.and.arrow.down")
                                }
                                .tint(.gray)

                                Button {
                                    store.muteJob(digest.jobId)
                                } label: {
                                    Label("Mute job", systemImage: "bell.slash")
                                }
                                .tint(.orange)
                            }
                        }
                    } header: {
                        Text(section.title)            // Today / Yesterday / This week / Earlier
                            .font(.crowlyChip)
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

                // Open loops: questions first
                if !digest.questions.isEmpty {
                    SectionHeader(title: "Questions",
                                  badge: "\(digest.openQuestions.count) open")
                    VStack(spacing: Space.l) {
                        ForEach(digest.questions) { q in
                            QuestionRow(question: q, digestId: digest.id)
                        }
                    }
                }

                // Action items
                if !digest.actionItems.isEmpty {
                    SectionHeader(title: "Action items",
                                  badge: "\(digest.openActions.count)")
                    VStack(spacing: Space.l) {
                        ForEach(digest.actionItems) { a in
                            ActionItemRow(action: a, digestId: digest.id)
                        }
                    }
                }

                // Body sections
                if !digest.sections.isEmpty {
                    VStack(alignment: .leading, spacing: Space.l) {
                        ForEach(digest.sections) { s in
                            VStack(alignment: .leading, spacing: Space.s) {
                                Text(s.heading).font(.crowlyCellTitle)
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
                Button {
                    store.markHandled(digest)
                } label: {
                    Label("Mark handled", systemImage: "checkmark.circle")
                }
                ToolbarSpacer(.flexible)
                Button {
                    store.archive(digest)
                } label: {
                    Label("Archive", systemImage: "tray.and.arrow.down")
                }
                ToolbarSpacer(.fixed)
                Menu {
                    Button("Mute job", systemImage: "bell.slash") { store.muteJob(digest.jobId) }
                    Button("Open as JSON", systemImage: "curlybraces") { /* debug surface */ }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }
}
```

#### `SectionHeader`
```swift
struct SectionHeader: View {
    let title: String
    var badge: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.weight(.semibold))
            if let badge {
                Text(badge)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
```

#### `QuestionRow` (yes_no — the must-build path)

```swift
struct QuestionRow: View {
    let question: Question
    let digestId: Digest.ID
    @Environment(DigestStore.self) private var store
    @Namespace private var glassNamespace

    private var answer: AnswerState { store.answerState(for: question.id) }
    private var yesResolution: RouteResolution { store.resolution(forAnswer: "yes", of: question) }
    private var noResolution:  RouteResolution { store.resolution(forAnswer: "no",  of: question) }

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            OpenLoopGlyph(kind: .question, isResolved: answer.isResolved)

            VStack(alignment: .leading, spacing: Space.s) {
                Text(question.text).font(.crowlyDetailQ)

                switch question.replyKind {
                case .yesNo:
                    if !answer.isResolved {
                        GlassEffectContainer(spacing: Space.s) {       // [iOS 26]
                            HStack(spacing: Space.s) {
                                Button {
                                    store.answer(question, value: "yes")
                                } label: {
                                    Text("Yes")
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .buttonStyle(.glassProminent)          // [iOS 26]

                                Button {
                                    store.answer(question, value: "no")
                                } label: {
                                    Text("No")
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .buttonStyle(.glass)                   // [iOS 26]
                            }
                        }
                        // Pre-tap consequence preview (the trust affordance)
                        ResolutionPreview(mode: .willResolve, resolution: yesResolution)
                            .padding(.top, Space.xs)
                    } else {
                        ResolutionPreview(
                            mode: answer.failed ? .failed : .didResolve,
                            resolution: answer.value == "yes" ? yesResolution : noResolution
                        )
                    }

                case .choice(let options):
                    VStack(spacing: Space.s) {
                        ForEach(options, id: \.self) { opt in
                            let res = store.resolution(forAnswer: opt, of: question)
                            Button { store.answer(question, value: opt) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(opt).font(.body.weight(.medium))
                                    Text("Will \(res.verb.lowercased())")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, Space.s)
                                .padding(.horizontal, Space.m)
                            }
                            .buttonStyle(.glass)                       // [iOS 26]
                        }
                    }

                case .freeText:
                    Button("Reply…") { store.openFreeTextSheet(for: question) }
                        .buttonStyle(.glass)                            // [iOS 26]
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: answer.isResolved)   // honors reduce-motion below
        .accessibilityElement(children: .contain)
    }
}
```

#### `ActionItemRow`

```swift
struct ActionItemRow: View {
    let action: ActionItem
    let digestId: Digest.ID
    @Environment(DigestStore.self) private var store

    private var state: ActionState { store.actionState(for: action.id) }
    private var resolution: RouteResolution { store.resolution(for: action) }

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            OpenLoopGlyph(kind: .action, isResolved: state.isResolved)

            VStack(alignment: .leading, spacing: Space.s) {
                Text(action.text).font(.body)

                if !action.hintsChips.isEmpty {
                    HStack(spacing: Space.s) {
                        ForEach(action.hintsChips, id: \.self) { hint in
                            Text(hint)
                                .font(.crowlyChip)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, Space.s)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.10)))
                        }
                    }
                }

                if !state.isResolved {
                    HStack(spacing: Space.s) {
                        RouteButton(resolution: resolution) {
                            store.executeAction(action)
                        }
                        if resolution.hasOverrides {
                            Menu {
                                Button("Edit project…", systemImage: "folder") { /* overrides */ }
                                Button("Edit due…",     systemImage: "calendar") { /* overrides */ }
                                Button("Edit labels…",  systemImage: "tag") { /* overrides */ }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.glass)                        // [iOS 26]
                        }
                    }
                } else {
                    ResolutionPreview(mode: .didResolve, resolution: resolution)
                }
            }
        }
    }
}
```

### 3.3 `CrowlyWidgetEntryView` — `systemMedium` (must-build #3)

The marketing artifact. Two open loops + `yes_no` buttons, one tap from home.

```swift
import WidgetKit
import SwiftUI
import AppIntents

struct CrowlyWidgetEntryView: View {
    let entry: CrowlyEntry                          // contains up to 2 open loops + total count

    @Environment(\.widgetFamily)        private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        switch family {
        case .systemMedium: mediumLayout
        case .systemSmall:  smallLayout
        case .systemLarge:  largeLayout                 // M1 cut-target; see ux.md cut order
        default:            mediumLayout
        }
    }

    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            // Header: app id + total open count
            HStack(spacing: Space.s) {
                Image(systemName: "tray.full")
                    .widgetAccentable()
                Text("Crowly").font(.caption.weight(.semibold))
                Spacer()
                if entry.totalOpenLoops > 2 {
                    Text("\(entry.totalOpenLoops) open")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .widgetAccentable()
                }
            }

            // Up to two open loops
            VStack(spacing: Space.s) {
                ForEach(entry.openLoops.prefix(2)) { loop in
                    WidgetLoopRow(loop: loop)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(Space.m)
        .containerBackground(for: .widget) { Color.clear }  // system renders glass beneath
    }

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Image(systemName: "tray.full").widgetAccentable()
                Spacer()
                Text("\(entry.totalOpenLoops)").font(.headline).widgetAccentable()
            }
            Spacer(minLength: 0)
            if let top = entry.openLoops.first {
                Text(top.text)
                    .font(.subheadline)
                    .lineLimit(2)
                if top.kind == .question, case .yesNo = top.replyKind {
                    GlassEffectContainer(spacing: 6) {            // [iOS 26]
                        HStack(spacing: 6) {
                            yesButton(for: top, compact: true)
                            noButton(for: top, compact: true)
                        }
                    }
                } else {
                    Text("Open Crowly to act").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text(entry.latestBottomLine ?? "All clear.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(Space.m)
        .containerBackground(for: .widget) { Color.clear }
    }

    private var largeLayout: some View { mediumLayout }    // ux.md cut order: large is cut if M1 slips
}

struct WidgetLoopRow: View {
    let loop: OpenLoopEntry
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme)         private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            // Job color stripe (suppressed in accented mode → goes white)
            RoundedRectangle(cornerRadius: 2)
                .fill(renderingMode == .accented
                      ? Color.white
                      : JobColor.color(for: loop.jobId, in: scheme))
                .frame(width: Space.xs, height: 36)
                .widgetAccentable()

            VStack(alignment: .leading, spacing: Space.xs) {
                Text(loop.text)
                    .font(.caption)
                    .lineLimit(2)
                if loop.kind == .question, case .yesNo = loop.replyKind {
                    GlassEffectContainer(spacing: 6) {            // [iOS 26]
                        HStack(spacing: 6) {
                            yesButton(for: loop, compact: true)
                            noButton(for: loop, compact: true)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }
}

@inline(__always)
private func yesButton(for loop: OpenLoopEntry, compact: Bool) -> some View {
    Button(intent: AnswerQuestionIntent(
        digestId: loop.digestId, questionId: loop.questionId, value: "yes"
    )) {
        Text("Yes")
            .font(.caption.weight(.semibold))
            .frame(minWidth: 44, minHeight: 28)
    }
    .buttonStyle(.glassProminent)                                  // [iOS 26]
}

@inline(__always)
private func noButton(for loop: OpenLoopEntry, compact: Bool) -> some View {
    Button(intent: AnswerQuestionIntent(
        digestId: loop.digestId, questionId: loop.questionId, value: "no"
    )) {
        Text("No")
            .font(.caption.weight(.semibold))
            .frame(minWidth: 44, minHeight: 28)
    }
    .buttonStyle(.glass)                                           // [iOS 26]
}
```

**Notes.**
- `.containerBackground(for: .widget) { Color.clear }` is the WidgetKit invariant for letting system glass show through.
- `widgetAccentable()` on the tray glyph, count badge, and job stripe → those go monochrome white in Accented mode while the buttons (glass-styled) cleanly tint.
- `Button(intent:)` runs `AnswerQuestionIntent` **without launching the app**; the intent calls `WidgetCenter.shared.reloadTimelines(ofKind:)` after the POST so the row vanishes within a beat.
- Job color stripe gets explicitly replaced with white in accented mode; system tinting of arbitrary colors is unreliable for non-monochrome assets.

---

## 4. Accessibility, Dynamic Type, light/dark

These aren't an addendum — they're the design.

### 4.1 Dynamic Type

- **Every** font in the design system is `TextStyle`-based. No fixed `.system(size:)` in main flow surfaces.
- Cell `lineLimit(2)` on `bottom_line` is acceptable up to XXL; at AX1+ sizes the cell grows vertically — no special-casing needed because `List` is self-sizing.
- Intent chip row wraps when chips exceed the available width; do **not** use `lineLimit(1)` on chips themselves. The cell uses `Layout`-aware `HStack(spacing: Space.s)` that flows via SwiftUI's natural sizing.
- Widget rows use `.minimumScaleFactor(0.85)` on body text only (widget text can't reflow into more lines because the widget is fixed-size). Buttons stay at their declared size.

### 4.2 VoiceOver labels (per component)

| Element | Spoken |
|---|---|
| `StatusDot` (unread) | "Unread" (or "Unread, urgent" / "Unread, high priority") |
| `StatusDot` (readOpen) | "Read, has open items" |
| `StatusDot` (handled) | "Handled" |
| `IntentChip` | "{count} open {task/question/note/followup}", e.g., "2 open tasks" |
| `OpenLoopGlyph` | Hidden — the row label carries semantics |
| `JobColorStripe` | Hidden — color is visual scanning only |
| Answer button (Yes) | "Yes. Hint: {sublabel}." e.g., "Yes. Hint: Will create a task." |
| Answer button (No) | "No. Hint: {sublabel}." |
| `RouteButton` | "{verb}. Hint: {sublabel}." |
| `ResolutionPreview` (didResolve) | "Answered. {confirmation}." Announced via `.accessibilityLabel` change so VoiceOver speaks it on state transition. |
| `DigestCell` | Combined: title, state, urgency, bottom line, then chip counts. See `a11yLabel` in §2.7. |

Combine the cell as one VoiceOver element via `.accessibilityElement(children: .combine)`; navigating inside the cell is achieved by the focusable button/glyph children when needed (`.combine` keeps them adjustable).

### 4.3 Minimum tap targets

44 × 44 pt everywhere. Achieved via `frame(minHeight: 44)` on each `Button`'s label and `.contentShape(Rectangle())` on small visual elements that need wider hit zones. In the widget the answer buttons use `minWidth: 44, minHeight: 28` because the widget cap on row height forces 28pt; this is acceptable because the buttons span half the row width and gain hit slop from glass styling.

### 4.4 Reduce Motion

The "did the work" decay is a **fill change**, not motion — `OpenLoopGlyph` simply swaps `circle` for `circle.fill` and tints to `.secondary`. With Reduce Motion off it cross-fades via the implicit `withAnimation(.snappy)` in `QuestionRow` / `ActionItemRow`. With Reduce Motion on:

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion

.animation(reduceMotion ? nil : .snappy(duration: 0.25), value: answer.isResolved)
```

— state still flips instantly, just without the slide.

### 4.5 Light / dark per screen

All semantic colors above ship light + dark variants in the asset catalog. Per-screen spot checks:

- **Inbox.** Background `crowly.background` (light `#F2F2F7` / dark `#000`); cell `crowly.surface` (light `#FFF` / dark `#1C1C1E`). Job stripe stays visible against either because the algorithm switches S/L by `colorScheme`.
- **Detail.** Same surface tokens. Bottom-line callout uses `Color.accentColor.opacity(0.08)` — accent tint reads the same in both modes because opacity is low.
- **Widget.** Background is **system-managed** (glass), so light/dark/Accented all flow from `Color.clear` containerBackground. Stripes get explicit accented-mode override (§3.3).
- **Sheets.** `presentationBackground(.thinMaterial)` `[iOS 26]` for the free-text reply sheet so it feels like a layer of glass over the detail view.

### 4.6 Increased Contrast

`.accessibilityShowsButtonShapes` (handled by the system on glass button styles). When the system requests increased contrast, the answer-button text weight bumps from `.medium` to `.semibold` via the environment:

```swift
@Environment(\.legibilityWeight) private var legibilityWeight
.font(.body.weight(legibilityWeight == .bold ? .semibold : .medium))
```

---

## 5. Intent → visual lexicon (single source of truth)

This is the only place the table from `ux.md` is encoded — every component reads from it. Adding a route adds a case here and **only** here.

```swift
/// The five intents the app can render. Mirrors schema.md `route`s plus the
/// terminal in-inbox fallback that the resolver may produce.
enum Intent: String, CaseIterable, Hashable {
    case task
    case note
    case followup
    case none            // schema-level: no side effect
    case terminal        // resolver-level: "stays in the inbox, logged" fallback

    /// SF Symbol used in the chip, the row glyph (when not using OpenLoopGlyph),
    /// and the route button leading icon. Matches ux.md.
    var symbol: String {
        switch self {
        case .task:     "checklist"
        case .note:     "note.text"
        case .followup: "arrow.uturn.forward"
        case .none:     "circle.dotted"
        case .terminal: "tray.fill"
        }
    }

    /// Verb on a route button. Matches ux.md.
    var verb: String {
        switch self {
        case .task:     "Add as task"
        case .note:     "Save as note"
        case .followup: "Send to Hermes"
        case .none:     "Dismiss"
        case .terminal: "Log in inbox"
        }
    }

    /// Noun used in intent chips ("1 task", "2 questions" — questions are not
    /// an Intent; that's the IntentChip caller's job).
    func noun(pluralFor count: Int) -> String {
        switch self {
        case .task:     count == 1 ? "task" : "tasks"
        case .note:     count == 1 ? "note" : "notes"
        case .followup: count == 1 ? "followup" : "followups"
        case .none:     ""
        case .terminal: count == 1 ? "in inbox" : "in inbox"
        }
    }

    /// Whether the companion's GET /capabilities can make this intent unavailable.
    var isCapabilityAware: Bool {
        switch self {
        case .task, .note, .followup: true
        case .none, .terminal:        false        // always available
        }
    }

    /// Ordering used for the chip row on `DigestCell`. Question-count chips
    /// (which aren't an Intent) are inserted by the cell first.
    static let cellOrdering: [Intent] = [.task, .followup, .note]
}

/// A resolved route, produced by RouteResolver. Combines the intent with the
/// companion's actual capability so the UI never lies about what will happen.
struct RouteResolution {
    let intent: Intent
    let verb: String          // typically Intent.verb, but resolver may rewrite
                              // (e.g., "Save as note (Obsidian unavailable, falling back to local)")
    let sublabel: String?     // e.g., "Will create a Todoist task"
    let symbol: String        // Intent.symbol unless overridden
    let confirmation: String  // post-tap: "task created", "note saved", "queued for Hermes"
    let enabled: Bool         // false → caller drops the button (capability-aware)
    let hasOverrides: Bool    // action items only: lets RouteButton show the ⋯ menu
}
```

**Capability mapping (Demo Mode default — used by `RouteResolver` for canned digests):**

| Intent | Demo-mode resolution |
|---|---|
| `task` | enabled=true; verb="Add as task"; sublabel="Will create a Todoist task"; confirmation="task created" |
| `note` | enabled=true; verb="Save as note"; sublabel="Will save as note"; confirmation="note saved" |
| `followup` | enabled=true; verb="Send to Hermes"; sublabel="Will queue an agent run"; confirmation="queued for Hermes" |
| `none` | enabled=true; verb="Dismiss"; sublabel=nil; confirmation="dismissed" |
| `terminal` | enabled=true; verb="Log in inbox"; sublabel="Will keep in inbox"; confirmation="kept in inbox" |

In real mode this map is built from `GET /capabilities` (architecture.md § Routing); when a capability is missing, the resolver either falls back through the chain (per schema.md § Routes are intents) or returns `enabled=false`. Either way, the **UI binds only to `RouteResolution`** — there is no path by which a button can render a dead affordance.

---

## Why this matches Apple docs (anchors for the coder's review)

- Liquid Glass usage and the answer-button styling follow Apple's *Implementing Liquid Glass Design in SwiftUI* (`.buttonStyle(.glass)` / `.glassProminent`, `GlassEffectContainer` for clusters, `.glassEffect()` reserved for the demo banner — not card content).
- Widget rendering modes, `widgetAccentable()`, and `.containerBackground(for: .widget) { Color.clear }` follow *Implementing Liquid Glass Design in Widgets* (Accented vs Full Color).
- Bottom-bar action layout in detail follows *SwiftUI New Toolbar Features* (`ToolbarItemGroup(placement: .bottomBar)` + `ToolbarSpacer`).
- `Button(intent:)` from the widget, running silently in the background, follows the AppIntents widget pattern referenced in `ux.md`.

## Pitfalls (read before building)

- **Don't put `.glassEffect()` on the cell.** It will trash legibility against busy wallpapers and miss the invariant entirely. Cell = opaque, always.
- **Don't use `String.hashValue` for job color.** It's seeded per process; you'll get different colors after every relaunch. The FNV-1a implementation in §1.1.2 is non-negotiable.
- **Don't gate `[iOS 26]` APIs now.** M1 target is iOS 26 — gates add noise. They go in for M2 when the public target may drop.
- **Don't let a button render without `RouteResolution`.** Every actionable affordance — answer, action, override — flows through the resolver. This is what guarantees no dead buttons across companion versions.
- **Don't add a fifth status-dot state.** "Snoozed", "muted-but-open", etc., are M2. Four states keep the cell scannable.
- **Don't animate the row layout on "did the work" decay.** The shape stays put; only the fill changes. Layout-shifting animations make resolution feel unstable.
