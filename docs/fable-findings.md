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

> **Reconciled 2026-07-02.** Items 1–2 are done (see the resolution notes above). Items **4 and 6 are overtaken by events**: the owner **waived the two-week M1 validation gate on 2026-07-02** (proceeding on daily-use conviction), so "start the clock only after the live widget" / "avoid further M2 work until the M1 validation produces evidence" no longer describe the plan. The kill criteria are retained as a fallback (`docs/validation.md`); the review's original wording is preserved below as design history.

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

---

# Follow-up Fable 5 Findings — Post-redesign / build 6

Date: 2026-07-03
Reviewer: Claude Code using `claude-fable-5` with `--fallback-model opus --effort high`
Scope: read-only product/code/architecture inspection after pulling latest `main` through commit `9a6d208` (`chore: bump build to 6 for TestFlight; declare export-compliance exempt`).

## What was inspected

The follow-up review reported inspecting:

- `docs/fable-findings.md` and current docs under `docs/`
- `CLAUDE.md`, `README.md`
- recent git history since the first findings
- iOS app, shared model/theme/network code, widget code, and tests under:
  - `App/`
  - `Shared/`
  - `Widget/`
  - `Tests/`
- companion and emitter code under:
  - `companion/`
  - `emitter/`
- `.claude/agents` and `.claude/skills` additions, enough to assess usefulness/noise

Not run or built during this review:

- Xcode project / Swift tests
- Python companion/emitter suites

Reason: Fable reported that test execution was denied by the permission gate in its session. Runtime behavior below is therefore source-inspection-based unless otherwise stated.

## Overall verdict

Fable 5 judged Crowly as **stronger overall**, with one important caveat:

> Stronger, with one new P1 the redesign sprint shipped right past.

The prior review's two P0s are largely closed in code:

- `/pair` is gated default-off and wired through compose files.
- The widget now has a real live-data path.

However, Fable found that recent work was heavily weighted toward brand/TestFlight polish while a trust-critical widget failure mode may remain: **the paired widget can silently degrade to demo fixtures after a locked-device refresh and then stop refreshing.**

## Material improvements since the prior review

### `/pair` exposure appears fixed in code

Fable found:

- `companion/server.py` gates `/` and `/pair` unless `CROWLY_PAIR_ENABLED` is set.
- Gate behavior covers path-normalization cases such as query/trailing slash variants.
- Unknown paths return auth-gated responses rather than route enumeration help.
- `/health` no longer leaks digest count.
- Compose files include the pairing flag wiring.

Remaining operator caveat: the live token still needs confirmed rotation; the code fix does not revoke any token that was already exposed.

### Live widget path shipped

Fable found the widget path is now real:

- Widget fetches `/summary` off-main.
- Uses an approximately 15-minute `.after` reload policy.
- Falls back to App Group snapshot on fetch failure.
- Both targets declare App Group and shared Keychain group entitlements in `project.yml`.
- The widget remains read-only; no `Button(intent:)` pattern was found.

### Schema v2 content blocks are directionally good

Fable judged schema v2 content blocks as a real product improvement, not mere polish:

- Additive display-only block types.
- No action-shaped fields or callback semantics.
- Unknown block types can degrade/preserve enough for forward compatibility in the current companion-backed model.
- `docs/schema.md` explicitly guards against callout-as-button drift.

### Docs and design discipline mostly held

Fable found that the docs mostly stayed honest despite fast iteration:

- Validation-gate waiver is recorded across docs.
- `architecture.md` marks pagination/rate-limiting as planned, not shipped.
- Redesign was reconciled with `design-system.md`.
- Brand tokens are centralized in `Shared/Theme/Tokens.swift`.

## New / remaining P0-P1 risks

### P0

Fable reported **no current P0s** from source inspection.

### P1: widget may fall back to fake data after locked-device refresh

Fable's highest-priority finding:

- `Shared/Net/KeychainStore.swift` stores the pairing token with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- WidgetKit can run `getTimeline` while the device is locked, especially during overnight/background budget refreshes.
- If the widget cannot read the token while locked, it can treat itself as unpaired.
- The unpaired branch in `Widget/CrowlyWidget.swift` can return demo fixture data with `.never` policy.

Likely effect if source reading matches device behavior:

- A paired user can wake up to a widget showing fake demo digests as if real.
- The widget may then freeze until the app foregrounds.
- This is worse than the old demo-only widget because it is intermittent and easy to mistake for live content.

Recommended fix:

1. Store the shared pairing secret as `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
2. In the widget's unpaired/failure branch, prefer an existing App Group snapshot over demo fixtures when a snapshot exists.
3. Verify on-device after a locked overnight refresh; simulator verification is insufficient.

### P1: token rotation still needs live confirmation

Fable found the code/runbook now treat the prior pairing token as exposed, but source inspection cannot prove the live VPS token was rotated.

Risk:

- If the old token is still active, the `/pair` gate fix does not remediate prior exposure.
- The token may have existed in container stdout / `docker logs` and Hermes/env/transcripts.

Recommended action:

- Confirm or run the token rotation from `docs/deployment-learnings.md` before relying on the live deployment.

## P2 findings

### Onboarding docs can recreate the `/pair` mistake

Fable flagged that `docs/onboarding.md` and comments in compose files may still imply `/pair` is always available. An operator following stale instructions may set `CROWLY_PAIR_ENABLED=1` permanently and recreate the exposure.

Recommended fix: update onboarding to describe `/pair` as a temporary setup mode that should be disabled after pairing.

### Public companion should set a request timeout

Fable suggested adding a small request timeout for the public Funnel-facing companion, e.g. `Handler.timeout = 30`, to reduce slowloris-style exposure.

### Optimistic mark-read race remains

The prior optimistic state mirror issue appears still open:

- `DigestStore.markRead` updates local state and sends detached `POST /state`.
- A timed refresh can replace local state with a stale server snapshot before the mirror completes.

Likely impact:

- A digest may briefly flip back unread after opening.
- This is trust-eroding in daily use and matters more now that the formal validation gate was waived.

### Missing un-pair/disconnect path

Fable found `DigestStore.didDisconnect()` but no user-facing call path. Before broader TestFlight/public use, there should be a minimal un-pair path.

## P3 / tracked issues

Fable also noted lower-priority items:

- `created_at` still appears text-sorted without UTC normalization on ingest, mitigated by the canonical emitter stamping UTC.
- `/list` remains unbounded.
- `DigestSection.id = heading` can still collide on duplicate headings.
- URL handling should ensure `sources[].url` only opens expected schemes such as `http`/`https`.
- Companion subpath URLs may silently break because client paths are root-relative.

## Product/design critique

Fable's product read:

- The direction is still on-thesis.
- Schema v2 content blocks are real product depth because they make agent digests more readable.
- The redesign did not violate the core reader-only invariants.
- But the last sprint leaned heavily toward polish: icon, palette, onboarding art, Lottie removal, TestFlight build churn.

Blunt interpretation:

> Build 6 is fine. Further visual polish before the daily-use trust bugs are fixed is procrastination with a progress bar.

Fable specifically warned that with the validation gate waived, the daily-use loop is now the evidence base. Bugs that make the widget show fake data or make read-state flicker undermine the instrument being used to judge Crowly.

## Engineering critique

Positive findings:

- Companion auth ordering appears correct on every route inspected.
- Entitlement ordering hazards are documented in `project.yml`.
- Swift widget provider code appears deliberate about sendability.
- Git identity remains personal; no Salesforce/work-account commits were observed.

Concerns:

- Tests were not actually executed in this review.
- Some tests may be tautological or misleading, especially around content-block preservation behavior.
- Comments may overclaim round-trip fidelity for unknown fields inside known block types; production may not rely on this because the companion stores the canonical digest blob.
- `CrowlyProvider` hardcodes `KeychainStore()` and `DigestStore` leans on shared/global session behavior, making the highest-risk runtime paths harder to test directly.
- `.claude/agents` are mostly useful because they encode hard-won invariants, but several `.claude/skills/revyl-*` additions appear irrelevant/noisy for Crowly.
- `run-crowly/SKILL.md` may be stale if it still claims no signing/App Group or an outdated test count.

## Recommended order of work

Fable recommended this priority order:

1. Confirm or run live VPS token rotation.
2. Fix widget keychain accessibility and demo fallback behavior.
3. Fix the mark-read refresh/flicker race.
4. Run Python suites and the Swift suite; record actual results.
5. Patch docs/ops drift:
   - onboarding `/pair` gate instructions;
   - companion timeout;
   - App Store naming status;
   - roadmap waiver residue;
   - misleading/tautological block test;
   - stale `run-crowly` skill.
6. Add a minimal un-pair path before any stranger uses a build.
7. Resume daily-use validation and M2 installer work only after the trust bugs above are addressed.

## What not to do next

Fable explicitly advised against:

- More brand/visual builds before trust bugs are fixed.
- Starting schema v3.
- Building generic ingest/input layers such as webhooks/RSS yet.
- Adding broad settings surface beyond un-pair.
- Expanding client-side digest encoding just to chase round-trip comments.
- Re-litigating or performatively un-waiving the validation gate.

## Interpretation

The follow-up review is not a reversal of the first review. It says Crowly is now closer to real use, and therefore smaller trust bugs matter more:

1. The live deployment needs confirmed token rotation.
2. The widget must never silently present fake data as live data.
3. Read-state changes must feel reliable.

After that, usage evidence matters more than more polish.
