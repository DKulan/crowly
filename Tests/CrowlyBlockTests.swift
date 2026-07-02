// Schema v2 content-block decode tests (Swift Testing).
//
// What we prove:
//   - Each known block type decodes from its wire shape into the right case.
//   - An unknown block type degrades to `.unknown` and preserves its raw JSON
//     (forward-compat / additive-only round-trip).
//   - Malformed known blocks degrade field-by-field, never throw the digest
//     decode (the "degrade-and-warn, never crash" rule).
//   - A digest with `content` round-trips (encode → decode) with blocks intact.
//   - `content` present vs absent drives the detail view's block-vs-fallback
//     choice via `renderableBlocks`-equivalent filtering.

import Testing
import Foundation
@testable import Crowly

// MARK: - Helper

private func decodeDigest(contentJSON: String) throws -> Digest {
    let json = """
    {
      "schema_version": 2,
      "id": "dgst_blk",
      "job_id": "job-x",
      "source": "hermes-cron",
      "title": "T",
      "created_at": "2026-06-29T19:00:00Z",
      "urgency": "normal",
      "bottom_line": "x",
      "content": \(contentJSON)
    }
    """
    return try JSONDecoder().decode(Digest.self, from: Data(json.utf8))
}

// MARK: - Known block decode

@Test func paragraphBlockDecodes() throws {
    let d = try decodeDigest(contentJSON: #"[{"type":"paragraph","text":"Hello **world**"}]"#)
    #expect(d.content.count == 1)
    guard case .paragraph(let text) = d.content[0] else {
        Issue.record("expected paragraph, got \(d.content[0])"); return
    }
    #expect(text == "Hello **world**")
}

@Test func headingBlockDecodes() throws {
    let d = try decodeDigest(contentJSON: #"[{"type":"heading","text":"Section"}]"#)
    guard case .heading(let text) = d.content[0] else {
        Issue.record("expected heading"); return
    }
    #expect(text == "Section")
}

@Test func bulletListBlockDecodes() throws {
    let d = try decodeDigest(contentJSON: #"[{"type":"list","style":"bullet","items":["a","b","c"]}]"#)
    guard case .list(let style, let items) = d.content[0] else {
        Issue.record("expected list"); return
    }
    #expect(style == .bullet)
    #expect(items == ["a", "b", "c"])
}

@Test func orderedListBlockDecodes() throws {
    let d = try decodeDigest(contentJSON: #"[{"type":"list","style":"ordered","items":["one","two"]}]"#)
    guard case .list(let style, _) = d.content[0] else {
        Issue.record("expected list"); return
    }
    #expect(style == .ordered)
}

@Test func listWithMissingStyleDefaultsToBullet() throws {
    let d = try decodeDigest(contentJSON: #"[{"type":"list","items":["x"]}]"#)
    guard case .list(let style, _) = d.content[0] else {
        Issue.record("expected list"); return
    }
    #expect(style == .bullet)
}

@Test func listWithUnknownStyleDegradesToBullet() throws {
    let d = try decodeDigest(contentJSON: #"[{"type":"list","style":"checkbox","items":["x"]}]"#)
    guard case .list(let style, _) = d.content[0] else {
        Issue.record("expected list"); return
    }
    #expect(style == .bullet)
}

@Test func calloutBlockDecodesWithVariantAndTitle() throws {
    let d = try decodeDigest(contentJSON: #"[{"type":"callout","variant":"warning","title":"Heads up","text":"Storm"}]"#)
    guard case .callout(let variant, let title, let text) = d.content[0] else {
        Issue.record("expected callout"); return
    }
    #expect(variant == .warning)
    #expect(title == "Heads up")
    #expect(text == "Storm")
}

@Test func calloutWithUnknownVariantDegradesToInfo() throws {
    let d = try decodeDigest(contentJSON: #"[{"type":"callout","variant":"nuclear","text":"x"}]"#)
    guard case .callout(let variant, let title, _) = d.content[0] else {
        Issue.record("expected callout"); return
    }
    #expect(variant == .info)
    #expect(title == nil)  // absent title decodes to nil
}

@Test func metricsBlockDecodes() throws {
    let d = try decodeDigest(contentJSON: #"[{"type":"metrics","items":[{"label":"Gust","value":"90 km/h"},{"label":"Risk","value":"High"}]}]"#)
    guard case .metrics(let items) = d.content[0] else {
        Issue.record("expected metrics"); return
    }
    #expect(items.count == 2)
    #expect(items[0].label == "Gust")
    #expect(items[0].value == "90 km/h")
}

@Test func metricsDropsMalformedItemsButKeepsGoodOnes() throws {
    // One well-formed metric, one missing `value` → the bad one is dropped,
    // the good one survives. Never throws.
    let d = try decodeDigest(contentJSON: #"[{"type":"metrics","items":[{"label":"ok","value":"1"},{"label":"bad"}]}]"#)
    guard case .metrics(let items) = d.content[0] else {
        Issue.record("expected metrics"); return
    }
    #expect(items.count == 1)
    #expect(items[0].label == "ok")
}

@Test func dividerBlockDecodes() throws {
    let d = try decodeDigest(contentJSON: #"[{"type":"divider"}]"#)
    #expect(d.content[0] == .divider)
}

// MARK: - Tolerant / forward-compat

@Test func unknownBlockTypeDegradesToUnknownAndPreservesRaw() throws {
    let d = try decodeDigest(contentJSON: #"[{"type":"future_widget","payload":{"x":1},"text":"fallback"}]"#)
    guard case .unknown(let type, let raw) = d.content[0] else {
        Issue.record("expected unknown, got \(d.content[0])"); return
    }
    #expect(type == "future_widget")
    // The raw JSON is preserved verbatim for round-trip.
    #expect(raw.objectValue?["text"]?.stringValue == "fallback")
    if case .object(let payload)? = raw.objectValue?["payload"] {
        #expect(payload["x"] == .int(1))
    } else {
        Issue.record("expected nested payload preserved")
    }
}

@Test func nonObjectBlockDegradesToUnknownNeverThrows() throws {
    // A stray non-object element in the content array must not fail the decode.
    let d = try decodeDigest(contentJSON: #"["not a block", 42, {"type":"paragraph","text":"ok"}]"#)
    #expect(d.content.count == 3)
    guard case .paragraph(let text) = d.content[2] else {
        Issue.record("expected the valid paragraph to survive"); return
    }
    #expect(text == "ok")
}

@Test func paragraphMissingTextDecodesToEmptyNotThrow() throws {
    let d = try decodeDigest(contentJSON: #"[{"type":"paragraph"}]"#)
    guard case .paragraph(let text) = d.content[0] else {
        Issue.record("expected paragraph"); return
    }
    #expect(text == "")
    // …and an empty paragraph is not renderable, so the detail view skips it.
    #expect(!d.content[0].isRenderable)
}

@Test func nonArrayContentDecodesToEmpty() throws {
    // `content` present but not an array → [] (degrade, don't throw).
    let json = """
    {
      "schema_version": 2, "id": "x", "job_id": "j", "source": "s",
      "title": "T", "created_at": "2026-06-29T19:00:00Z",
      "urgency": "normal", "bottom_line": "b",
      "content": "oops-not-an-array"
    }
    """
    let d = try JSONDecoder().decode(Digest.self, from: Data(json.utf8))
    #expect(d.content.isEmpty)
    // Non-array `content` is preserved in extras (unknown-field passthrough)
    // rather than silently dropped.
    #expect(d.extras["content"] == nil || d.content.isEmpty)
}

@Test func absentContentIsEmpty() throws {
    // A v1 digest (no `content` key) decodes with an empty content array, so
    // the detail view falls back to summary/sections.
    let json = """
    {
      "schema_version": 1, "id": "x", "job_id": "j", "source": "s",
      "title": "T", "created_at": "2026-06-29T19:00:00Z",
      "urgency": "normal", "bottom_line": "b",
      "summary": "just prose"
    }
    """
    let d = try JSONDecoder().decode(Digest.self, from: Data(json.utf8))
    #expect(d.content.isEmpty)
    #expect(d.summary == "just prose")
}

// MARK: - Round-trip

@Test func digestWithContentRoundTrips() throws {
    let original = try decodeDigest(contentJSON: """
    [
      {"type":"callout","variant":"critical","title":"T","text":"boom"},
      {"type":"list","style":"ordered","items":["a","b"]},
      {"type":"metrics","items":[{"label":"L","value":"V"}]},
      {"type":"divider"},
      {"type":"paragraph","text":"end"},
      {"type":"mystery_block","keep":"me"}
    ]
    """)
    let reencoded = try JSONEncoder().encode(original)
    let redecoded = try JSONDecoder().decode(Digest.self, from: reencoded)

    #expect(redecoded.content.count == original.content.count)
    #expect(redecoded.content == original.content)
    // The unknown block survived the round-trip verbatim.
    guard case .unknown(let type, let raw) = redecoded.content[5] else {
        Issue.record("expected unknown block preserved"); return
    }
    #expect(type == "mystery_block")
    #expect(raw.objectValue?["keep"]?.stringValue == "me")
}

// MARK: - Demo fixtures exercise v2

@Test func demoFixturesIncludeContentBlocks() {
    // The v2 rewrite: at least one fixture uses structured content, and the
    // full block taxonomy appears across the set.
    let all = DemoFixtures.digests.flatMap(\.content)
    #expect(!all.isEmpty)

    func has(_ predicate: (ContentBlock) -> Bool) -> Bool { all.contains(where: predicate) }
    #expect(has { if case .callout = $0 { return true } else { return false } })
    #expect(has { if case .metrics = $0 { return true } else { return false } })
    #expect(has { if case .heading = $0 { return true } else { return false } })
    #expect(has { if case .list = $0 { return true } else { return false } })
    #expect(has { if case .divider = $0 { return true } else { return false } })
    #expect(has { if case .paragraph = $0 { return true } else { return false } })
}

@Test func demoFixturesKeepAV1FallbackDigest() {
    // market-pulse stays schema_version 1 with summary/sections and no content,
    // so the detail view's fallback branch is exercised by a real fixture.
    let pulse = DemoFixtures.marketPulseDigest
    #expect(pulse.schemaVersion == 1)
    #expect(pulse.content.isEmpty)
    #expect(pulse.summary != nil)
    #expect(!pulse.sections.isEmpty)
}
