# Hermex takeaways for Crowly

Date: 2026-07-03
Source reviewed: [`uzairansaruzi/hermex`](https://github.com/uzairansaruzi/hermex) at commit `8fc73b9`
Purpose: capture what Crowly can borrow from Hermex without drifting away from Crowly's reader-only product shape.

## Summary verdict

Hermex is not a feature model for Crowly. Hermex is a dense native iOS **control plane** for a self-hosted Hermes WebUI server: chat, sessions, tasks, skills, memory, workspace browsing, streaming, attachments, and operational controls.

Crowly is intentionally different: a calm, read-only inbox/widget for completed recurring agent digests.

The useful takeaway is therefore not "copy Hermex's surfaces." The useful takeaway is:

> Treat the self-hosted backend contract, onboarding, diagnostics, CI, and public-readiness workflow as product surfaces — not internal implementation details.

## Quick comparison

| Area | Hermex | Crowly implication |
|---|---|---|
| Product shape | iPhone cockpit/control plane for a self-hosted Hermes WebUI server | Do **not** copy chat/control/admin surfaces; preserve read + archive only |
| Positioning | "Your server. Your iPhone. No middleman." | Crowly should lead with the same self-hosted privacy clarity for digests |
| Setup model | Bring your own server; app teaches URL/password/tunnel basics | Crowly should make companion reachability/pairing diagnostics first-class |
| Contract posture | `CONTRACT_TESTS.md`, `UPSTREAM_TESTED_SHA`, endpoint matrix, upstream-watch workflow | Crowly needs a companion/app/emitter smoke harness and schema/version pin discipline |
| Public-readiness | README, CI workflows, TestFlight docs, privacy/security docs, issue templates | Crowly should add the minimum public-release skeleton before broad TestFlight/App Store |
| Complexity | Large app: 254 Swift files, 79 test files, many features | Crowly should not widen prematurely; copy discipline, not scope |

## What Crowly should borrow

### 1. Sharper public README framing

Hermex's README is immediately legible:

> Control your self-hosted Hermes agent from your iPhone.
> Your server. Your iPhone. No middleman.

Crowly's public-facing README/App Store copy should be similarly direct:

> Crowly is a private iPhone inbox for the digests your agents produce.
> Your agents. Your server. Your iPhone. No middleman.

Recommended README additions:

- concise feature bullets: digest inbox, home-screen widget, self-hosted companion;
- explicit "what it is / is not" section;
- setup paths: Tailscale Funnel, existing reverse proxy, demo mode;
- connection troubleshooting checklist;
- screenshots once App Store/TestFlight assets exist.

### 2. Pairing diagnostics as product UX

Hermex has a visible "Test Connection" step and practical connection troubleshooting. Crowly should do the same for pairing.

Before saving a pairing, the app should distinguish:

| Diagnostic | User-facing meaning |
|---|---|
| `GET /health` returns Crowly health | URL reaches the companion |
| `/health` returns `404` | tunnel/proxy points at the wrong service |
| connection refused / timeout | companion is down or port is not exposed from the host/container |
| authenticated `GET /summary` succeeds | token works and widget path is viable |
| schema/version unsupported | companion needs update before pairing |

This matters because the app can otherwise accept a URL/token that looks plausible but cannot serve Crowly data. The recent Tailscale/Funnel confusion is the exact failure mode this would catch.

### 3. Companion contract-smoke discipline

Hermex treats server API drift as a first-class risk. Crowly controls both app and companion, but once strangers install a companion and later update the app, drift still exists.

Recommended Crowly artifacts:

```text
COMPANION_TESTED_SHA
COMPANION_TESTED_SCHEMA
scripts/smoke_companion.py
docs/contract-smoke.md
```

Minimum live-smoke flow against a disposable digest:

1. `GET /health`
2. `POST /ingest` with valid v1 digest
3. `POST /ingest` with valid v2 digest / content blocks
4. `GET /list`
5. `GET /summary`
6. `POST /state` mark-read
7. `POST /state` archive
8. unknown top-level fields round-trip
9. unknown content block fields/types survive storage
10. old/new schema negotiation produces the intended app warning or fallback

This is probably the highest-leverage Hermex lesson: Crowly's digest contract is the product, so contract drift should be visible before users hit it.

### 4. Minimal CI / release-readiness skeleton

Hermex already has mature release infrastructure: PR CI, TestFlight workflows, upstream watch, issue templates, TestFlight runbooks, and privacy/security docs.

Crowly does not need the full stack yet, but before broader public testing it should add:

- `.github/workflows/pr-ci.yml`;
- companion Python tests;
- emitter/schema validation tests;
- Swift tests on macOS runner where available;
- `git diff --check`;
- plist/privacy manifest lint once App Store metadata files exist;
- `SECURITY.md`;
- hosted/source privacy policy doc;
- issue and PR templates;
- TestFlight/App Store runbook.

### 5. Troubleshooting copy that names likely failures

Hermex's setup docs tell users to check server process, `/health`, tunnel/proxy, URL, and password. Crowly should provide equally concrete copy.

Recommended Crowly troubleshooting matrix:

| Symptom | Likely cause | Fix direction |
|---|---|---|
| `/health` returns `404` | tunnel/proxy hits Hermes or another service, not Crowly | repoint proxy/Funnel to the companion |
| `curl :8787` fails from host | companion is trapped in container namespace or bound to loopback | bind `0.0.0.0`, publish port, or run companion on host |
| app pairs but widget stays demo/stale | widget cannot read shared Keychain/App Group data or locked-device access path fails | verify keychain accessibility/snapshot fallback |
| `/summary` auth fails | token mismatch or stale pairing token | rotate/re-pair token |
| companion on laptop sleeps | pull model cannot wake sleeping host | use VPS/always-on host or accept stale snapshot |

## What Crowly should not borrow

### Do not become a control plane

Hermex's surfaces — chat, session control, task management, skills browsing, workspace/file tools — are valuable for Hermex but would violate Crowly's wedge.

Crowly should keep:

- inbox;
- detail reader;
- archive with undo;
- search/filter;
- read-only widget;
- setup/pairing/settings.

No chat, no agent controls, no task admin, no "reply from widget," no action buttons.

### Do not add Live Activities yet

Hermex's Live Activities make sense for long-running active agent sessions. Crowly's unit is a completed digest. A Live Activity would imply an in-progress execution model that Crowly intentionally avoids.

Possible later exception: companion setup progress or digest-generation progress, but not M2.

### Do not add multi-server/multi-companion yet

Hermex's `ServerRegistry` and per-server headers are useful for a cockpit used across multiple agents. Crowly may eventually support personal/family/work companions, but adding that now widens the product before the single inbox is proven.

### Do not add a share extension yet

Hermex's share extension is natural for sending content into a chat agent. Crowly should only consider a share extension after the generic input layer is a real product goal. For now, agents and scheduled emitters fill the inbox.

## Recommended Crowly backlog

| Priority | Item | Why |
|---|---|---|
| P0 | Add companion live-smoke script/checklist | Protect app/companion/emitter contract before public users |
| P0 | Add pairing diagnostics for `/health`, authenticated `/summary`, schema/version | Prevent bad QR/manual pair flows |
| P1 | Strengthen README "Getting started" using Hermex's direct self-hosting framing | Makes self-hosting understandable to strangers |
| P1 | Add minimal GitHub CI | Stops schema/emitter/Swift regressions |
| P1 | Add troubleshooting copy for 404/refused/token/widget failures | Matches real setup failure modes already observed |
| P2 | Add App Store/TestFlight/privacy/security runbook files | Needed before broader TestFlight/App Store |
| P2 | Add companion/app tested-version pin files | Helps debug app-newer-than-companion reports |
| Later | Multi-companion registry | Only if real users ask for personal/family/work separation |
| Later | Share extension | Only after generic ingest becomes a product goal |
| Avoid | Chat/control/tasks/skills surfaces | Violates Crowly's reader-only wedge |

## Best single takeaway

The best thing to steal from Hermex is not UI density or feature breadth. It is the way Hermex treats a self-hosted backend as a user-facing contract.

For Crowly, the app should not just say "pairing failed." It should be able to say:

- "This URL is reachable, but it is not Crowly.";
- "This companion is reachable but too old.";
- "The token works for health but not summary.";
- "The widget is showing a last-known snapshot because the companion is unreachable.";
- "Your companion is probably asleep.";
- "Your tunnel is hitting the wrong service."

That would make Crowly feel more trustworthy to non-expert users without adding any new reader complexity.
