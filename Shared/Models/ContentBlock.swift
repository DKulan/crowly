// ContentBlock — schema v2's structured content model.
//
// v2 adds one optional top-level field to a digest: `content`, an ordered
// array of typed blocks the detail view renders with bespoke SwiftUI. It's
// additive-only over v1 — `summary`/`sections` remain valid and are the
// fallback for simple digests (the detail view prefers `content` when present).
//
// Hard invariant (CLAUDE.md / docs/schema.md): **degrade-and-warn, never
// crash.** Every parse here is tolerant — a block with an unknown `type`, a
// missing field, or a wrong-typed field degrades to a sensible default (or the
// `.unknown` case) rather than throwing. This mirrors `Urgency`'s tolerant
// decode: a future v3 block type must survive a round-trip through this v2
// reader, and a malformed block must never take down the whole digest decode.
//
// Blocks are decoded from `JSONValue` (not straight `Decoder`) precisely so a
// bad element can't throw out of the array decode — the array is read as
// `[JSONValue]` in `Digest`, then each element is mapped through
// `ContentBlock.parse`, which cannot fail.

import Foundation

// MARK: - Sub-enums

/// List rendering style. Tolerant: unknown/missing → `.bullet`. Named
/// `BlockListStyle` (not `ListStyle`) to avoid colliding with SwiftUI's
/// `ListStyle` protocol, which is in scope wherever a view imports SwiftUI.
public enum BlockListStyle: String, Hashable, Sendable {
    case bullet, ordered
}

/// Callout emphasis. Tolerant: unknown/missing → `.info`. Each variant maps to
/// a tint + SF Symbol at the render site (see `ContentBlockView`).
public enum CalloutVariant: String, Hashable, Sendable, CaseIterable {
    case info, warning, success, critical
}

/// A single `{label, value}` pair in a `metrics` block (e.g. "High" / "24°C").
public struct Metric: Hashable, Sendable {
    public let label: String
    public let value: String
    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

// MARK: - ContentBlock

/// One ordered block of digest content. The six known types plus a tolerant
/// `.unknown` bucket for forward-compatibility.
public enum ContentBlock: Hashable, Sendable {
    case paragraph(text: String)
    case heading(text: String)
    case list(style: BlockListStyle, items: [String])
    case callout(variant: CalloutVariant, title: String?, text: String)
    case metrics(items: [Metric])
    case divider
    /// A block whose `type` isn't one of the known six. The raw JSON is kept
    /// verbatim so it round-trips unchanged (a v3 block survives a v2 reader);
    /// the renderer surfaces its `text` if it has one, else skips it.
    case unknown(type: String, raw: JSONValue)

    // MARK: Decode (tolerant — never throws)

    /// Map a single JSON value to a block. Any shape problem degrades rather
    /// than throwing: a non-object → `.unknown`; a known type with a missing
    /// field → that field's empty/default; an unknown type → `.unknown` with
    /// the raw value preserved.
    public static func parse(_ value: JSONValue) -> ContentBlock {
        guard let obj = value.objectValue else {
            return .unknown(type: "", raw: value)
        }
        let type = obj["type"]?.stringValue ?? ""
        switch type {
        case "paragraph":
            return .paragraph(text: obj["text"]?.stringValue ?? "")
        case "heading":
            return .heading(text: obj["text"]?.stringValue ?? "")
        case "list":
            let style = BlockListStyle(rawValue: obj["style"]?.stringValue ?? "") ?? .bullet
            let items = (obj["items"]?.arrayValue ?? []).compactMap(\.stringValue)
            return .list(style: style, items: items)
        case "callout":
            let variant = CalloutVariant(rawValue: obj["variant"]?.stringValue ?? "") ?? .info
            return .callout(
                variant: variant,
                title: obj["title"]?.stringValue,
                text: obj["text"]?.stringValue ?? ""
            )
        case "metrics":
            let items = (obj["items"]?.arrayValue ?? []).compactMap { m -> Metric? in
                guard let mo = m.objectValue,
                      let label = mo["label"]?.stringValue,
                      let val = mo["value"]?.stringValue else { return nil }
                return Metric(label: label, value: val)
            }
            return .metrics(items: items)
        case "divider":
            return .divider
        default:
            return .unknown(type: type, raw: value)
        }
    }

    // MARK: Encode

    /// Re-serialize to JSON. Known blocks re-emit from their parsed fields;
    /// `.unknown` re-emits its preserved raw value verbatim. Used by `Digest`'s
    /// encoder so a decoded digest round-trips (the companion is the ultimate
    /// verbatim store, but the app's own round-trip stays faithful too).
    public var jsonValue: JSONValue {
        switch self {
        case .paragraph(let text):
            return .object(["type": .string("paragraph"), "text": .string(text)])
        case .heading(let text):
            return .object(["type": .string("heading"), "text": .string(text)])
        case .list(let style, let items):
            return .object([
                "type": .string("list"),
                "style": .string(style.rawValue),
                "items": .array(items.map(JSONValue.string)),
            ])
        case .callout(let variant, let title, let text):
            var o: [String: JSONValue] = [
                "type": .string("callout"),
                "variant": .string(variant.rawValue),
                "text": .string(text),
            ]
            if let title { o["title"] = .string(title) }
            return .object(o)
        case .metrics(let items):
            return .object([
                "type": .string("metrics"),
                "items": .array(items.map {
                    .object(["label": .string($0.label), "value": .string($0.value)])
                }),
            ])
        case .divider:
            return .object(["type": .string("divider")])
        case .unknown(_, let raw):
            return raw
        }
    }

    /// True if this block has nothing worth rendering (empty text/items, or an
    /// unknown block with no surfaceable text). The renderer skips these so a
    /// stray empty paragraph doesn't punch a hole in the layout.
    public var isRenderable: Bool {
        switch self {
        case .paragraph(let text), .heading(let text):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .list(_, let items):
            return !items.isEmpty
        case .callout(_, _, let text):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .metrics(let items):
            return !items.isEmpty
        case .divider:
            return true
        case .unknown(_, let raw):
            return raw.objectValue?["text"]?.stringValue?.isEmpty == false
        }
    }
}
