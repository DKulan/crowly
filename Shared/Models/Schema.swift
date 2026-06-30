// Schema models — Codable types for Crowly's reader-v1 digest contract.
//
// Crowly is a reader: agents emit digests, the user reads them. There are no
// callbacks, no answers, no actions. The single contract that lives here is
// the `Digest` (and its sub-shapes: `DigestSection`, `Source`, `Urgency`).
//
// Hard invariants (CLAUDE.md):
//   - The schema is **versioned and additive-only.** Never remove or repurpose
//     a field; unknown fields are *ignored, not fatal*, on decode.
//   - Decoders **preserve** unknown fields in an `extras` map so a round-trip
//     through an older app/companion doesn't strip them.

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
    /// needs one. Derived from heading (callers should keep headings unique
    /// within a digest).
    public var id: String { heading }
    public let heading: String
    public let body: String

    public init(heading: String, body: String) {
        self.heading = heading
        self.body = body
    }
}

// MARK: - Digest

/// The top-level reader digest. Cron-job output the user reads.
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
    public let sources: [Source]

    /// Unknown future fields preserved verbatim per the additive-only rule.
    /// Cheap insurance: a newer field a v2 emitter adds survives a round-trip
    /// through this v1 reader.
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
        sources: [Source] = [],
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
        self.sources = sources
        self.extras = extras
    }

    private static let knownKeys: Set<String> = [
        "schema_version", "id", "job_id", "source", "title", "created_at",
        "urgency", "bottom_line", "summary", "sections", "sources"
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
        self.sources = try container.decodeIfPresent([Source].self, forKey: DynamicKey("sources")) ?? []
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
        if !sources.isEmpty { try container.encode(sources, forKey: DynamicKey("sources")) }
        try Self.encodeExtras(extras, into: &container)
    }

    /// Subtitle for `DigestDetailView`. Formats as
    /// "Sun, Jun 29 at 7:00 PM · low urgency".
    public var subtitle: String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d 'at' h:mm a"
        return "\(f.string(from: createdAt)) · \(urgency.rawValue) urgency"
    }
}

// MARK: - DigestState

/// Per-digest UI state. `unread` on arrival, flips to `read` when the user
/// opens the detail view, `archived` when the user archives it.
public enum DigestState: String, Codable, CaseIterable, Hashable, Sendable {
    case unread, read, archived
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
