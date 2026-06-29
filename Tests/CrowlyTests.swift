// Crowly Shared-layer tests (Swift Testing).
//
// What we prove here (per the team-lead brief):
//   - Job-color determinism: same job_id → same hue, every time, across launches.
//   - Schema decoding incl. unknown-field passthrough (additive-only invariant).
//   - Route resolution incl. the terminal "Log in inbox" fallback.
//   - parent_question_id round-trips.
//   - Demo fixtures meet the shape requirements (≥3, open loops, action items,
//     one pure-info, one with parent_question_id).

import Testing
import Foundation
@testable import Crowly

// MARK: - Job color determinism

@Test func jobColorHueIsDeterministicAcrossCalls() {
    let id = "harmony-weekly-public-digest"
    let h1 = JobColor.hue(for: id)
    let h2 = JobColor.hue(for: id)
    let h3 = JobColor.hue(for: id)
    #expect(h1 == h2)
    #expect(h2 == h3)
}

@Test func jobColorHueIsDifferentForDifferentJobIds() {
    let a = JobColor.hue(for: "harmony-weekly-public-digest")
    let b = JobColor.hue(for: "alberta-move-coordination")
    // Not strictly guaranteed by FNV-1a, but extremely likely for these two.
    #expect(a != b)
}

@Test func jobColorFnv1aMatchesKnownValue() {
    // Sanity-check the FNV-1a constants. "foobar" should hash to 0x85944171f73967e8
    // per the standard FNV-1a 64 reference vectors.
    let h = JobColor.fnv1a64("foobar")
    #expect(h == 0x85944171f73967e8)
}

@Test func jobColorHueInUnitRange() {
    for id in ["a", "ab", "abc", "harmony", "alberta-move-coordination", ""] {
        let h = JobColor.hue(for: id)
        #expect(h >= 0.0)
        #expect(h < 1.0)
    }
}

// MARK: - Schema decoding + unknown-field passthrough

@Test func digestDecodesFromSchemaMdExampleJson() throws {
    let json = """
    {
      "schema_version": 1,
      "id": "dgst_2026-06-29_harmony",
      "job_id": "harmony-weekly-public-digest",
      "source": "hermes-cron",
      "title": "Harmony Community Digest",
      "created_at": "2026-06-29T19:00:00-04:00",
      "urgency": "low",
      "bottom_line": "No urgent action items.",
      "summary": "Full prose summary",
      "sections": [
        { "heading": "Bylaw watch", "body": "Updates under review." }
      ],
      "action_items": [
        {
          "id": "a1",
          "text": "Confirm Interlane EV9 drop-off window",
          "route": "task",
          "hints": { "project": "Alberta Move", "labels": ["@hermes", "@vendor"] }
        }
      ],
      "questions": [
        {
          "id": "q1",
          "text": "Should I start tracking?",
          "reply_kind": "yes_no",
          "on_answer": {
            "yes": { "route": "task", "hints": { "text": "Set up watch" } },
            "no":  { "route": "none" }
          }
        }
      ],
      "sources": [
        { "title": "RVC Bylaws", "url": "https://www.rockyview.ca/bylaws" }
      ]
    }
    """.data(using: .utf8)!

    let digest = try JSONDecoder().decode(Digest.self, from: json)
    #expect(digest.schemaVersion == 1)
    #expect(digest.id == "dgst_2026-06-29_harmony")
    #expect(digest.jobId == "harmony-weekly-public-digest")
    #expect(digest.urgency == .low)
    #expect(digest.actionItems.count == 1)
    #expect(digest.actionItems[0].route.intent == .task)
    #expect(digest.questions.count == 1)
    #expect(digest.questions[0].replyKind == .yesNo)
    #expect(digest.questions[0].onAnswer?["yes"]?.route.intent == Intent.task)
    #expect(digest.questions[0].onAnswer?["no"]?.route.intent == Intent.none)
    #expect(digest.sources.count == 1)
}

@Test func digestPreservesUnknownTopLevelFields() throws {
    let json = """
    {
      "schema_version": 1,
      "id": "dgst_x",
      "job_id": "job-x",
      "source": "hermes-cron",
      "title": "T",
      "created_at": "2026-06-29T19:00:00Z",
      "urgency": "normal",
      "bottom_line": "x",
      "future_field_added_in_v2": "hello",
      "another_unknown": { "nested": 7 }
    }
    """.data(using: .utf8)!

    let digest = try JSONDecoder().decode(Digest.self, from: json)
    // Unknown fields preserved in `extras`.
    #expect(digest.extras["future_field_added_in_v2"] == .string("hello"))
    if case .object(let obj) = digest.extras["another_unknown"] {
        #expect(obj["nested"] == .int(7))
    } else {
        Issue.record("Expected nested object preserved in extras")
    }
}

@Test func actionItemPreservesUnknownFields() throws {
    let json = """
    {
      "id": "a1",
      "text": "X",
      "route": "task",
      "hints": {"project": "P"},
      "unknown_future_thing": true
    }
    """.data(using: .utf8)!

    let item = try JSONDecoder().decode(ActionItem.self, from: json)
    #expect(item.id == "a1")
    #expect(item.extras["unknown_future_thing"] == .bool(true))
}

@Test func questionPreservesUnknownFields() throws {
    let json = """
    {
      "id": "q1",
      "text": "Why?",
      "reply_kind": "yes_no",
      "on_answer": { "yes": {"route": "note"}, "no": {"route": "none"} },
      "v3_only_field": [1, 2, 3]
    }
    """.data(using: .utf8)!

    let q = try JSONDecoder().decode(Question.self, from: json)
    #expect(q.id == "q1")
    if case .array(let arr) = q.extras["v3_only_field"] {
        #expect(arr.count == 3)
    } else {
        Issue.record("Expected array preserved in question extras")
    }
}

@Test func digestRoundTripsExtras() throws {
    let json = """
    {
      "schema_version": 1,
      "id": "dgst_x",
      "job_id": "job-x",
      "source": "hermes-cron",
      "title": "T",
      "created_at": "2026-06-29T19:00:00Z",
      "urgency": "normal",
      "bottom_line": "x",
      "future_field": "v2-only"
    }
    """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(Digest.self, from: json)
    let reencoded = try JSONEncoder().encode(decoded)
    let redecoded = try JSONDecoder().decode(Digest.self, from: reencoded)
    #expect(redecoded.extras["future_field"] == .string("v2-only"))
}

@Test func unknownRouteIsTolerantAndDecodes() throws {
    let json = """
    {
      "id": "a1",
      "text": "X",
      "route": "create_watch"
    }
    """.data(using: .utf8)!

    let item = try JSONDecoder().decode(ActionItem.self, from: json)
    // Unknown route doesn't crash; intent is nil; raw is preserved.
    #expect(item.route.intent == nil)
    #expect(item.route.raw == "create_watch")
}

@Test func unknownUrgencyDegradesToNormal() throws {
    let json = """
    {
      "schema_version": 1,
      "id": "dgst_x",
      "job_id": "job-x",
      "source": "hermes-cron",
      "title": "T",
      "created_at": "2026-06-29T19:00:00Z",
      "urgency": "blue",
      "bottom_line": "x"
    }
    """.data(using: .utf8)!

    let digest = try JSONDecoder().decode(Digest.self, from: json)
    #expect(digest.urgency == .normal)
}

@Test func parentQuestionIdDecodesAndRoundTrips() throws {
    let json = """
    {
      "schema_version": 1,
      "id": "dgst_x",
      "job_id": "job-x",
      "source": "hermes-followup",
      "title": "Followup result",
      "created_at": "2026-06-29T19:00:00Z",
      "urgency": "normal",
      "bottom_line": "x",
      "parent_question_id": "q42"
    }
    """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(Digest.self, from: json)
    #expect(decoded.parentQuestionId == "q42")

    let reencoded = try JSONEncoder().encode(decoded)
    let redecoded = try JSONDecoder().decode(Digest.self, from: reencoded)
    #expect(redecoded.parentQuestionId == "q42")
}

// MARK: - Route resolution

@Test func routeResolverResolvesSupportedIntent() {
    let resolver = RouteResolver(capabilities: DemoCapabilities.standard)
    let resolution = resolver.resolve(rawIntent: .task)
    #expect(resolution.intent == .task)
    #expect(resolution.verb == "Add as task")
    #expect(resolution.enabled)
}

@Test func routeResolverFallsBackToTerminalForUnsupportedIntent() {
    // Capabilities with NO supported routes — every capability-aware intent
    // must degrade to .terminal ("Log in inbox") so nothing is dropped.
    let bareCaps = Capabilities(
        schemaVersion: 1,
        companionVersion: "0.0.1",
        supportedReplyKinds: [.yesNo],
        supportedRoutes: []
    )
    let resolver = RouteResolver(capabilities: bareCaps)
    let resolution = resolver.resolve(rawIntent: .task)
    #expect(resolution.intent == .terminal)
    #expect(resolution.verb == "Log in inbox")
    #expect(resolution.enabled)
    #expect(resolution.sublabel?.contains("task unavailable") == true)
}

@Test func routeResolverResolvesYesNoOnAnswer() {
    let resolver = RouteResolver(capabilities: DemoCapabilities.standard)
    let q = Question(
        id: "q1",
        text: "?",
        replyKind: .yesNo,
        onAnswer: [
            "yes": OnAnswerLeg(route: TolerantIntent(intent: Intent.task, raw: "task")),
            "no":  OnAnswerLeg(route: TolerantIntent(intent: Intent.none, raw: "none"))
        ]
    )
    let yes = resolver.resolve(forAnswer: "yes", of: q)
    let no  = resolver.resolve(forAnswer: "no", of: q)
    #expect(yes.intent == Intent.task)
    #expect(no.intent == Intent.none)
}

@Test func routeResolverActionItemTerminalFallback() {
    let bareCaps = Capabilities(
        schemaVersion: 1,
        companionVersion: "0.0.1",
        supportedReplyKinds: [.yesNo],
        supportedRoutes: []
    )
    let resolver = RouteResolver(capabilities: bareCaps)
    let action = ActionItem(
        id: "a1",
        text: "X",
        route: TolerantIntent(intent: .note, raw: "note")
    )
    let resolution = resolver.resolve(action)
    #expect(resolution.intent == .terminal)
    #expect(resolution.enabled)            // never silently dropped
}

@Test func routeResolverHasOverridesForTaskWithHints() {
    let resolver = RouteResolver(capabilities: DemoCapabilities.standard)
    let action = ActionItem(
        id: "a1",
        text: "X",
        route: TolerantIntent(intent: .task, raw: "task"),
        hints: [
            "project": .string("P"),
            "labels": .array([.string("L")])
        ]
    )
    let resolution = resolver.resolve(action)
    #expect(resolution.hasOverrides)
}

@Test func routeResolverNoOverridesForNoteIntent() {
    let resolver = RouteResolver(capabilities: DemoCapabilities.standard)
    let action = ActionItem(
        id: "a1",
        text: "X",
        route: TolerantIntent(intent: .note, raw: "note"),
        hints: ["project": .string("P")]
    )
    let resolution = resolver.resolve(action)
    // Per the resolver: overrides only meaningful for task-like intents.
    #expect(!resolution.hasOverrides)
}

// MARK: - Demo fixtures invariants

@Test func demoFixturesAreAtLeastThree() {
    #expect(DemoFixtures.digests.count >= 3)
}

@Test func demoFixturesIncludeYesNoOpenLoop() {
    let hasYesNo = DemoFixtures.digests.contains { digest in
        digest.questions.contains { $0.replyKind == .yesNo }
    }
    #expect(hasYesNo)
}

@Test func demoFixturesIncludeActionItems() {
    let hasActions = DemoFixtures.digests.contains { !$0.actionItems.isEmpty }
    #expect(hasActions)
}

@Test func demoFixturesIncludePureInfoDigest() {
    let pureInfo = DemoFixtures.digests.contains { digest in
        digest.questions.isEmpty && digest.actionItems.isEmpty
    }
    #expect(pureInfo)
}

@Test func demoFixturesIncludeParentQuestionId() {
    let hasParent = DemoFixtures.digests.contains { $0.parentQuestionId != nil }
    #expect(hasParent)
}

// MARK: - Intent lexicon sanity

@Test func intentLexiconHasSymbolAndVerbForEveryCase() {
    for intent in Intent.allCases {
        #expect(!intent.symbol.isEmpty)
        #expect(!intent.verb.isEmpty)
    }
}

// MARK: - Callback shape

@Test func questionAnswerCallbackEncodesCallbackIdAutomatically() throws {
    let cb = QuestionAnswer(
        jobId: "job-x",
        digestId: "dgst-y",
        questionId: "q1",
        answer: "yes"
    )
    // P0-3: callback_id is digest_id + question_id ONLY — never the answer
    // value, so the companion dedupes a stray flip from yes→no on the same
    // question.
    #expect(cb.callbackId == "dgst-y:q1")
    let data = try JSONEncoder().encode(cb)
    let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(dict["callback_id"] as? String == "dgst-y:q1")
    #expect(dict["kind"] as? String == "question_answer")
}

// MARK: - P0/P1 regression tests (review pass A)

/// P0-3: a different answer value for the same (digest, question) must
/// produce the same idempotency key.
@Test func callbackIdExcludesAnswerValue() {
    let yes = QuestionAnswer(jobId: "j", digestId: "d", questionId: "q", answer: "yes")
    let no  = QuestionAnswer(jobId: "j", digestId: "d", questionId: "q", answer: "no")
    #expect(yes.callbackId == no.callbackId)
    #expect(yes.callbackId == "d:q")
}

/// P0-3: a double-tap (or any later write) must be a no-op. First-write-wins.
@Test func demoAnswerLogIsFirstWriteWins() {
    // Use a unique key per test run so we don't collide with other tests'
    // writes to the shared `UserDefaults.standard`.
    let log = DemoAnswerLog.shared
    let digestId = "test-fww-\(UUID().uuidString)"
    let questionId = "q1"

    log.record(digestId: digestId, questionId: questionId, value: "yes")
    log.record(digestId: digestId, questionId: questionId, value: "no")    // ignored
    log.record(digestId: digestId, questionId: questionId, value: "yes")   // ignored

    #expect(log.answer(digestId: digestId, questionId: questionId) == "yes")
    #expect(log.isAnswered(digestId: digestId, questionId: questionId))
}

/// P1-2: Capabilities decode tolerantly. An unknown route name in
/// `supported_routes` is silently dropped, not fatal.
@Test func capabilitiesTolerantToUnknownRoute() throws {
    let json = """
    {
      "schema_version": 1,
      "companion_version": "0.2.0",
      "supported_reply_kinds": ["yes_no", "future_kind"],
      "supported_routes": ["task", "create_watch", "note", "future_route"]
    }
    """.data(using: .utf8)!

    let caps = try JSONDecoder().decode(Capabilities.self, from: json)
    #expect(caps.schemaVersion == 1)
    // Known reply_kinds pass through; unknowns dropped.
    #expect(caps.supportedReplyKinds.contains(.yesNo))
    #expect(caps.supportedReplyKinds.count == 1)
    // Known routes pass through; unknowns dropped.
    #expect(caps.supportedRoutes.contains(Intent.task))
    #expect(caps.supportedRoutes.contains(Intent.note))
    #expect(caps.supportedRoutes.count == 2)
}

/// P1: `choice` legs that aren't in `on_answer` get the terminal fallback —
/// nothing is silently dropped.
@Test func routeResolverChoiceLegTerminalFallback() {
    let resolver = RouteResolver(capabilities: DemoCapabilities.standard)
    let q = Question(
        id: "q1",
        text: "Pick one",
        replyKind: .choice,
        onAnswer: [
            "a": OnAnswerLeg(route: TolerantIntent(intent: Intent.task, raw: "task"))
            // "b" is intentionally absent
        ],
        options: ["a", "b"]
    )
    let a = resolver.resolve(forAnswer: "a", of: q)
    let b = resolver.resolve(forAnswer: "b", of: q)
    #expect(a.intent == Intent.task)
    #expect(b.intent == Intent.terminal)
    #expect(b.enabled)                              // terminal is always enabled
    #expect(b.verb == "Log in inbox")
}

/// P0-2: answer state is digest-scoped. Answering `q1` in one digest leaves
/// `q1` in another digest untouched. Demo fixtures reuse "q1" across three
/// different digests, which is exactly the bleed the old keying caused.
@Test @MainActor func answerStateIsDigestScoped() {
    let store = DigestStore()
    let harmony = DemoFixtures.harmonyDigest
    let alberta = DemoFixtures.albertaMoveDigest

    // Sanity: both have a "q1".
    #expect(harmony.questions.first?.id == "q1")
    #expect(alberta.questions.first?.id == "q1")

    // Answer harmony.q1 = yes
    store.answer(harmony.questions[0], in: harmony.id, value: "yes")

    let harmonyState = store.answerState(digestId: harmony.id, questionId: "q1")
    let albertaState = store.answerState(digestId: alberta.id, questionId: "q1")

    // Harmony's q1 is answered.
    if case .answered(let v, _) = harmonyState {
        #expect(v == "yes")
    } else {
        Issue.record("Expected harmony q1 to be answered")
    }
    // Alberta's q1 is NOT touched — the old bug bled state across digests.
    #expect(albertaState == .unanswered)
    #expect(store.openQuestionCount(for: alberta) == 1)
}

/// P0-4: `markHandled` decays chip counts via digest state, NOT by writing
/// fake answer values into `answerStates`. The user shouldn't see "Answered:
/// handled" on a question they never touched.
@Test @MainActor func markHandledDoesNotForgeAnswerState() {
    let store = DigestStore()
    let harmony = DemoFixtures.harmonyDigest
    store.markHandled(harmony)

    // Chips decay (the inbox cell shows no open chips).
    #expect(store.openQuestionCount(for: harmony) == 0)
    #expect(store.openLoopCounts(for: harmony).isEmpty)

    // But the per-question answer state is still `.unanswered` — no fake
    // "handled" answer was written.
    let qState = store.answerState(digestId: harmony.id, questionId: "q1")
    #expect(qState == .unanswered)
}

// MARK: - Pass B regression tests

/// P1-5: `.none` is not chip-renderable (no noun, no meaningful chip).
/// `.terminal`'s noun reads as "item(s) in inbox".
@Test func intentChipRenderableSkipsNone() {
    #expect(Intent.none.chipRenderable == false)
    #expect(Intent.task.chipRenderable)
    #expect(Intent.note.chipRenderable)
    #expect(Intent.followup.chipRenderable)
    #expect(Intent.terminal.chipRenderable)
}

@Test func terminalIntentNounReadsAsItemInInbox() {
    #expect(Intent.terminal.noun(pluralFor: 1) == "item in inbox")
    #expect(Intent.terminal.noun(pluralFor: 2) == "items in inbox")
}

/// Bug #2: deeplink URL parsing.
@Test func deepLinkRouterParsesCrowlyDigestURL() {
    #expect(DeepLinkRouter.digestId(from: URL(string: "crowly://digest/abc-123")!) == "abc-123")
    // Trailing slash tolerated.
    #expect(DeepLinkRouter.digestId(from: URL(string: "crowly://digest/abc-123/")!) == "abc-123")
    // Unknown host → nil.
    #expect(DeepLinkRouter.digestId(from: URL(string: "crowly://settings/x")!) == nil)
    // Wrong scheme → nil.
    #expect(DeepLinkRouter.digestId(from: URL(string: "https://digest/abc")!) == nil)
    // Empty id → nil.
    #expect(DeepLinkRouter.digestId(from: URL(string: "crowly://digest/")!) == nil)
}

/// Bug #2: `handle(_:)` only updates `pendingDigestId` on a valid URL.
@Test @MainActor func deepLinkRouterHandleIgnoresInvalidURL() {
    let router = DeepLinkRouter()
    router.handle(URL(string: "https://example.com")!)
    #expect(router.pendingDigestId == nil)

    router.handle(URL(string: "crowly://digest/dgst_x")!)
    #expect(router.pendingDigestId == "dgst_x")
}

/// Future-date fixture sanity: Harmony's createdAt must NOT be in the
/// future for the "today" timestamp to read naturally. (Locked to
/// 2026-06-29T09:00 EDT after the pass-B fix.)
@Test func harmonyFixtureIsNotInFuture() {
    let now = CrowlyISO8601.parse("2026-06-29T12:00:00-04:00")!
    #expect(DemoFixtures.harmonyDigest.createdAt < now)
}
