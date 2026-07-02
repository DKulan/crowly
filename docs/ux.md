# iOS UI/UX (M1)

The M1 app's interaction design. Grounded in Apple's WidgetKit / App Intents / SwiftUI guidance and the project invariants. M1 scope only — anything public-only (demo polish, Spotlight, Lock Screen widgets) is M2.

## North stars (derived from the invariants)

- **The card is a one-glance read, not a story.** Every cell answers "what did this agent bring back?" in under a second: source, when, the `bottom_line`. Detail is one tap away for the prose.
- **Read on open; archive when done.** Two states, two gestures. No "handled," no "muted job," no triage tax. The inbox is a reading queue, not a control panel.
- **The widget is the demo.** It must show the most recent digest(s) on the home screen and deeplink straight into the app — no buttons, no answers, no chrome beyond the digest itself.
- **Companion-version honesty.** Schema fields the app doesn't know are skipped, not rendered as garbage. The UI never lies about what was stored.
- **Liquid Glass for chrome, not content.** Toolbars and the widget surface get `.glass`/`.glassProminent`; cards stay opaque so digest text stays legible against any wallpaper.

## Information architecture

One `NavigationStack` rooted on **Inbox** is enough for M1. (A `TabView` — Inbox / Jobs / Settings — is an M2 move only if Jobs grows into a real browse experience.)

```
RootNavigationStack
└── InboxView (root)                 list of digests, grouped by date
    ├── DigestDetailView             header → bottom line → summary/sections → sources
    ├── JobView                      inbox filtered to one job_id
    ├── SettingsView                 pairing, disconnect, demo toggle
    │   └── PairCompanionView         .fullScreenCover camera scanner
    └── DemoModeBanner               .safeAreaInset(.top), dismissable

Home screen:
└── CrowlyWidget (small / medium / large)
    ├── Timeline: latest digests, by created_at desc
    ├── Tap row → deeplink crowly://digest/<id>
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

**Empty / error states** use `ContentUnavailableView`, never a blank screen:
- New pairing → "No digests yet. Send your first one from Hermes." + "Show example" (Demo Mode).
- Companion unreachable → "Can't reach your inbox service" + retry, with last-cached digests still visible behind the banner.
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

Fed by `GET /summary` (cheap; returns latest few digests + unread count). The widget's `TimelineProvider` reloads on its own **~15-minute floor**, refreshing from `GET /summary` — that's the entire refresh model (see [`architecture.md`](architecture.md) → Refresh model).

**Every widget size is read-only — tap deeplinks into the app; nothing else.** This is the reader-pivot's biggest UX move: no buttons in the widget, no answer affordances, no action verbs. The widget's job is "here's what just arrived; tap to read it."

**`.systemSmall`** — at-a-glance: app glyph + **unread count** in the top-right; **latest digest's `bottom_line`** (3 lines max) below. Tapping anywhere deeplinks to `crowly://digest/<latest-id>`. If no unread, shows "All clear" + the latest read digest's `bottom_line` in `.secondary`.

**`.systemMedium`** — the default and the App Store screenshot: header row with app glyph + unread count, then **the top 2–3 most-recent digests** as compact rows. Each row shows the leading job color stripe, the source (`title`), the relative timestamp, and the `bottom_line` (1 line, tail-truncated). Tapping a row deeplinks to that digest.

**`.systemLarge`** — same shape as medium, **4–5 rows** + a "View all →" footer that deeplinks to the inbox root. Cut-target if M1 slips; small + medium covers the demo.

WidgetKit specifics that matter:

- `.containerBackground(for: .widget) { Color.clear }` so the system renders glass beneath the rows.
- `widgetAccentable()` on the app glyph, count badge, and job stripes — these go monochrome white in Accented mode while the body text tints cleanly.
- `widgetURL` per row deeplinks `crowly://digest/<id>`. The whole widget is also wrapped in a `widgetURL` for the bottom-line surface so a tap anywhere on the small widget Just Works.

Constraints respected:

- **No buttons.** `Button(intent:)` is not used anywhere in the widget — there's no action to take. (This is a deliberate departure from the old loop-widget design.)
- **No content beyond `title` + `bottom_line` + timestamp** — the widget is a pointer to the digest, not the digest itself.
- **No widget login state** — never blank/error. Data path as shipped (M1 Phase 1, `docs/architecture.md` § Widget data path): when **paired**, the widget fetches `GET /summary` itself on its ~15-min timeline and caches the result to a shared App Group snapshot, falling back to that snapshot when a fetch fails (the app also writes the snapshot on refresh/read/archive to seed the first render). When **unpaired**, the widget renders **demo fixtures** — matching the app's demo-mode-when-unpaired behavior and giving App Review a populated widget to screenshot. (This supersedes an earlier draft of this line that showed an "Open Crowly to pair" prompt when unpaired; demo fixtures won because a populated widget reads better on the home screen and in App Review than an empty call-to-action.)

## Onboarding (≈60 seconds)

1. Launch → **Demo Mode** by default (3 canned digests of varied urgencies and shapes, fully client-side). Reachable afterward from Settings → "Show demo digests" (for App Review).
2. Pinned `.safeAreaInset(.top)` banner "Connect your Crowly inbox →" → **PairCompanionView**.
3. Pair: camera scanner reads the QR `{companion_url, pairing_token, …}`, validates by hitting the companion over HTTPS, stores credentials in the **Keychain**, dismisses with success. Manual "Enter URL and token instead" fallback for the QR-averse and as a Reviewer escape valve.
4. First real digest pulled → demo banner disappears. That transition is the "aha."

(Pairing wire-protocol detail lives in [`architecture.md`](architecture.md) → Pairing.)

## iOS specifics

**Use:** App Group container for the widget's small state + a JSON/SwiftData digest cache; `SFSafariViewController` for external sources (never an in-app `WKWebView`); `ContentUnavailableView` for every empty/error state.

**Avoid in M1:** custom navigation/zoom transitions; **Lock Screen widgets** (defer — they add platform surface without changing the read flow); background URL session for state writes (synchronous POST + retry-on-foreground is enough); `Button(intent:)` widgets (no action surface in a reader).

## Cut order if M1 slips

1. Spotlight indexing / `.userActivity` → M2.
2. Large widget — small + medium covers the demo.
3. `⋯` menu in detail bottom bar (Open as JSON) — Archive alone is enough for M1.
4. Search — chronological scan covers <50 digests; revisit if the inbox grows.

**Keep no matter what — this triad *is* the M1 product:** the inbox cell with date sectioning and unread dot · the detail view rendering header → bottom line → summary → sections → sources · the medium widget with 2–3 latest digests and an unread count.
