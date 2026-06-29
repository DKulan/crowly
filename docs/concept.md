# Concept

## One-line idea

**Crowly** — a native iOS app + interactive widget that acts as a dedicated inbox **and response surface** for recurring AI-agent and automation outputs — so scheduled digests don't get buried in chat, and so agent questions/actions can be answered **in context, bound to the job that raised them**. Built for people who self-host their own agent (Hermes first): they run a small **companion service** on their own VPS, the app talks to it directly, and a tiny central relay only delivers push.

## The pattern this serves

1. User creates agents/automations.
2. Agents begin producing scheduled outputs (briefings, watchers, digests).
3. Outputs land in chat/email/Slack/Discord.
4. The channel becomes notification sludge — no grouping, state, archive, or search.
5. Worse: when an agent asks a question or surfaces an action, the reply is loose text the agent must disambiguate.
6. User needs a clean review layer **with a bound response loop**.

## Framing

**Bad framing:** "AI news summary app." Crowded, weakly differentiated, becomes a reader.

**Right framing:** "A mobile inbox and control surface for scheduled AI-agent reports, where every question/action is bound to its job — and your data stays on your own server."

The job is not reading. It's **reviewing, triaging, archiving, and responding** to recurring agent output. Two things are the moat:

1. **The bound loop.** A reply arrives as `{job_id, question_id, answer}`, resolved against the question's own `on_answer` route and executed deterministically by the companion. Chat structurally can't do this. (Note: the loop is *stateless handlers keyed on job_id* — not literal "resume the agent process." The differentiation is **structured, bound, routable answers**, not context resumption.)
2. **The interactive widget.** Answer a `yes_no`/`choice` question from the home screen — the reason to be native, and the marketing artifact.

## Positioning lines (for X/article later)

- "Your daily/weekly AI briefings, organized outside your chat apps."
- "A dedicated inbox for your agents' recurring reports — answer them in one tap from your home screen."
- "What did my agents find for me today, and what do they need from me?"
- "A review and response layer for scheduled AI work — running on your own server."

## Target users

- **First:** Daniel himself (Hermes deployment) — the M1 validation.
- **Then:** other **Hermes self-hosters**, who already run a VPS and can deploy the companion the same way they deployed Hermes.
- Broader self-hosted AI/automation users later. Not a mainstream consumer app: the public App Store listing is mostly a **demo + a funnel to the self-hosting docs** for the few who self-host. That's consistent with the power-user audience.

## Adjacent products / competition

| Category | Examples | Gap |
|---|---|---|
| AI RSS/news readers | Bulletin, TodayRSS, Feedly AI | Content feeds, not arbitrary agent outputs; no response loop. |
| Read-it-later | Readwise Reader, Matter | Great for articles, weak for operational digests + agent questions. |
| Automation digests | Zapier Digest, Make/n8n email | Backend batching exists; review UX is email/chat; no binding. |
| Notification summaries | Apple Intelligence | Ephemeral, not a durable workflow inbox. |
| Chat surfaces | Telegram, Slack, Discord, email | Easy delivery, poor triage; replies are ambiguous to the agent. |
| Agent consoles | Platform dashboards | Tied to one platform, rarely mobile/widget-first, never self-hosted-data. |

None cleanly owns: agent-agnostic in *delivery*, mobile/widget-first, **with a job-bound response loop and self-hosted data**.

## Risks

1. **Niche timing.** Few people run recurring agent jobs *and* self-host. Audience is small/technical now. Mitigation: built for the Daniel-of-6-months and the showcase power-user.
2. **Platform capture.** Agent platforms may build their own inboxes. Defense: cross-agent delivery, self-hosted data, widget-first.
3. **Reader trap.** If it becomes another AI reader, differentiation collapses. Defense: the bound loop + the widget, not the card list, are the product. (Watch the capability-degradation case: a user with no Todoist/Obsidian must still get the *bound* answer, even if it only lands "saved in the inbox" — the binding is the moat, not the richness of the sink.)
4. **Overbuilding.** The four-artifact public scope is large. Defense: **M1 gates M2** — build and behaviorally validate the single-user slice before the public-only layer.
5. **Notification sludge.** Defense: thin push **gated on open loops** (an agent needs you), handled state, weekly cleanup.
6. **The relay is a permanent, single-operator dependency.** Push can't be self-hosted (APNs is bound to the project's Apple credential), so the project funds and runs the relay forever, and it's a single point of failure for the cue. Defense: relay is **best-effort, never critical-path** — the app stays fully usable on pull + periodic refresh when it's down.
7. **(The real one) Single-user pull.** Personal-first projects die when the builder stops reaching for it. Validation must be ruthless: no unprompted use in two weeks → stop at M1.

## Resolved grill questions (2026-06-29)

- Is the core a reader, inbox, action hub, or control plane? → **Control plane with a bound, stateless response loop.**
- What does "resume job context" mean? → It doesn't; **stateless handlers keyed on `job_id`**. Moat = structured/bound/routable answers.
- Concrete tools or intents in the schema? → **Intents** (`task | note | followup | none`), resolved per-companion by capability.
- Who executes callbacks? → **The companion**, on the user's VPS. Only `followup` involves the agent, and it returns as a new digest.
- Single-user or public? → **Public**, for Hermes self-hosters, via the companion model (not a hosted SaaS).
- What's the cue? → **Push** (APNs via the relay), thin and gated on open loops; home-screen icon as backstop.

## Still-open grill questions

- What's the first widget layout Daniel keeps on his home screen?
- Which outputs are most valuable: morning briefings, community updates, Todoist completions, vendor/research watches, CI/ops?
- Would anyone self-host the companion without already running Hermes?
