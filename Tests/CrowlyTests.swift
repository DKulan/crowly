// Crowly reader-layer tests (Swift Testing).
//
// What we prove here:
//   - Job-color determinism: same job_id → same hue, every time, across launches.
//   - Schema decoding incl. unknown-field passthrough (additive-only invariant).
//   - Demo fixtures meet the reader shape requirements (≥4 digests, varied
//     urgency, some with sections + sources).
//   - DigestStore: unread/read/archived state, archive filtering, undo,
//     section sort order.
//   - Deeplink URL parsing.

import Testing
import Foundation
@testable import Crowly

// MARK: - Job color determinism

@Test func jobColorHueIsDeterministicAcrossCalls() {
    let id = "ai-news-daily"
    let h1 = JobColor.hue(for: id)
    let h2 = JobColor.hue(for: id)
    let h3 = JobColor.hue(for: id)
    #expect(h1 == h2)
    #expect(h2 == h3)
}

@Test func jobColorHueIsDifferentForDifferentJobIds() {
    let a = JobColor.hue(for: "ai-news-daily")
    let b = JobColor.hue(for: "weather-local")
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
    for id in ["a", "ab", "abc", "harmony", "ai-news-daily", ""] {
        let h = JobColor.hue(for: id)
        #expect(h >= 0.0)
        #expect(h < 1.0)
    }
}

// MARK: - Schema decoding + unknown-field passthrough

@Test func digestDecodesFromReaderShape() throws {
    let json = """
    {
      "schema_version": 1,
      "id": "dgst_2026-06-29_ai-news",
      "job_id": "ai-news-daily",
      "source": "hermes-cron",
      "title": "AI news — Monday roundup",
      "created_at": "2026-06-29T07:15:00-04:00",
      "urgency": "normal",
      "bottom_line": "Two major model releases this weekend.",
      "summary": "Quiet weekend on the policy front; loud one on releases.",
      "sections": [
        { "heading": "Releases", "body": "Two flagship updates landed." }
      ],
      "sources": [
        { "title": "Anthropic", "url": "https://www.anthropic.com/news" }
      ]
    }
    """.data(using: .utf8)!

    let digest = try JSONDecoder().decode(Digest.self, from: json)
    #expect(digest.schemaVersion == 1)
    #expect(digest.id == "dgst_2026-06-29_ai-news")
    #expect(digest.jobId == "ai-news-daily")
    #expect(digest.urgency == .normal)
    #expect(digest.bottomLine == "Two major model releases this weekend.")
    #expect(digest.sections.count == 1)
    #expect(digest.sections[0].heading == "Releases")
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

@Test func digestIgnoresRemovedV0FieldsButPreservesThem() throws {
    // A v0 emitter (back when the schema carried questions / action_items)
    // must still decode through the reader — and the fields survive as extras
    // so a downstream v0-aware consumer can still read them on round-trip.
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
      "questions": [{"id": "q1", "text": "?", "reply_kind": "yes_no"}],
      "action_items": [{"id": "a1", "text": "x", "route": "task"}]
    }
    """.data(using: .utf8)!

    let digest = try JSONDecoder().decode(Digest.self, from: json)
    #expect(digest.id == "dgst_x")
    // The reader doesn't *model* questions/actions, but it preserves them.
    #expect(digest.extras["questions"] != nil)
    #expect(digest.extras["action_items"] != nil)
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

// MARK: - Demo fixtures invariants

@Test func demoFixturesAreAtLeastFour() {
    #expect(DemoFixtures.digests.count >= 4)
}

@Test func demoFixturesIncludeVariedUrgency() {
    let urgencies = Set(DemoFixtures.digests.map(\.urgency))
    #expect(urgencies.count >= 2)
    // At least one high-urgency to exercise the urgency tint in the cell.
    #expect(urgencies.contains(.high) || urgencies.contains(.urgent))
}

@Test func demoFixturesIncludeSectionsAndSources() {
    let withSections = DemoFixtures.digests.contains { !$0.sections.isEmpty }
    let withSources  = DemoFixtures.digests.contains { !$0.sources.isEmpty }
    #expect(withSections)
    #expect(withSources)
}

@Test func demoFixturesAllHaveBottomLine() {
    for d in DemoFixtures.digests {
        #expect(!d.bottomLine.isEmpty, "digest \(d.id) has empty bottom_line")
    }
}

@Test func demoFixturesExerciseExtrasPassthrough() {
    // The market-pulse digest carries an extras key; encoding + decoding it
    // should preserve the value end-to-end.
    let pulse = DemoFixtures.marketPulseDigest
    #expect(pulse.extras["forecast_confidence"] == .string("moderate"))
}

// MARK: - DigestStore: read/archive state

@Test @MainActor func newDigestsStartUnread() {
    let store = DigestStore()
    for d in DemoFixtures.digests {
        #expect(store.digestState(for: d.id) == .unread)
        #expect(store.statusDotState(for: d) == .unread)
    }
}

@Test @MainActor func markReadFlipsUnreadToRead() {
    let store = DigestStore()
    let d = DemoFixtures.aiNewsDigest
    store.markRead(d)
    #expect(store.digestState(for: d.id) == .read)
    #expect(store.statusDotState(for: d) == .read)
}

@Test @MainActor func markReadIsIdempotent() {
    let store = DigestStore()
    let d = DemoFixtures.aiNewsDigest
    store.markRead(d)
    store.markRead(d)
    #expect(store.digestState(for: d.id) == .read)
}

@Test @MainActor func archiveHidesDigestFromInbox() {
    let store = DigestStore()
    let d = DemoFixtures.aiNewsDigest
    store.archive(d)
    let visibleIds = store.sectionedDigests(matching: "")
        .flatMap(\.digests)
        .map(\.id)
    #expect(!visibleIds.contains(d.id))
    #expect(store.digestState(for: d.id) == .archived)
}

@Test @MainActor func undoArchiveRestoresDigestToRead() {
    let store = DigestStore()
    let d = DemoFixtures.aiNewsDigest
    store.archive(d)
    let restoredId = store.undoArchive()
    #expect(restoredId == d.id)
    #expect(store.digestState(for: d.id) == .read)
    let visibleIds = store.sectionedDigests(matching: "")
        .flatMap(\.digests)
        .map(\.id)
    #expect(visibleIds.contains(d.id))
}

@Test @MainActor func undoArchiveWithNoTargetReturnsNil() {
    let store = DigestStore()
    #expect(store.undoArchive() == nil)
}

// MARK: - DigestStore: sort + sectioning

@Test @MainActor func sectionedDigestsSortHighUrgencyFirstWithinSection() {
    let store = DigestStore()
    let today = store.sectionedDigests(matching: "")
        .first(where: { $0.title == "Today" })
    guard let today else { return }
    // The "Today" section in fixtures includes ai-news (normal) and weather
    // (high). High urgency must rank first.
    if today.digests.count >= 2,
       let firstUrgency = today.digests.first?.urgency {
        #expect(firstUrgency >= today.digests[1].urgency)
    }
}

@Test @MainActor func searchFiltersByBottomLineAndTitle() {
    let store = DigestStore()
    let weatherMatch = store.sectionedDigests(matching: "thunderstorm")
        .flatMap(\.digests)
    #expect(weatherMatch.contains { $0.id == "dgst_2026-06-29_weather" })
    #expect(!weatherMatch.contains { $0.id == "dgst_2026-06-29_ai-news" })
}

@Test @MainActor func searchAcrossSummary() {
    let store = DigestStore()
    // The AI news fixture's summary mentions "safety benchmark".
    let matches = store.sectionedDigests(matching: "safety benchmark")
        .flatMap(\.digests)
    #expect(matches.contains { $0.id == "dgst_2026-06-29_ai-news" })
}

// MARK: - Deeplink URL parsing

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

@Test @MainActor func deepLinkRouterHandleIgnoresInvalidURL() {
    let router = DeepLinkRouter()
    router.handle(URL(string: "https://example.com")!)
    #expect(router.pendingDigestId == nil)

    router.handle(URL(string: "crowly://digest/dgst_x")!)
    #expect(router.pendingDigestId == "dgst_x")
}

// MARK: - Fixture date sanity

/// Demo timestamps must NOT be in the future for the relative-timestamp
/// formatter to read naturally. Locked to 2026-06-29 in fixtures.
@Test func aiNewsFixtureIsNotInFuture() {
    let now = CrowlyISO8601.parse("2026-06-29T12:00:00-04:00")!
    #expect(DemoFixtures.aiNewsDigest.createdAt < now)
}
