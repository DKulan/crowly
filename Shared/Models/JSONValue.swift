// JSONValue — a Codable, value-preserving box for arbitrary JSON.
//
// Why this exists: the schema is **additive-only** (docs/schema.md §3). The
// companion and app may be on different versions — so when we decode a digest
// or callback, we must *preserve* unknown fields verbatim instead of silently
// dropping them. This lets a field a newer app understands survive a round-trip
// through an older one.
//
// Used by `Digest.extras` — anywhere the schema says "additive-only,
// unknown fields ignored, not fatal." Decoding never throws on unknown keys.

import Foundation

/// Value-preserving JSON box. Round-trips any JSON value through Codable.
@frozen
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:           try container.encodeNil()
        case .bool(let b):    try container.encode(b)
        case .int(let i):     try container.encode(i)
        case .double(let d):  try container.encode(d)
        case .string(let s):  try container.encode(s)
        case .array(let a):   try container.encode(a)
        case .object(let o):  try container.encode(o)
        }
    }
}

// MARK: - Tolerant accessors
//
// Used by `ContentBlock`'s decode path (Schema.swift), which decodes each
// block as a whole JSONValue first and then reads typed fields off it — so a
// malformed block degrades to `.unknown` instead of throwing. These return
// nil on a type mismatch rather than trapping.
public extension JSONValue {
    var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
}
