# Fable 5 Findings — Crowly Repo Inspection

Date: 2026-07-01
Reviewer: Claude Code using `claude-fable-5`
Session: `6375e1a9-d01c-4a05-bb75-5283941ac229`
Scope: read-only product/code/architecture inspection of the Crowly repository.

## What was inspected

The Fable 5 review reported inspecting:

- `README.md`
- `docs/concept.md`
- `docs/schema.md`
- `docs/architecture.md`
- `docs/validation.md`
- `docs/roadmap.md`
- `docs/onboarding.md`
- `docs/deployment-learnings.md`
- Companion service:
  - `companion/server.py`
  - `companion/store.py`
  - `companion/docker-compose.local.yml`
- Emitter:
  - `emitter/crowly_emit.py`
  - emitter Hermes `SKILL.md`
- iOS core:
  - `Shared/Models/Schema.swift`
  - `App/Net/CompanionClient.swift`
  - `App/Store/DigestStore.swift`
  - `App/Security/KeychainStore.swift`
  - `Widget/CrowlyWidget.swift`
  - `App/Views/InboxView.swift`
  - `App/CrowlyApp.swift`
  - `App/ContentView.swift`
  - `project.yml`
- Git log and `.gitignore`

Not run or built during this review:

- Xcode project
- Swift tests
- `test_end_to_end.py`

The reviewer skimmed but did not deeply inspect:

- `docs/design-system.md`
- `docs/ux.md`
- detail and pairing views
- fixtures
- test bodies

## Overall verdict

Fable 5 judged Crowly as coherent and unusually honestly framed.

Positive findings:

- The reader-only pivot is directionally correct.
- The schema is genuinely content-only.
- The inbox is genuinely read/archive-only.
- `docs/validation.md` names the real risk: single-user pull.
- The “no parallel Telegram channel during validation” constraint avoids a rigged comparison.
- The self-hosted recurring-agent-digest niche is small but real.
- Code quality is stronger than typical demo-ware.
- Core invariants are enforced in both directions:
  - `_`-prefixed reserved-field rejection.
  - `{digest, state}` wrapper keeps state outside the canonical digest blob.
  - state survives re-ingest.
  - emitter ISO parsing is aligned with Swift decoding.

Blunt summary from the review:

> The product thinking and code are better than most funded projects I see, but the repo is currently celebrating “the software is built” while the single most thesis-critical component is a stub and the deployed instance is leaking its credential.

## Critical finding 1: `/pair` may expose the bearer token

Fable 5 flagged a live security concern in `companion/server.py`:

- `GET /`
- `GET /pair`

appear to return pairing information, including the bearer token, without authentication.

The concern is amplified by the current deployment path described in `docs/deployment-learnings.md`:

- Crowly is reachable through Tailscale Funnel.
- Funnel exposes a public HTTPS hostname.
- Public HTTPS hostnames may appear in Certificate Transparency logs.
- If `/pair` is reachable publicly, anyone who discovers the Funnel URL can fetch the pairing token.

Impact if reachable publicly:

- read access to digests;
- write/ingest access to the companion;
- current token should be treated as exposed.

Recommended fix:

1. Gate `/pair` behind an explicit env flag such as `CROWLY_PAIR_ENABLED`.
2. Default pairing off after initial setup.
3. Prefer one-shot/temporary pairing if possible.
4. Rotate the current token after closing the exposure.

Priority: **P0 before further real usage**.

## Critical finding 2: live widget is still demo-only

> **Resolved 2026-07-02 (M1 Phase 1 — live widget).** The widget now fetches `GET /summary` on its own `TimelineProvider` when paired (with a `.after(now + ~15min)` reload floor), renders the server's rows + authoritative `unread_count`, and falls back to an App Group (`group.com.crowly`) snapshot when offline; unpaired still shows `DemoFixtures`. `project.yml` declares the shared Keychain access group + App Group entitlements on both targets, and `KeychainStore` now uses a fixed shared service (`com.crowly.shared`) instead of the bundle id. The recommended fixes below are all done except this doc's original ask #4 — "only start the validation clock after the widget reflects live data" — which is now *unblocked* (see `docs/roadmap.md` M1 item 4). Details: `docs/architecture.md` § Widget data path.


Fable 5 found that `Widget/CrowlyWidget.swift` appears to use demo data rather than live companion data:

- Reads `DemoFixtures`.
- Uses `.never` timeline policy.
- Does not fetch `/summary`.
- Does not appear to use an App Group/shared cache path.
- `project.yml` does not yet define entitlements for the needed shared container/keychain path.
- `KeychainStore` service is derived from `Bundle.main.bundleIdentifier`, which differs between app and widget, so widget access will require explicit shared-group treatment.

This conflicts with the M1 validation thesis:

- `docs/validation.md` treats the widget as the primary habit cue.
- `docs/roadmap.md` lists a live widget using `/summary` as an M1 item.
- `docs/architecture.md` describes the widget refresh behavior as a committed property.

Risk:

- If the two-week validation starts now, the home-screen widget shows static fake digests and a fake unread count.
- That invalidates the widget-glance criterion and may train Daniel to ignore the widget.
- It tests a different product than the stated widget-first thesis.

Recommended fix:

1. Add App Group/shared storage and shared keychain/access group configuration.
2. Have the app write latest summary state for widget use, or have the widget safely fetch `/summary`.
3. Use a real timeline reload policy matching iOS constraints.
4. Only start the two-week validation clock after the widget reflects live data.

Priority: **unfinished M1, not M2 scope**.

## Smaller findings

### `created_at` text sorting can misorder mixed offsets

`created_at` appears to be denormalized and sorted as text. The validator accepts timezone offsets, and docs include offset examples. Mixed offsets can break chronological ordering.

Likely impact:

- The app may re-sort `/list` client-side.
- `/summary` and widget “latest” behavior are more exposed.

Recommended fix: normalize the denormalized sortable timestamp to UTC on ingest.

### Optimistic state mirror race

`DigestStore.markRead` flips local state and fires a detached `POST /state`. If a refresh lands before the mirror completes, the server’s stale snapshot can overwrite local state temporarily.

Likely impact:

- Low priority for single-user M1.
- Could cause trust-eroding “why did that go unread again?” moments.

### Emitter idempotency is narrower than the skill wording

The emitted id hashes content. Exact-payload retries are safe, but an LLM cron that regenerates prose for the same day/job can produce a different id and duplicate a same-day digest.

Recommended decision: decide whether duplicate same-day digests matter for M1; if yes, use a stable logical id or caller-supplied id for recurring jobs.

### Documentation drift

Fable 5 found docs that may describe aspirational or stale behavior as if already implemented:

- `docs/architecture.md` mentions paginated `/list`, QR pairing, and auth rate limiting.
- `CLAUDE.md` still describes M1 as demo mode with no companion/App Group/signing, which conflicts with recent implementation/deployment work.
- `docs/onboarding.md` appears closer to current reality than some older docs.

Recommended fix: mark future behavior explicitly or update docs to match current code.

> **Partially resolved 2026-07-02.** `docs/architecture.md` already marks paginated `/list`, QR pairing, and auth rate limiting as *planned, not shipped* (§ Components / § Pairing / § Security). The `CLAUDE.md` "demo mode … no companion/App Group/signing" line was de-staled in the M1 Phase 1 doc pass — M1 is now described as demo-when-unpaired / live companion-backed when paired, with the live widget's App Group + shared Keychain group + device signing. The `App/Net/` → `Shared/Net/` move (this review cited `App/Net/CompanionClient.swift`, `App/Security/KeychainStore.swift`) is reflected in the doc references.

### Minor SwiftUI identity issue

`DigestSection.id = heading` can break or warn on duplicate section headings in `ForEach`.

Likely impact: low, but easy to fix later with a stable section id or index-based display model.

### `/health` leaks digest count

Unauthenticated `/health` appears to expose digest count.

Likely impact: acceptable for M1 unless public exposure/privacy bar changes.

## Recommended order of work

1. Close `/pair` exposure and rotate the token.
2. Build the live widget path:
   - App Group/shared storage;
   - shared keychain/access group;
   - live `/summary` or cached summary source;
   - real timeline reload policy.
3. Sync `CLAUDE.md` and `docs/architecture.md` with current reality.
4. Start the two-week M1 validation clock only after the live widget is in place.
5. Claim the App Store name “Crowly”.
6. Avoid further M2 work until the M1 validation produces evidence.

## Interpretation

The review does not argue against Crowly. It argues that the project is close enough to real use that two specific issues matter immediately:

1. A potential public credential exposure in pairing.
2. A demo-only widget undermining the central validation loop.

Both are practical, bounded fixes. After those, the next milestone should be usage evidence, not more architecture or distribution work.
