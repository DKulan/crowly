# iOS UI/UX (M1)

The M1 app's interaction design. Grounded in Apple's WidgetKit / App Intents / SwiftUI guidance and the project invariants. M1 scope only — anything public-only (demo polish, Spotlight, Lock Screen widgets) is M2.

## North stars (derived from the invariants)

- **The card is a one-glance read, not a story.** Every cell answers "what did this agent bring back?" in under a second: source, when, the `bottom_line`. Detail is one tap away for the prose.
- **Read on open; archive when done.** Two states, two gestures. No "handled," no "muted job," no triage tax. The inbox is a reading queue, not a control panel.
- **The widget is the demo.** It must show the most recent digest(s) on the home screen and deeplink straight into the app — no buttons, no answers, no chrome beyond the digest itself.
- **Companion-version honesty.** Schema fields the app doesn't know are skipped, not rendered as garbage. The UI never lies about what was stored.
- **Liquid Glass for system chrome; brand pill for primary CTAs; opaque for content.** Toolbars and the widget surface still ride on system glass, and cards stay opaque so digest text stays legible against any wallpaper — but *primary* CTAs (onboarding "Connect my inbox", pairing) use the flat orange brand pill (`.buttonStyle(.crowlyPrimary)`), not `.buttonStyle(.glass)`. Full chrome hierarchy in `docs/design-system.md` § 1.4.

## Information architecture

One `NavigationStack` rooted on **Inbox** is enough for M1. (A `TabView` — Inbox / Jobs / Settings — is an M2 move only if Jobs grows into a real browse experience.)

```
ContentView (root ZStack)            first-run onboarding gate over the inbox
├── OnboardingView                   4-screen carousel, first run only (hasOnboarded gate)
└── RootNavigationStack
    └── InboxView (root)             list of digests, grouped by date
        ├── DigestDetailView         header → bottom line → summary/sections → sources
        ├── JobView                  inbox filtered to one job_id
        ├── SettingsView             pairing, disconnect, demo toggle
        │   └── PairCompanionView     QR scan (VisionKit) + manual URL/token fallback
        │       └── QRPairScannerView .sheet DataScannerViewController
        └── DemoModeBanner           .safeAreaInset(.top), dismissable

Home screen:
└── CrowlyWidget (small / medium / large)
    ├── Timeline: latest digests, by created_at desc
    ├── Tap row → deeplink crowly://digest/<id>
    ├── Large "View all N →" footer → deeplink crowly://inbox (pops to root)
    └── No buttons — pure reader surface
```

Object model:

- **Digest** = one card; identity is `digest.id`.
- **Job** = bucket by `job_id`; the secondary navigation axis (filter, group header).
- **State** (unread / read / archived) is computed locally for optimistic UI but mirrored to the companion via a small `state_change` write. The companion is source of truth; the local store is a cache for offline read.

## Inbox screen

Sectioned `List`, sticky **date** headers (Today / Yesterday / This week / Earlier), auto-refresh (foreground + interval poll while open; pull-to-refresh kept as a manual override), `.searchable($query).searchToolbarBehavior(.minimize)`. Job grouping is a *filter*, not the default — chronological scan wins for <10 active jobs.

**Sort:** `created_at` desc within each date section. `urgency` `high`/`urgent` get a small leading exclamation glyph but do **not** reorder — the inbox is a chronological reading queue. (Urgency drives widget surfacing, not list order.)

**Cell anatomy:**

```
┌──────────────────────────────────────────────┐
│ [job-glyph]  Harmony Community Digest        │  .headline; 4pt job color stripe on leading edge
│              Sun · 7:00 PM             ●     │  .footnote .secondary; unread dot trailing
│                                              │
│  No urgent updates this week. County         │  bottom_line, .body, 2 lines max, .tail truncation
│  bylaws under review remain worth watching.  │
└──────────────────────────────────────────────┘
```

- **Unread dot**, two states: unread (filled accent) and read (no dot). Archived digests live in their own section and don't show a dot at all. **Three visual states, two states of mind: unread vs. everything else.**
- **Job color stripe** is derived deterministically from `job_id` (hash → fixed S/L HSL). Scannable by source with no per-job config in M1. (User-configurable colors: M2.)
- **Swipe actions:** trailing "Archive" (gray) is the only swipe. Archive fires a `state_change`, removes the row optimistically, and shows an undo toast for ~5 seconds. **There is no leading swipe.** (No "mark handled," no "mute job" — those were artifacts of the old loop model.)
- **Tap a row** marks it read (optimistically + `state_change`) and pushes the detail view. The unread dot fades immediately; if the network write fails, the dot stays and a quiet retry banner appears at the top.

**Loading / empty / error states** — the inbox has four states, never a blank screen:
- **Loading (first fetch)** → a redacted, cell-shaped skeleton (`InboxLoadingView`, `.redacted(reason: .placeholder)`), NOT an empty view. In live mode the store starts `hasLoaded == false` and the paired inbox is empty until the first `/list` lands; showing the skeleton (rather than an empty state) is what stops the cold-launch "flash empty, then pop in" and the wrong "No matches" copy mid-load. Demo mode is seeded synchronously (`hasLoaded == true`), so it never shows the skeleton.
- **Genuinely empty**, three distinct messages (never the wrong one): searching with no hits → `ContentUnavailableView.search`; paired but the companion returned nothing → "Inbox is empty" / "New digests from your companion will show up here."; demo/first-run → "No digests yet."
- Companion unreachable → surfaced via the refresh-error path (last-cached digests stay visible; a retry banner, not a blank screen).
- Companion schema older than `N-1` → pinned "Update your inbox service" banner, no destructive action.

## Digest detail screen

Order: **Header → Bottom line → Summary → Sections → Sources → Footer.** No open-loop section, no answer buttons, no action items — just the digest, read top to bottom.

```
  Harmony Community Digest                       .navigationTitle (large)
  Sun, Jun 29 · 7:00 PM · low urgency            .navigationSubtitle

  Bottom line
  No urgent updates this week. County            callout block, subtle accent-tinted fill
  bylaws under review remain worth watching.

  Summary
  Full prose summary of the digest...            .body

  Bylaw watch                                    .title2 .semibold (section heading)
  Regional off-site levy updates remain
  under review.

  Sources
    ↗ Rocky View County Bylaws Under Review        Link → SFSafariViewController

  ── bottom bar (.bottomBar, system glass) ──
   [ Archive ]                              ⋯
```

- The detail opens with the **bottom line** in a tinted callout — this is the one piece of prose that earns top-of-screen real estate because it's the digest's own TL;DR.
- **Summary and sections render in the order the emitter sent them.** No reordering, no priority weighting — the agent decided what matters; the reader respects that.
- **Sources** are tappable rows that open `SFSafariViewController` in-app (never a `WKWebView`, never an external Safari kick-out).
- **Bottom bar** has **Archive** as the primary action and a `⋯` menu for "Open as JSON" (debug surface, hidden in non-debug builds).
- **No "mark handled" button.** Opening the digest marks it read; that's the only read-state transition the user needs.

## Home-screen widget

Fed by `GET /summary` (cheap; returns the latest **5** non-archived digests + unread count + the non-archived `total`). The widget's `TimelineProvider` reloads on its own **~15-minute floor**, refreshing from `GET /summary` — that's the entire refresh model (see [`architecture.md`](architecture.md) → Refresh model). Archived digests are excluded from the widget — archive is a triage move, so a triaged digest must not resurface on the home screen.

**Every widget size is read-only — tap deeplinks into the app; nothing else.** This is the reader-pivot's biggest UX move: no buttons in the widget, no answer affordances, no action verbs. The widget's job is "here's what just arrived; tap to read it."

**`.systemSmall`** — at-a-glance: app glyph + **unread count** in the top-right; **latest digest's `bottom_line`** (3 lines max) below. Tapping anywhere deeplinks to `crowly://digest/<latest-id>`. If no unread, shows "All clear" + the latest read digest's `bottom_line` in `.secondary`.

**`.systemMedium`** — the default and the App Store screenshot: header row with app glyph + unread count, then **the top 2–3 most-recent digests** as compact rows. Each row shows the leading job color stripe, the source (`title`), the relative timestamp, and the `bottom_line` (1 line, tail-truncated). Tapping a row deeplinks to that digest.

**`.systemLarge`** — **shipped** (2026-07-02). Same header + shape as medium, but **up to 5 rows** and a **"View all N →" footer** (shown only when the inbox holds more non-archived digests than the widget can show) that deeplinks to the inbox root via `crowly://inbox` — a new deeplink whose only job is to pop the nav stack to the inbox root. `N` is the companion's non-archived `total` (`GET /summary` → `total`; see [`architecture.md`](architecture.md) → Widget data path).

WidgetKit specifics that matter:

- `.containerBackground(for: .widget) { Color.clear }` so the system renders glass beneath the rows.
- `widgetAccentable()` on the app glyph, count badge, and job stripes — these go monochrome white in Accented mode while the body text tints cleanly.
- `widgetURL` per row deeplinks `crowly://digest/<id>`. The whole widget is also wrapped in a `widgetURL` for the bottom-line surface so a tap anywhere on the small widget Just Works.

**Cue polish (M2 Phase 3c, 2026-07-02).** The widget is the MVP's *only* habit cue, so the glance was tightened to read at arm's length — still read-only, no new surface:
- Unread renders as a filled **"N new" pill** (tinted, `widgetAccentable`) in the medium/large header instead of plain grey text — a stronger "something arrived" signal. Absent when `unreadCount == 0`.
- Each medium/large row now shows a **relative age** ("2h", "now") right-aligned next to the title (`.relative` format on the row's `createdAt`), so freshness is legible without opening the app.
- **Push posture: still deferred** (decided 2026-07-02). No notifications, no `BGAppRefreshTask` — the widget's own ~15-min timeline remains the entire ambient-refresh model, and the "no notifications in the MVP" invariant (`validation.md`) holds. Local/central notifications stay a Phase-4 item, revisited only if daily use shows the widget glance isn't enough (`roadmap.md` Phase 4).

Constraints respected:

- **No buttons.** `Button(intent:)` is not used anywhere in the widget — there's no action to take. (This is a deliberate departure from the old loop-widget design.)
- **No content beyond `title` + `bottom_line` + timestamp** — the widget is a pointer to the digest, not the digest itself.
- **No widget login state** — never blank/error. Data path as shipped (M1 Phase 1, `docs/architecture.md` § Widget data path): when **paired**, the widget fetches `GET /summary` itself on its ~15-min timeline and caches the result to a shared App Group snapshot, falling back to that snapshot when a fetch fails (the app also writes the snapshot on refresh/read/archive to seed the first render). When **unpaired**, the widget renders **demo fixtures** — matching the app's demo-mode-when-unpaired behavior and giving App Review a populated widget to screenshot. (This supersedes an earlier draft of this line that showed an "Open Crowly to pair" prompt when unpaired; demo fixtures won because a populated widget reads better on the home screen and in App Review than an empty call-to-action.)

## Onboarding

### First-run carousel (M2 Phase 3b — shipped 2026-07-02)

The first launch presents a swipeable **4-screen carousel** over the inbox — a `TabView(.page)` gated by `@AppStorage("hasOnboarded")` (the gate + `InboxView` live in a `ZStack` in `App/ContentView.swift`; onboarding presents on top on first run only). Copy is grounded in `docs/deployment-learnings.md` — it's honest about the self-hosted shape, with **no zero-touch promise**. Screens (`App/Views/Onboarding/OnboardingView.swift`, `OnboardingScreen`):

1. **What Crowly is** — a read-only inbox for the digests your agents produce on a schedule; nothing acts on your behalf.
2. **Runs on your own machine** — a self-hosted companion on *a server or your own computer* (copy is deliberately topology-neutral — not VPS-only), behind your own TLS; no central Crowly server ever sees your content. Tailscale Funnel is framed as the easy default *because it spans setups* — "it works whether you're on a VPS or a home machine, with no domain or certificate to wrangle."
3. **Your agent fills it** — point your agent at the companion with the emitter kit, "a few lines of Python, **no Docker required**"; if the agent can run commands on the host it can even set the companion up for you.
4. **Pair once, then read** — scan the QR your companion prints (or paste URL + token); the secret goes straight to the **Keychain**, never off the phone. Ends on the honest always-on caveat: "New digests appear whenever your companion is reachable, so it's happiest on a machine that stays awake" (the pull model can't wake a sleeping laptop — see `docs/architecture.md` § Refresh model / `docs/onboarding.md` § Where the companion can run).

- **CTA** advances through the deck (the flat orange brand pill via `.buttonStyle(.crowlyPrimary)` — "Next"), then on the last screen reads **"Connect my inbox"** and hands off to pairing: it flips `hasOnboarded` and sets `DeepLinkRouter.pendingPair`, which `InboxView` already observes → opens **PairCompanionView**.
- **Skip** (any screen) and **"Look around first"** (last screen) dismiss straight into demo mode.
- **Crow art shipped (2026-07-02 redesign).** `App/Views/Onboarding/CrowAnimationView.swift` renders the bundled `crow` asset — a transparent right-facing ink crow with orange/grey speed-lines, extracted from the app icon (`App/Assets.xcassets/crow.imageset`) — with a gentle code-driven bob (`Reduce Motion` holds it still). No Lottie, no third-party animation dependency. `CrowKind` remains as an enum for API stability but all four cases resolve to the single shared `crow` asset (per-kind art was collapsed to one hero image so the onboarding beats visually match the icon).
- **Visual identity.** The whole carousel sits on the fixed brand palette — cream field, ink serif headline (`Font.crowlyDisplay*`), a `CrowlyDivider` (short orange rule + center dot) under each headline, orange brand pill CTA, warm hairline page dots. The app is light-locked (`.preferredColorScheme(.light)` at the scene root) so onboarding reads the same in light and dark system appearance. Full palette + type rules live in `docs/design-system.md`.
- **Testing surface:** `crowly://onboarding` replays the carousel (resets the gate via `DeepLinkRouter.replayOnboarding`) — the same undocumented-testing pattern as `crowly://pair`.

### The "aha" arc (≈60 seconds)

1. Launch → carousel → pair (or skip into **Demo Mode**: 3 canned digests of varied urgencies and shapes, fully client-side; reachable afterward from Settings → "Show demo digests" for App Review).
2. Reachable afterward: pinned `.safeAreaInset(.top)` banner "Connect your Crowly inbox →" → **PairCompanionView**.
3. Pair: **QR scan is functional** (VisionKit `DataScannerViewController`, `App/Views/Onboarding/QRPairScannerView.swift`) — it reads the companion's `{companion_url, pairing_token, …}` QR, fills the PairCompanionView fields, and auto-validates against the companion over HTTPS before persisting to the **Keychain**. Where there's no camera (Simulator / headless device) it degrades gracefully to a "Camera unavailable → Enter manually" state. **Manual URL + token entry remains the always-works fallback** (and the Reviewer escape valve). (QR was previously specced as a post-M1 stub; it shipped in M2 Phase 3b.)
4. First real digest pulled → demo banner disappears. That transition is the "aha."

(Pairing wire-protocol detail lives in [`architecture.md`](architecture.md) → Pairing.)

## iOS specifics

**Use:** App Group container for the widget's small state + a JSON/SwiftData digest cache; `SFSafariViewController` for external sources (never an in-app `WKWebView`); `ContentUnavailableView` for every empty/error state.

**Avoid in M1:** custom navigation/zoom transitions; **Lock Screen widgets** (defer — they add platform surface without changing the read flow); background URL session for state writes (synchronous POST + retry-on-foreground is enough); `Button(intent:)` widgets (no action surface in a reader).

## Cut order if M1 slips

1. Spotlight indexing / `.userActivity` → M2.
2. ~~Large widget — small + medium covers the demo.~~ **Shipped 2026-07-02** — no longer a cut-target; small + medium + large all ship in M1.
3. `⋯` menu in detail bottom bar (Open as JSON) — Archive alone is enough for M1.
4. Search — chronological scan covers <50 digests; revisit if the inbox grows.

**Keep no matter what — this triad *is* the M1 product:** the inbox cell with date sectioning and unread dot · the detail view rendering header → bottom line → summary → sections → sources · the medium widget with 2–3 latest digests and an unread count.
