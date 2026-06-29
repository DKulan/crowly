# Crowly

Crowly is a native iOS inbox + interactive widget for recurring AI-agent/automation outputs, with a **job-bound response loop**. Stage: **M1 demo-mode iOS app built and verified on-device** (since 2026-06-29); the design docs remain the source of design intent. The repo/dir is `agent-output-inbox`; the product ships as **Crowly**.

The shape (so you can orient without reading everything): four artifacts — an **iOS app** (App Store) talks directly to a **companion service** (Docker, self-hosted per user on their own VPS) for all content and callbacks; a tiny **push relay** (central, project-run) exists only because APNs can't be self-hosted; an **emitter kit** (helper + Hermes skill) makes agents emit schema-valid digests.

## Working in this repo

Part design docs, part code. The **iOS app** (M1 demo mode) is a real Swift/SwiftUI codebase; the `docs/` are still the source of design intent. Keep docs consistent with decisions already recorded; reopening a settled tradeoff is a design change, so flag it rather than editing silently. Each doc is self-contained — read the one relevant to your task.

**Docs:**
- `README.md` — pitch, the four-artifact shape, doc map.
- `docs/concept.md` — positioning, users, competition, risks, resolved/open questions.
- `docs/schema.md` — the digest + callback contract and its versioning policy. **The contract is the product.**
- `docs/architecture.md` — the four artifacts; routing, TLS, pairing, push, privacy.
- `docs/ux.md` — the M1 iOS interaction spec (inbox, digest detail, widget, intent→visual lexicon).
- `docs/design-system.md` — tokens, components with SwiftUI sketches, FNV-1a job-color algo, the `Intent` lexicon.
- `docs/validation.md` — the M1 two-week personal test and kill criteria.
- `docs/roadmap.md` — M1 (single-user) → M2 (public-ready) build order.
- `docs/naming.md` — why "Crowly"; App Store name not yet claimed in App Store Connect.

**Code (iOS app):** `project.yml` is the source of truth — **XcodeGen** generates `Crowly.xcodeproj` (gitignored; run `xcodegen generate` after adding/moving files). Targets: `Crowly` (app; sources `App/` + `Shared/`), `CrowlyWidgetExtension` (`Widget/` + `Shared/`), `CrowlyTests` (Swift Testing). Deployment target **iOS 26** (Liquid Glass used freely; simulator-only, unsigned). `Shared/` is compiled into both app and widget. M1 is **demo mode** — fully client-side from `Shared/Demo/` fixtures, no companion/relay/App Group/signing.

Build & test (iPhone 17 Pro / iOS 26 sim):
`xcodegen generate && xcodebuild -project Crowly.xcodeproj -scheme Crowly -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build {build|test}`

Not yet verifiable via automation: the **home-screen interactive widget render** (simulator can't add widgets headlessly — needs a manual check).

## Invariants (hard-won; changing one is a design decision, not a refactor)

- **Schema routes are intents** (`task | note | followup | none`), never tool names — resolved per-companion by declared capability, with a terminal "stays in the inbox, logged" fallback so nothing is dropped.
- **The companion executes callbacks**, not the agent. Only `followup` involves the agent, and its result returns as a *new digest* — the loop never leaks back into chat.
- **The schema is versioned and additive-only.** Never remove or repurpose a field; unknown fields are ignored, not fatal, on both sides.
- **Content stays on the user's VPS.** The relay holds only `routing_token → device_token`, never logs pointer metadata, and is **best-effort, never critical-path** (a relay outage degrades to pull, not to broken).
- **Push is a thin pointer gated on open loops** (an unanswered question/action), not on `urgency` and not carrying digest content.
- **M1 gates M2.** Don't spec or build public-only work (demo mode, stranger TLS, privacy, relay-for-strangers) as if the two-week validation already passed.
- **Secrets** live in the user's `/opt/data/.env` — never in any vault or this repo.

## Git identity (personal, on a multi-account machine)

This is a **personal** project; the machine's global git identity is the **work** account, so this repo uses an explicit per-repo personal identity — local `user.email danny.kulangiev@gmail.com` / `user.name "Daniel Knight"`, and (when a remote is added) `git@github.com-personal:DKulan/<repo>.git`. Never let a `dkulangiev@salesforce.com` commit land here. See the `git-personal-vs-work-identity` memory.
