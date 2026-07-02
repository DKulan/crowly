# Crowly

Crowly is a native iOS **inbox/reader** for recurring AI-agent/automation outputs — AI news summaries, weather, local community updates, scheduled briefings, reminders. Stage: **M2 build in progress** (as of 2026-07-02). M1 is built and live end-to-end — the iOS app is verified on-device (unpaired = demo fixtures; paired = live companion pull, including a live-data home-screen widget as of Phase 1, 2026-07-02), and the design docs were rewritten away from the earlier "job-bound response loop" framing. The two-week behavioral validation gate (`docs/validation.md`) was **deliberately waived on 2026-07-02 by owner decision** (see that doc's waiver note); M2 proceeds on the owner's daily-use conviction rather than the formal gate. The repo/dir is `agent-output-inbox`; the product ships as **Crowly**.

The shape (so you can orient without reading everything): three artifacts — an **iOS app** (App Store) talks directly to a **companion service** (self-hosted per user on their own host — a bare `python3 -m companion` process or a Docker bundle; Docker is a packaging convenience, not a requirement — on a VPS or a personal computer) for all content on a pull/timeline-refresh cycle; an **emitter kit** (helper + Hermes skill) makes agents emit schema-valid digests.

## Working in this repo

Part design docs, part code. The **iOS app** (M1 demo mode) is a real Swift/SwiftUI codebase; the `docs/` are still the source of design intent. Keep docs consistent with decisions already recorded; reopening a settled tradeoff is a design change, so flag it rather than editing silently. Each doc is self-contained — read the one relevant to your task.

**Docs:**
- `README.md` — pitch, the three-artifact shape, doc map.
- `docs/concept.md` — positioning (reader-only), users, competition, risks.
- `docs/schema.md` — the digest contract and its versioning policy. **The contract is the product.**
- `docs/architecture.md` — the three artifacts; companion ingest/serve, TLS, pairing, privacy.
- `docs/emitter.md` — the `POST /ingest` wire contract + emitter kit (helper + Hermes skill); implementation in `emitter/` (Python stdlib helper, test companion stub).
- `docs/ux.md` — the M1 iOS interaction spec (inbox: read + archive; digest detail: header → bottom line → summary → sections → sources; the read-only widget).
- `docs/design-system.md` — tokens, components with SwiftUI sketches, FNV-1a job-color algo.
- `docs/validation.md` — the M1 two-week personal test and reader-shape kill criteria.
- `docs/roadmap.md` — M1 (single-user) → M2 (public-ready) build order.
- `docs/onboarding.md` — single-user install runbook (app + companion + emitter) with per-step ✅/🔨/👤 status; doubles as the team's debug checklist.
- `docs/deployment-learnings.md` — the real first VPS+iPhone deploy (2026-06-30): working path (Tailscale Funnel + shared docker net + Hermes emit skill) and every snag/fix — source material for the M2 `setup-crowly` installer.
- `docs/naming.md` — why "Crowly"; App Store name not yet claimed in App Store Connect.

**Code (iOS app):** `project.yml` is the source of truth — **XcodeGen** generates `Crowly.xcodeproj` (gitignored; run `xcodegen generate` after adding/moving files). Targets: `Crowly` (app; sources `App/` + `Shared/`), `CrowlyWidgetExtension` (`Widget/` + `Shared/`), `CrowlyTests` (Swift Testing). Deployment target **iOS 26** (Liquid Glass used freely; simulator builds run unsigned, device/TestFlight builds sign automatically with the personal team — see `project.yml` `DEVELOPMENT_TEAM`/`CODE_SIGN_STYLE`). `Shared/` is compiled into both app and widget — including the companion client + credential store (`Shared/Net/CompanionClient.swift`, `Shared/Net/KeychainStore.swift`) and the widget snapshot bridge (`Shared/Widget/WidgetSnapshotStore.swift`). **Demo mode is the unpaired path**, not the whole app: an unpaired app and its widget both render `Shared/Demo/` fixtures client-side (the App-Review / look-around experience). `App/ContentView.swift` is the root — it gates a **first-run onboarding carousel** (`App/Views/Onboarding/`, `@AppStorage("hasOnboarded")`) over `InboxView` in a `ZStack`, then hands off to pairing or dismisses into demo mode; QR pairing (VisionKit) and the carousel's placeholder crow art (`lottie-ios`, app target only — real `.lottie` assets not sourced yet) landed in M2 Phase 3b (`docs/ux.md` § Onboarding). App deeplinks: `crowly://digest/<id>`, `crowly://inbox`, `crowly://pair`, `crowly://onboarding` (last two are testing surfaces). Once paired, the app is companion-backed — it pulls `/list` live and the **widget fetches `/summary` on its own ~15-min timeline** (Phase 1, done). That live widget path adds an App Group (`group.com.crowly`, snapshot fallback) and a shared Keychain access group (both targets read the same pairing token), declared on both targets in `project.yml`.

Build & test (iPhone 17 Pro / iOS 26 sim):
`xcodegen generate && xcodebuild -project Crowly.xcodeproj -scheme Crowly -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build {build|test}`

Not automatable: the **home-screen widget render** (simulator can't add widgets headlessly — needs a manual check). **Verified manually on device 2026-06-30** — it renders on the real iPhone home screen.

## Invariants (hard-won; changing one is a design decision, not a refactor)

- **The schema is content-only.** Title, bottom line, summary, sections, sources, urgency — no routes, no questions, no callbacks. If a digest wants the user to do something, it says so in prose; acting is out of scope for Crowly.
- **The schema is versioned and additive-only, with unknown fields preserved verbatim.** Never remove or repurpose a field; new fields are optional with safe defaults; the companion stores the whole digest blob so unknown fields survive a round-trip through an older companion.
- **The companion is ingest + store + serve.** No callback execution, no agent integration beyond receiving digests. (This is the reader-pivot's biggest architectural shift — earlier drafts had the companion executing routes.)
- **The inbox is read + archive only.** Opening a digest marks it read; archive (with undo) is the only triage move. No "handled," no "mute job," no snooze, no intent chips.
- **Content stays on the user's VPS.** The app pulls directly from the companion over HTTPS; no central service ever sees content or metadata.
- **The widget is read-only.** Latest digests + unread count; `Link`-deeplink rows; **no `Button(intent:)` anywhere in the widget**. Reading happens in the app, not on the home screen. The widget refreshes on its own `TimelineProvider` schedule.
- **M1 gates M2 — waived 2026-07-02.** The two-week behavioral validation was the designed gate; the owner waived it (running on daily-use conviction) and M2 build proceeds. The *rationale* still stands as design history — if M2 stalls or the reader stops earning its tap, `docs/validation.md`'s kill criteria are the honest fallback. Don't silently un-waive it, and don't cite it as still-blocking.
- **Secrets** live in the user's `/opt/data/.env` — never in any vault or this repo.

## Git identity (personal, on a multi-account machine)

This is a **personal** project; the machine's global git identity is the **work** account, so this repo uses an explicit per-repo personal identity — local `user.email danny.kulangiev@gmail.com` / `user.name "Daniel Knight"`, and (when a remote is added) `git@github.com-personal:DKulan/<repo>.git`. Never let a `dkulangiev@salesforce.com` commit land here. See the `git-personal-vs-work-identity` memory.
