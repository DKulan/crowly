# iOS UI/UX (M1)

The M1 app's interaction design. Grounded in Apple's WidgetKit / App Intents / SwiftUI guidance and the project invariants. M1 scope only — anything public-only (demo polish, Spotlight, Lock Screen widgets) is M2.

## North stars (derived from the invariants)

- **The card is a question, not a story.** Every cell answers "does this need me?" before "what does it say." Open loops are the spine of the UI; pure-info digests are second-class.
- **Routes are intents, not tools.** A button reads "Add as task," never "Add to Todoist," and only renders if `GET /capabilities` resolves that intent. **No dead affordances, ever.**
- **The widget is the demo.** It must answer a `yes_no` in one tap from the home screen without launching the app. Everything else flows from that.
- **Companion-version honesty.** Schema fields the app doesn't know are skipped; `reply_kind`s the companion can't handle are hidden, not broken. The UI never lies about what was executed.
- **Liquid Glass for chrome, not content.** Toolbars, widget surfaces, and answer buttons get `.glass`/`.glassProminent`; cards stay opaque so digest text stays legible against any wallpaper.

## Information architecture

One `NavigationStack` rooted on **Inbox** is enough for M1. (A `TabView` — Inbox / Jobs / Settings — is an M2 move only if Jobs grows into a real browse experience.)

```
RootNavigationStack
└── InboxView (root)                 list of digests, grouped by date
    ├── DigestDetailView             bound answers + actions live here
    │   └── FreeTextAnswerSheet       .sheet, when reply_kind = free_text
    ├── JobView                       inbox filtered to one job_id
    ├── SettingsView                  pairing, capabilities, disconnect
    │   └── PairCompanionView          .fullScreenCover camera scanner
    └── DemoModeBanner                .safeAreaInset(.top), dismissable

Home screen:
└── CrowlyWidget (small / medium / large)
    ├── Timeline: open-loop digests, ranked by urgency
    ├── Tap row     → deeplink crowly://digest/<id>
    └── Tap answer  → AppIntent (background) → reload timeline
```

Object model:

- **Digest** = one card; identity is `digest.id`.
- **Job** = bucket by `job_id`; the secondary navigation axis (filter, group header).
- **OpenLoop** = an `action_item` or `question` not yet handled/answered. **The widget timeline is open loops, not digests.**
- **State** (read/handled/archived) is computed locally for optimistic UI but mirrored to the companion via a `state_change` callback. The companion is source of truth; the local store is a cache for offline read.

## Inbox screen

Sectioned `List`, sticky **date** headers (Today / Yesterday / This week / Earlier), pull-to-refresh, `.searchable($query).searchToolbarBehavior(.minimize)`. Job grouping is a *filter*, not the default — chronological scan wins for <10 active jobs.

**Sort:** open-loop digests first (by `urgency` desc, then `created_at` desc), then pure-info digests below a subtle divider — the visual hierarchy matches the alerting hierarchy (push is gated on open loops).

**Cell anatomy:**

```
┌──────────────────────────────────────────────┐
│ [job-glyph]  Harmony Community Digest        │  .headline; 4pt job color stripe on leading edge
│              Sun · 7:00 PM             ●     │  .footnote .secondary; status dot trailing
│                                              │
│  No urgent action items. County bylaws       │  bottom_line, .body, 2 lines max, .tail truncation
│  under review remain worth watching.         │
│                                              │
│  ● 1 question   ● 1 task                     │  intent chips — only if open; .caption2
└──────────────────────────────────────────────┘
```

- **Status dot**, four states, never a badge stack: unread (filled accent) · read-but-open (ring accent) · handled (filled secondary) · archived (hidden; lives in archive section).
- **Intent chips** are capsule `Label`s with SF Symbols, each a count of *open* items of that intent. They vanish when the count hits zero — a satisfying "did the work" decay.
- **Job color stripe** is derived deterministically from `job_id` (hash → fixed S/L HSL). Scannable by source with no per-job config in M1. (User-configurable colors: M2.)
- **Swipe actions:** leading "Mark handled" (green); trailing "Archive" (gray) and "Mute job" (orange). All fire `state_change`; archived/muted filter out optimistically with an undo. **Mute suppresses push only** — the inbox stays a durable archive, never a filter.

**Empty / error states** use `ContentUnavailableView`, never a blank screen:
- New pairing → "No digests yet. Send your first one from Hermes." + "Show example" (Demo Mode).
- `/capabilities` unreachable → "Can't reach your inbox service" + retry, with last-cached digests still visible behind the banner.
- Companion older than `N-1` → pinned "Update your inbox service" banner, no destructive action.

## Digest detail screen

Order: **Header → Open loops → Body → Sources → Footer actions.** Open loops sit *above* the body — they're the reason the digest was opened.

```
  Harmony Community Digest                       .navigationTitle (large)
  Sun, Jun 29 · 7:00 PM · low urgency            .navigationSubtitle

  Bottom line
  No urgent action items. County bylaws under    callout block, subtle .background fill
  review remain worth watching.

  Questions  (1 open)
  ?  Should I start tracking the off-site levy
     bylaw as a recurring watch?
       [   Yes   ]    [   No   ]                  .glassProminent / .glass capsules
       Will create a Todoist task                 resolution preview, .caption .secondary

  Action items  (1)
  ☐  Confirm Interlane EV9 drop-off window
     project: Alberta Move · @hermes @vendor      hints as chips
                            [ Add as task ]  ⋯    primary verb; ⋯ for overrides

  Summary …  Bylaw watch …                        schema sections, .body

  Sources
    ↗ Rocky View County Bylaws Under Review        Link → SFSafariViewController

  ── bottom bar (.bottomBar, system glass) ──
   [ Mark handled ]   [ Archive ]            ⋯
```

**Answering, by `reply_kind`:**

- **`yes_no`** — tap fires the `AppIntent`; optimistic UI: tapped button fills+disables, sibling hides, an inline `Label("Answered: yes — task created", systemImage: "checkmark.circle.fill")` slides in. POST failure flips the row to a soft "Tap to retry," never a destructive alert.
- **`choice`** — vertical `.glass` buttons, one per option, with each option's resolved route shown beneath as caption (consequence before tap). Falls back to a `Picker` at >4 options.
- **`free_text`** — button reads "Reply…", opens a `.sheet` with `TextEditor` and a banner showing the resolved route ("This reply will be saved as a note").

**Acting on `action_items`:** primary button is the resolved intent verb ("Add as task" / "Save as note" / "Send to Hermes" / "Log in inbox"). The terminal **"Log in inbox"** fallback is the *same shape* as the others — nothing is silently dropped and the user isn't punished for missing integrations. `⋯` opens overrides (project/due/labels prefilled from `hints`); it is **hidden, not greyed**, when the companion lacks that capability.

**Resolution preview** ("Will create a Todoist task") is **not optional** — it's the affordance that earns trust in the bound loop, computed app-side from `on_answer[value].route` + `/capabilities`, so it shows the *real* resolution ("Will save as note (Obsidian unavailable, falling back to local)"). One `RouteResolver` view-model returns `(verb, sublabel, sfSymbol, enabled)` for every button in the app — this is what guarantees no dead buttons.

## Interactive widget

Fed by `GET /summary` (cheap, binding-carrying). Timeline reloads on push (relay → APNs → `reloadTimelines`), with a **~15-minute reload floor** as the relay-outage degradation path (see [`architecture.md`](architecture.md) → Push).

**`.systemSmall`** — "what needs me today": logo + total open-loop count, the top-priority open question (2 lines), and `[ Yes ] [ No ]`. If the top loop is an action, shows `[ Do it ]` + `[ Open ]`. No open loops → latest `bottom_line` + glyph.

**`.systemMedium`** — the default and the App Store screenshot: up to **2 open loops**, each with inline answer buttons and a leading job color stripe.

**`.systemLarge`** — 4–5 loops + a "View all 12 →" footer deeplinking to the inbox.

WidgetKit specifics that matter:

- `GlassEffectContainer` around the button cluster; `.glassProminent` on the affirmative, `.glass` on the dismissive — monochromes cleanly in tinted (Accented) mode.
- `widgetAccentable()` on the status dot + count badge; `.containerBackground(for: .widget) { Color.clear }` so the system renders glass beneath.
- `widgetURL` per row deeplinks `crowly://digest/<id>`; buttons use `Button(intent:)` so the action runs **without launching the app**.
- `AnswerQuestionIntent` is `[.background, .foreground(.dynamic)]` — silent+fast by default; may request foreground only when the resolved route is `followup` (queues an agent run). After it runs, the intent calls `WidgetCenter.shared.reloadTimelines(ofKind:)` so the row vanishes within a beat.

Constraints respected:

- **One tap = one answer = no confirmation.** The companion dedupes on a client-minted `callback_id` (e.g. `digest_id + question_id`), so a double-tap is a no-op, not a duplicate.
- **No content beyond `bottom_line` / question text** — the widget is a pointer, per the invariant.
- **No widget login state** — the widget reads a shared App Group container the app populates; unpaired → "Open Crowly to pair," never blank/error.

## Intent → visual lexicon

The same mapping in cells, detail, and widget rows — consistency is the point:

| Intent     | SF Symbol             | Button verb     | Capability-aware? |
|------------|-----------------------|-----------------|-------------------|
| `task`     | `checklist`           | "Add as task"   | yes |
| `note`     | `note.text`           | "Save as note"  | yes |
| `followup` | `arrow.uturn.forward` | "Send to Hermes"| yes — hidden if no Hermes intake |
| `none`     | —                     | "Dismiss"       | always |
| terminal   | `tray.fill`           | "Log in inbox"  | always (the fallback) |

**Open-loop visual language:** an open question = a `?` in an accent circle; an open action = an unchecked `circle`; resolved = the same glyph, filled, `.secondary`. The shape stays put — only the fill changes — so "did the work" decay is visible without redrawing the layout.

## Onboarding (≈60 seconds)

1. Launch → **Demo Mode** by default (3 canned digests, one open question, one action; tapping "Yes" renders the bound loop entirely client-side). Reachable afterward from Settings → "Show demo digests" (for App Review).
2. Pinned `.safeAreaInset(.top)` banner "Connect your Crowly inbox →" → **PairCompanionView**.
3. Pair: camera scanner reads the QR `{companion_url, pairing_token, …}`, validates by hitting `GET /capabilities` over HTTPS, stores credentials in the **Keychain**, hands the companion the `routing_token`, dismisses with success. Manual "Enter URL and token instead" fallback for the QR-averse and as a Reviewer escape valve.
4. First real digest pulled → demo banner disappears. That transition is the "aha."

(Pairing wire-protocol detail lives in [`architecture.md`](architecture.md) → Pairing.)

## iOS specifics

**Use:** `AppIntent` for every action (inbox swipe, detail buttons, widget buttons) — one intent struct, three call sites, and free Siri/Shortcuts in M2; App Group container for the widget's small state + a JSON/SwiftData digest cache; `SFSafariViewController` for external sources (never an in-app `WKWebView`); `UNNotificationCategory` with one "Mark handled" action so the loop is answerable from the notification too (three answer surfaces — notification, widget, app — for the same loop); `ContentUnavailableView` for every empty/error state.

**Avoid in M1:** custom navigation/zoom transitions; **Lock Screen interactive widgets** (`.accessoryRectangular` can't host buttons — defer); `UNTextInputNotificationAction` for `free_text` from the lock screen (rough keyboard UX, same data path as the in-app sheet); background URL session for callbacks (synchronous POST + retry-on-foreground is enough).

## Cut order if M1 slips

1. Spotlight indexing / `.userActivity` → M2.
2. Large widget — small + medium covers the demo.
3. Override `⋯` on action items — overrides via deeplink-to-app only; widget never overrides.
4. `choice`/`free_text` **in the widget** — `yes_no`-only on the widget; other kinds live in the app's detail sheet. (`/capabilities` declares supported reply_kinds, so this degrades cleanly.)

**Keep no matter what — this triad *is* the M1 product:** the inbox cell with open-loop chips · the detail view with bound `yes_no` answers · the medium widget with two open loops + `yes_no` buttons.
