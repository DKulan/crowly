# Design System (M1)

The implementation-ready visual design system for the Crowly M1 iOS app and `systemMedium` widget. This doc realizes the interaction spec in [`ux.md`](ux.md), renders the contract in [`schema.md`](schema.md), and respects the architecture in [`architecture.md`](architecture.md). It is opinionated, Apple-native, and intended to be built from directly — the coder will adapt these sketches, but the tokens, components, and screen hierarchies are decisions, not options.

## Scope & constraints (locked)

- **Deployment target: iOS 26.** Liquid Glass APIs (`.glassEffect()`, `GlassEffectContainer`, `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)`) are usable freely. Each API site that requires iOS 26 is flagged inline as `[iOS 26]` so M2 (potentially lower minimum) can `@available`-gate later. Do not add gates now.
- **Demo Mode first.** Every component renders entirely from canned model values; nothing here depends on a live companion or network.
- **The triad is the product:** (1) Inbox list cell, (2) Digest detail view, (3) `systemMedium` widget entry. Everything else exists to serve these three.
- **Liquid Glass for chrome, not content.** Toolbars and the widget surface get glass; digest cards and detail body stay opaque so prose is legible against any wallpaper or beneath glass chrome.

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
| `crowly.accent` | `#0A84FF` (systemBlue) | `#0A84FF` | Tint, unread-dot fill, link tint |
| `crowly.warning` | `#FF9F0A` | `#FF9F0A` | High-urgency exclamation glyph |
| `crowly.destructive` | `#FF3B30` | `#FF453A` | Urgent-urgency exclamation glyph |
| `crowly.muted` | `#8E8E93` (systemGray) | `#8E8E93` | "Archive" swipe, archived-section section header |

> **Rule:** all foreground text on cards uses `Color.primary`/`.secondary` so Dynamic Type + Smart Invert + Increased Contrast inherit for free.

#### 1.1.1 Urgency colors

Maps `digest.urgency` → an accent used only on the cell's leading exclamation glyph (when high/urgent) and the widget's urgency rail. Body text never tints by urgency (legibility).

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

#### 1.1.3 Unread-dot states (two; never a badge stack)

`UnreadDot` is the single source of truth for cell read/unread state. Per `ux.md` § Inbox.

| State | Fill | Stroke | Diameter | Notes |
|---|---|---|---|---|
| `unread` | `.accentColor` filled | none | 10pt | Digest hasn't been opened |
| `read` | n/a | n/a | hidden | Dot is not rendered |

(Archived digests live in their own section and don't render a dot at all — the section header *is* the state.)

Per-urgency tinting layers on top: if `digest.urgency >= .high` and state is `unread`, the dot inherits `Color.urgency(digest.urgency)` instead of `.accentColor`. One signal, not two badges.

### 1.2 Typography

Map every text role to a `Font.TextStyle` — never a fixed point size — so Dynamic Type scales the whole app for free.

| Token | TextStyle | Weight | Used for |
|---|---|---|---|
| `title.large` | `.largeTitle` | `.bold` | Navigation title (large) on Inbox + Detail |
| `title.section` | `.title2` | `.semibold` | Section headings in detail (from `sections[].heading`) |
| `title.cell` | `.headline` | `.semibold` (default) | Digest cell title |
| `body.lead` | `.body` | `.regular` | Cell `bottom_line`, detail summary/section bodies |
| `body.callout` | `.callout` | `.regular` | Detail "Bottom line" callout block |
| `meta` | `.footnote` | `.regular` | Cell timestamp, secondary meta |
| `mono.id` | `.caption2.monospaced()` | `.regular` | Debug surfaces / Settings only — never in main flow |

```swift
extension Font {
    static let crowlyCellTitle:    Font = .headline
    static let crowlyCellBody:     Font = .body
    static let crowlyDetailCallout: Font = .callout
    static let crowlySectionTitle: Font = .title2.weight(.semibold)
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
| Detail "Archive" button | `.buttonStyle(.glassProminent)` `[iOS 26]` | The detail screen's one primary action |
| Detail `⋯` menu | `.buttonStyle(.glass)` `[iOS 26]` | Secondary; lives next to Archive |
| Widget background | `.containerBackground(for: .widget) { Color.clear }` so system renders glass beneath | WidgetKit invariant |
| Cell card | **Opaque** `crowly.surface` | Prose legibility; `bottom_line` reads against any wallpaper |
| Detail body | **Opaque** `crowly.surface` callout | Same reason |
| Detail "Bottom line" callout | Opaque tinted block — `.background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: Radius.surface))` | Visual emphasis without glass; legible |
| Demo-mode banner | `.glassEffect(.regular.tint(.orange))` `[iOS 26]` in a Capsule | Chrome on top of inbox; tint signals "not real data" |

**Two hard rules** (changing either is a design change):

1. **Never put `.glassEffect()` on a view that owns the main reading text** — cell title, `bottom_line`, summary, section body. Glass-behind-prose fails the legibility bar against busy wallpapers.
2. **No widget buttons.** The widget is read-only; `Button(intent:)` is not used in any widget surface. (This is the reader-pivot's hardest constraint; rest of the design follows from it.)

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

**States.** See §1.1.3.

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
                Button {
                    store.archive(digest)
                } label: {
                    Label("Archive", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.glassProminent)              // [iOS 26]

                ToolbarSpacer(.flexible)

                Menu {
                    Button("Mute job push", systemImage: "bell.slash") {
                        store.muteJobPush(digest.jobId)
                    }
                    #if DEBUG
                    Button("Open as JSON", systemImage: "curlybraces") { /* debug surface */ }
                    #endif
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
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
        case .systemLarge:  largeLayout                 // M1 cut-target; see ux.md cut order
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

    private var largeLayout: some View {                    // simple extension of medium
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

### 4.4 Reduce Motion

There are no decay animations in the reader — read state is a simple dot vanish. `.animation(reduceMotion ? nil : .snappy(duration: 0.20), value: isUnread)` is the only animated state transition in the cell. Archive uses the system's default `List` row-removal animation, which honors Reduce Motion automatically.

### 4.5 Light / dark per screen

All semantic colors above ship light + dark variants in the asset catalog. Per-screen spot checks:

- **Inbox.** Background `crowly.background` (light `#F2F2F7` / dark `#000`); cell `crowly.surface` (light `#FFF` / dark `#1C1C1E`). Job stripe stays visible against either because the algorithm switches S/L by `colorScheme`.
- **Detail.** Same surface tokens. Bottom-line callout uses `Color.accentColor.opacity(0.08)` — accent tint reads the same in both modes because opacity is low.
- **Widget.** Background is **system-managed** (glass), so light/dark/Accented all flow from `Color.clear` containerBackground. Stripes get explicit accented-mode override (§3.3).

### 4.6 Increased Contrast

`.accessibilityShowsButtonShapes` (handled by the system on glass button styles). When the system requests increased contrast, the bottom-bar Archive button's text weight bumps from `.medium` to `.semibold` via the environment:

```swift
@Environment(\.legibilityWeight) private var legibilityWeight
.font(.body.weight(legibilityWeight == .bold ? .semibold : .medium))
```

---

## Why this matches Apple docs (anchors for the coder's review)

- Liquid Glass usage and the bottom-bar button styling follow Apple's *Implementing Liquid Glass Design in SwiftUI* (`.buttonStyle(.glass)` / `.glassProminent`, `.glassEffect()` reserved for the demo banner — not card content).
- Widget rendering modes, `widgetAccentable()`, and `.containerBackground(for: .widget) { Color.clear }` follow *Implementing Liquid Glass Design in Widgets* (Accented vs Full Color).
- Bottom-bar action layout in detail follows *SwiftUI New Toolbar Features* (`ToolbarItemGroup(placement: .bottomBar)` + `ToolbarSpacer`).
- Read-only widgets with `Link` deeplinks follow the WidgetKit guidance for static-information widgets (in contrast to interactive `Button(intent:)` widgets, which are deliberately out of scope here).

## Pitfalls (read before building)

- **Don't put `.glassEffect()` on the cell.** It will trash legibility against busy wallpapers and miss the invariant entirely. Cell = opaque, always.
- **Don't use `String.hashValue` for job color.** It's seeded per process; you'll get different colors after every relaunch. The FNV-1a implementation in §1.1.2 is non-negotiable.
- **Don't gate `[iOS 26]` APIs now.** M1 target is iOS 26 — gates add noise. They go in for M2 when the public target may drop.
- **Don't add buttons to the widget.** The widget is `Link`-only. Buttons in a reader widget invite the question "what does this do?" — and the answer should always be "open the app to read it."
- **Don't add a third unread state.** "Snoozed", "muted-but-open", etc., are M2. Two states (unread / not-unread) keep the cell scannable.
- **Don't reorder by urgency.** Urgency drives push and the urgency glyph; the inbox is strictly chronological.
