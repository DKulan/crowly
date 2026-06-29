// Schema models — Codable types matching docs/schema.md v1 EXACTLY.
//
// Three contracts live here:
//   1. Digest (and its sub-shapes: Question, ActionItem, Source, Section)
//   2. Callback (the three `kind`s the app POSTs back to its companion)
//   3. Capabilities (the response from `GET /capabilities`)
//
// Hard invariants (docs/schema.md §3 + CLAUDE.md):
//   - The schema is **versioned and additive-only.** Never remove or repurpose
//     a field; unknown fields are *ignored, not fatal*, on decode.
//   - Decoders **preserve** unknown fields in an `extras` map so a round-trip
//     through an older app/companion doesn't strip them.
//   - parent_question_id is in schema v1 (optional) — modeled here.
//   - Routes are intents, never tool names — see Intent.swift.

import Foundation

// MARK: - Urgency

public enum Urgency: String, Codable, CaseIterable, Hashable, Comparable, Sendable {
    case low, normal, high, urgent

    private var order: Int {
        switch self { case .low: 0; case .normal: 1; case .high: 2; case .urgent: 3 }
    }

    public static func < (lhs: Urgency, rhs: Urgency) -> Bool {
        lhs.order < rhs.order
    }

    /// Tolerant decode: unknown urgency strings degrade to `.normal` rather
    /// than throw. The schema's "degrade-and-warn, never crash" rule.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Urgency(rawValue: raw) ?? .normal
    }
}

// MARK: - ReplyKind

/// Mirrors schema.md `reply_kind`. `choice` carries its options on the parent
/// Question (not on the case itself) because the schema stores `options` as a
/// peer field.
public enum ReplyKind: String, Codable, CaseIterable, Hashable, Sendable {
    case yesNo = "yes_no"
    case freeText = "free_text"
    case choice
}

// MARK: - OnAnswer (intent + hints map)

/// One leg of a Question's `on_answer` map: "when the user answered X, route
/// to this intent with these hints." Hints are free-form key/values the
/// companion's resolver may use (project, labels, due, etc.).
public struct OnAnswerLeg: Codable, Hashable, Sendable {
    public let route: TolerantIntent
    public let hints: [String: JSONValue]?

    public init(route: TolerantIntent, hints: [String: JSONValue]? = nil) {
        self.route = route
        self.hints = hints
    }

    private enum CodingKeys: String, CodingKey { case route, hints }
}

// MARK: - Source

public struct Source: Codable, Hashable, Identifiable, Sendable {
    public var id: String { url.absoluteString + ":" + title }
    public let title: String
    public let url: URL

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }
}

// MARK: - Section

public struct DigestSection: Codable, Hashable, Identifiable, Sendable {
    /// Synthetic — schema sections don't carry an id, but SwiftUI ForEach
    /// needs one. Derived from heading + a stable index supplied by the
    /// parent decoder via the array position.
    public var id: String { heading }
    public let heading: String
    public let body: String

    public init(heading: String, body: String) {
        self.heading = heading
        self.body = body
    }
}

// MARK: - ActionItem

public struct ActionItem: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public let route: TolerantIntent
    public let hints: [String: JSONValue]?

    /// Unknown future fields preserved verbatim per docs/schema.md §3.
    public var extras: [String: JSONValue]

    public init(
        id: String,
        text: String,
        route: TolerantIntent,
        hints: [String: JSONValue]? = nil,
        extras: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.text = text
        self.route = route
        self.hints = hints
        self.extras = extras
    }

    private static let knownKeys: Set<String> = ["id", "text", "route", "hints"]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        self.id = try container.decode(String.self, forKey: DynamicKey("id"))
        self.text = try container.decode(String.self, forKey: DynamicKey("text"))
        self.route = try container.decode(TolerantIntent.self, forKey: DynamicKey("route"))
        self.hints = try container.decodeIfPresent([String: JSONValue].self, forKey: DynamicKey("hints"))
        self.extras = try Self.decodeExtras(from: container, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        try container.encode(id, forKey: DynamicKey("id"))
        try container.encode(text, forKey: DynamicKey("text"))
        try container.encode(route, forKey: DynamicKey("route"))
        try container.encodeIfPresent(hints, forKey: DynamicKey("hints"))
        try Self.encodeExtras(extras, into: &container)
    }

    /// Human-readable hint chips for display (project, labels, due).
    /// Ordered: project, due, labels — matches the UX spec.
    public var hintsChips: [String] {
        guard let hints else { return [] }
        var chips: [String] = []
        if case .string(let s) = hints["project"] { chips.append("project: \(s)") }
        if case .string(let s) = hints["due"] { chips.append("due: \(s)") }
        if case .array(let labels) = hints["labels"] {
            for value in labels {
                if case .string(let s) = value { chips.append(s) }
            }
        }
        return chips
    }
}

// MARK: - Question

public struct Question: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public let replyKind: ReplyKind
    public let onAnswer: [String: OnAnswerLeg]?
    public let options: [String]?
    public let defaultRoute: TolerantIntent?

    /// Unknown future fields preserved verbatim per docs/schema.md §3.
    public var extras: [String: JSONValue]

    public init(
        id: String,
        text: String,
        replyKind: ReplyKind,
        onAnswer: [String: OnAnswerLeg]? = nil,
        options: [String]? = nil,
        defaultRoute: TolerantIntent? = nil,
        extras: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.text = text
        self.replyKind = replyKind
        self.onAnswer = onAnswer
        self.options = options
        self.defaultRoute = defaultRoute
        self.extras = extras
    }

    private static let knownKeys: Set<String> = [
        "id", "text", "reply_kind", "on_answer", "options", "default_route"
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        self.id = try container.decode(String.self, forKey: DynamicKey("id"))
        self.text = try container.decode(String.self, forKey: DynamicKey("text"))
        self.replyKind = try container.decode(ReplyKind.self, forKey: DynamicKey("reply_kind"))
        self.onAnswer = try container.decodeIfPresent([String: OnAnswerLeg].self, forKey: DynamicKey("on_answer"))
        self.options = try container.decodeIfPresent([String].self, forKey: DynamicKey("options"))
        self.defaultRoute = try container.decodeIfPresent(TolerantIntent.self, forKey: DynamicKey("default_route"))
        self.extras = try Self.decodeExtras(from: container, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        try container.encode(id, forKey: DynamicKey("id"))
        try container.encode(text, forKey: DynamicKey("text"))
        try container.encode(replyKind, forKey: DynamicKey("reply_kind"))
        try container.encodeIfPresent(onAnswer, forKey: DynamicKey("on_answer"))
        try container.encodeIfPresent(options, forKey: DynamicKey("options"))
        try container.encodeIfPresent(defaultRoute, forKey: DynamicKey("default_route"))
        try Self.encodeExtras(extras, into: &container)
    }
}

// MARK: - Digest

/// The top-level digest contract (docs/schema.md §1).
public struct Digest: Codable, Hashable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let jobId: String
    public let source: String
    public let title: String
    public let createdAt: Date
    public let urgency: Urgency
    public let bottomLine: String
    public let summary: String?
    public let sections: [DigestSection]
    public let actionItems: [ActionItem]
    public let questions: [Question]
    public let sources: [Source]

    /// Optional. Set when this digest was emitted *as the result of* a
    /// `followup` answer — carries the originating question_id so the app can
    /// render "in reply to your answer about X" instead of an unrelated
    /// arrival. Absent on all non-followup digests. (docs/schema.md §1.)
    public let parentQuestionId: String?

    /// Unknown future fields preserved verbatim per docs/schema.md §3.
    /// The companion stores the digest blob whole and the app round-trips
    /// unknown fields so newer-app data survives an older-app pass-through.
    public var extras: [String: JSONValue]

    public init(
        schemaVersion: Int,
        id: String,
        jobId: String,
        source: String,
        title: String,
        createdAt: Date,
        urgency: Urgency,
        bottomLine: String,
        summary: String? = nil,
        sections: [DigestSection] = [],
        actionItems: [ActionItem] = [],
        questions: [Question] = [],
        sources: [Source] = [],
        parentQuestionId: String? = nil,
        extras: [String: JSONValue] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.jobId = jobId
        self.source = source
        self.title = title
        self.createdAt = createdAt
        self.urgency = urgency
        self.bottomLine = bottomLine
        self.summary = summary
        self.sections = sections
        self.actionItems = actionItems
        self.questions = questions
        self.sources = sources
        self.parentQuestionId = parentQuestionId
        self.extras = extras
    }

    private static let knownKeys: Set<String> = [
        "schema_version", "id", "job_id", "source", "title", "created_at",
        "urgency", "bottom_line", "summary", "sections", "action_items",
        "questions", "sources", "parent_question_id"
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        self.schemaVersion = try container.decode(Int.self, forKey: DynamicKey("schema_version"))
        self.id = try container.decode(String.self, forKey: DynamicKey("id"))
        self.jobId = try container.decode(String.self, forKey: DynamicKey("job_id"))
        self.source = try container.decode(String.self, forKey: DynamicKey("source"))
        self.title = try container.decode(String.self, forKey: DynamicKey("title"))

        let createdAtRaw = try container.decode(String.self, forKey: DynamicKey("created_at"))
        guard let date = CrowlyISO8601.parse(createdAtRaw) else {
            throw DecodingError.dataCorruptedError(
                forKey: DynamicKey("created_at"),
                in: container,
                debugDescription: "Invalid ISO8601 timestamp: \(createdAtRaw)"
            )
        }
        self.createdAt = date

        self.urgency = try container.decode(Urgency.self, forKey: DynamicKey("urgency"))
        self.bottomLine = try container.decode(String.self, forKey: DynamicKey("bottom_line"))
        self.summary = try container.decodeIfPresent(String.self, forKey: DynamicKey("summary"))
        self.sections = try container.decodeIfPresent([DigestSection].self, forKey: DynamicKey("sections")) ?? []
        self.actionItems = try container.decodeIfPresent([ActionItem].self, forKey: DynamicKey("action_items")) ?? []
        self.questions = try container.decodeIfPresent([Question].self, forKey: DynamicKey("questions")) ?? []
        self.sources = try container.decodeIfPresent([Source].self, forKey: DynamicKey("sources")) ?? []
        self.parentQuestionId = try container.decodeIfPresent(String.self, forKey: DynamicKey("parent_question_id"))
        self.extras = try Self.decodeExtras(from: container, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        try container.encode(schemaVersion, forKey: DynamicKey("schema_version"))
        try container.encode(id, forKey: DynamicKey("id"))
        try container.encode(jobId, forKey: DynamicKey("job_id"))
        try container.encode(source, forKey: DynamicKey("source"))
        try container.encode(title, forKey: DynamicKey("title"))
        try container.encode(
            CrowlyISO8601.format(createdAt),
            forKey: DynamicKey("created_at")
        )
        try container.encode(urgency, forKey: DynamicKey("urgency"))
        try container.encode(bottomLine, forKey: DynamicKey("bottom_line"))
        try container.encodeIfPresent(summary, forKey: DynamicKey("summary"))
        if !sections.isEmpty { try container.encode(sections, forKey: DynamicKey("sections")) }
        if !actionItems.isEmpty { try container.encode(actionItems, forKey: DynamicKey("action_items")) }
        if !questions.isEmpty { try container.encode(questions, forKey: DynamicKey("questions")) }
        if !sources.isEmpty { try container.encode(sources, forKey: DynamicKey("sources")) }
        try container.encodeIfPresent(parentQuestionId, forKey: DynamicKey("parent_question_id"))
        try Self.encodeExtras(extras, into: &container)
    }

    // Computed conveniences used by the inbox + detail views.

    /// Open questions = those without a recorded answer locally. For the
    /// model layer they're "all questions"; the view-model overlays answer
    /// state on top.
    public var openQuestions: [Question] { questions }

    public var openActions: [ActionItem] { actionItems }

    /// Subtitle for `DigestDetailView` per docs/design-system.md §3.2.
    /// Formats as "Sun, Jun 29 at 7:00 PM · low urgency".
    public var subtitle: String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d 'at' h:mm a"
        return "\(f.string(from: createdAt)) · \(urgency.rawValue) urgency"
    }
}

// MARK: - Capabilities (GET /capabilities)

/// Response from `GET /capabilities` (docs/schema.md §3). M1 demo mode
/// hard-codes a canned `Capabilities` value; real pairing replaces it.
///
/// Decoding is **additive-only tolerant** (P1-2 fix from review pass A):
/// `supported_routes` and `supported_reply_kinds` decode through string
/// arrays and silently drop values the app doesn't recognize. A newer
/// companion advertising `create_watch` will not crash an older app's
/// `/capabilities` parse — it just won't surface the unknown route.
public struct Capabilities: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let companionVersion: String
    public let supportedReplyKinds: [ReplyKind]
    public let supportedRoutes: [Intent]

    public init(
        schemaVersion: Int,
        companionVersion: String,
        supportedReplyKinds: [ReplyKind],
        supportedRoutes: [Intent]
    ) {
        self.schemaVersion = schemaVersion
        self.companionVersion = companionVersion
        self.supportedReplyKinds = supportedReplyKinds
        self.supportedRoutes = supportedRoutes
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case companionVersion = "companion_version"
        case supportedReplyKinds = "supported_reply_kinds"
        case supportedRoutes = "supported_routes"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.companionVersion = try container.decode(String.self, forKey: .companionVersion)

        // Decode as strings, then filter to known values. Unknown route
        // names (e.g. "create_watch" added by a newer companion) are
        // dropped silently — additive-only invariant.
        let rawReplyKinds = try container.decode([String].self, forKey: .supportedReplyKinds)
        self.supportedReplyKinds = rawReplyKinds.compactMap(ReplyKind.init(rawValue:))

        let rawRoutes = try container.decode([String].self, forKey: .supportedRoutes)
        self.supportedRoutes = rawRoutes.compactMap(Intent.init(rawValue:))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(companionVersion, forKey: .companionVersion)
        try container.encode(supportedReplyKinds.map(\.rawValue), forKey: .supportedReplyKinds)
        try container.encode(supportedRoutes.map(\.rawValue), forKey: .supportedRoutes)
    }
}

// MARK: - Callback (the three `kind`s the app POSTs back)

public enum Callback: Codable, Hashable, Sendable {
    case questionAnswer(QuestionAnswer)
    case actionTaken(ActionTaken)
    case stateChange(StateChange)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .questionAnswer(let v): try container.encode(v)
        case .actionTaken(let v):    try container.encode(v)
        case .stateChange(let v):    try container.encode(v)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Discriminator-based: peek at `kind`.
        let probe = try container.decode(KindProbe.self)
        switch probe.kind {
        case "question_answer": self = .questionAnswer(try container.decode(QuestionAnswer.self))
        case "action_taken":    self = .actionTaken(try container.decode(ActionTaken.self))
        case "state_change":    self = .stateChange(try container.decode(StateChange.self))
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown callback kind: \(probe.kind)"
            )
        }
    }

    private struct KindProbe: Decodable {
        let kind: String
    }
}

public struct QuestionAnswer: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let kind: String                  // "question_answer"
    public let jobId: String
    public let digestId: String
    public let questionId: String
    public let answer: String                // "yes" / "no" / choice value / free-text body
    public let note: String?
    /// Client-minted idempotency key so the companion dedupes a double-tap.
    /// docs/ux.md → "The companion dedupes on a client-minted `callback_id`".
    public let callbackId: String

    public init(
        jobId: String,
        digestId: String,
        questionId: String,
        answer: String,
        note: String? = nil,
        callbackId: String? = nil
    ) {
        self.schemaVersion = 1
        self.kind = "question_answer"
        self.jobId = jobId
        self.digestId = digestId
        self.questionId = questionId
        self.answer = answer
        self.note = note
        // Per docs/ux.md: "The companion dedupes on a client-minted
        // callback_id (e.g. digest_id + question_id), so a double-tap is a
        // no-op, not a duplicate." The answer value is intentionally NOT
        // part of the key — a stray flip from yes→no on the same question
        // must also dedupe.  (P0-3 fix from review pass A.)
        self.callbackId = callbackId ?? "\(digestId):\(questionId)"
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case kind
        case jobId = "job_id"
        case digestId = "digest_id"
        case questionId = "question_id"
        case answer
        case note
        case callbackId = "callback_id"
    }
}

public struct ActionTaken: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let kind: String                  // "action_taken"
    public let jobId: String
    public let digestId: String
    public let actionId: String
    public let overrides: [String: JSONValue]?
    public let callbackId: String

    public init(
        jobId: String,
        digestId: String,
        actionId: String,
        overrides: [String: JSONValue]? = nil,
        callbackId: String? = nil
    ) {
        self.schemaVersion = 1
        self.kind = "action_taken"
        self.jobId = jobId
        self.digestId = digestId
        self.actionId = actionId
        self.overrides = overrides
        self.callbackId = callbackId ?? "\(digestId):\(actionId)"
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case kind
        case jobId = "job_id"
        case digestId = "digest_id"
        case actionId = "action_id"
        case overrides
        case callbackId = "callback_id"
    }
}

public struct StateChange: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let kind: String                  // "state_change"
    public let digestId: String
    public let state: DigestState
    public let callbackId: String

    public init(digestId: String, state: DigestState, callbackId: String? = nil) {
        self.schemaVersion = 1
        self.kind = "state_change"
        self.digestId = digestId
        self.state = state
        self.callbackId = callbackId ?? "\(digestId):state:\(state.rawValue)"
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case kind
        case digestId = "digest_id"
        case state
        case callbackId = "callback_id"
    }
}

public enum DigestState: String, Codable, CaseIterable, Hashable, Sendable {
    case unread, read, handled, archived
}

// MARK: - DynamicKey + extras helpers

/// A coding key derived at runtime, used by decoders that want to read every
/// key in the JSON object (for extras passthrough).
struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { self.stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension Decodable {
    /// Collect any JSON keys NOT in `known` into a JSONValue extras map.
    fileprivate static func decodeExtras(
        from container: KeyedDecodingContainer<DynamicKey>,
        known: Set<String>
    ) throws -> [String: JSONValue] {
        var extras: [String: JSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            extras[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        return extras
    }

    fileprivate static func encodeExtras(
        _ extras: [String: JSONValue],
        into container: inout KeyedEncodingContainer<DynamicKey>
    ) throws {
        for (key, value) in extras {
            try container.encode(value, forKey: DynamicKey(key))
        }
    }
}

// MARK: - ISO8601 parsing
//
// We use `Date.ISO8601FormatStyle` (Foundation's modern, Sendable parser)
// instead of `ISO8601DateFormatter` because the latter is not Sendable and
// trips Swift 6 strict-concurrency checks when stored as `static let`.
// Each call constructs a value-type FormatStyle on the fly — cheap, safe.

public enum CrowlyISO8601 {
    /// Parse an ISO 8601 timestamp tolerantly: with or without fractional
    /// seconds, and with either `Z` or numeric (`-04:00`) offsets.
    public static func parse(_ string: String) -> Date? {
        // Try the format that matches the schema example
        // (`2026-06-29T19:00:00-04:00`) — fractional optional, offset
        // explicit. `ISO8601FormatStyle` parses both Z and ±HH:MM.
        if let d = try? Date(string, strategy: .iso8601) {
            return d
        }
        if let d = try? Date(
            string,
            strategy: .iso8601
                .year().month().day()
                .dateTimeSeparator(.standard)
                .time(includingFractionalSeconds: true)
                .timeZone(separator: .colon)
        ) {
            return d
        }
        if let d = try? Date(
            string,
            strategy: .iso8601
                .year().month().day()
                .dateTimeSeparator(.standard)
                .time(includingFractionalSeconds: false)
                .timeZone(separator: .colon)
        ) {
            return d
        }
        return nil
    }

    /// Format a `Date` as ISO 8601 with fractional seconds and UTC offset.
    public static func format(_ date: Date) -> String {
        date.formatted(
            .iso8601
                .year().month().day()
                .dateTimeSeparator(.standard)
                .time(includingFractionalSeconds: true)
                .timeZone(separator: .colon)
        )
    }
}
