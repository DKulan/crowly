// Intent — the five intents the app can render. Single source of truth.
//
// Mirrors the schema-level `route` values (`task | note | followup | none`)
// PLUS the resolver-level `terminal` "stays in the inbox, logged" fallback that
// the RouteResolver may produce when no companion capability matches.
//
// Per the invariant in CLAUDE.md: **schema routes are intents, never tool
// names.** The button text reads "Add as task," never "Add to Todoist." The
// resolver decides which concrete tool fulfills the intent.
//
// This file is the *only* place to add a new intent. Components read symbol /
// verb / noun from here — adding a route adds a case here and only here.

import Foundation

/// The five intents the app can render. Schema-level routes (`task | note |
/// followup | none`) plus the resolver-level `terminal` fallback that means
/// "stays in the inbox, logged" — never silently dropped.
public enum Intent: String, Codable, CaseIterable, Hashable, Sendable {
    case task
    case note
    case followup
    case none           // schema-level: no side effect
    case terminal       // resolver-level: "stays in the inbox, logged" fallback

    /// SF Symbol used in the chip and as the route-button leading icon.
    /// Matches the visual lexicon table in docs/ux.md.
    public var symbol: String {
        switch self {
        case .task:     "checklist"
        case .note:     "note.text"
        case .followup: "arrow.uturn.forward"
        case .none:     "circle.dotted"
        case .terminal: "tray.fill"
        }
    }

    /// Verb shown on a route button. Matches docs/ux.md.
    public var verb: String {
        switch self {
        case .task:     "Add as task"
        case .note:     "Save as note"
        case .followup: "Send to Hermes"
        case .none:     "Dismiss"
        case .terminal: "Log in inbox"
        }
    }

    /// Noun used in intent chips ("1 task", "2 notes"). Questions aren't an
    /// Intent — that count is inserted separately by the cell renderer.
    ///
    /// `.none` returns "" — callers must skip it (Intent.chipRenderable
    /// is the canonical predicate). Per P1-5 from review pass B.
    public func noun(pluralFor count: Int) -> String {
        switch self {
        case .task:     count == 1 ? "task" : "tasks"
        case .note:     count == 1 ? "note" : "notes"
        case .followup: count == 1 ? "followup" : "followups"
        case .none:     ""
        case .terminal: count == 1 ? "item in inbox" : "items in inbox"
        }
    }

    /// Whether a chip for this intent should render at all. `.none` is
    /// "no side effect" — there's no meaningful chip to show; the user
    /// already sees the dismissed state via the row's resolved glyph.
    /// Used by `DigestCell` and `IntentChip` (P1-5).
    public var chipRenderable: Bool {
        self != .none
    }

    /// Whether the companion's `GET /capabilities` can make this intent
    /// unavailable. `none` and `terminal` are always available — `terminal` IS
    /// the fallback when nothing else resolves.
    public var isCapabilityAware: Bool {
        switch self {
        case .task, .note, .followup: true
        case .none, .terminal:        false
        }
    }

    /// Display order used by `DigestCell` for the chip row. Question-count
    /// chips (not an Intent) are inserted by the cell first.
    public static let cellOrdering: [Intent] = [.task, .followup, .note]
}

/// Decodes an `Intent` from JSON tolerant of unknown future values. Unknown
/// route names decode to `nil` instead of throwing — the schema is
/// additive-only and unknown values are ignored, not fatal. Per docs/schema.md
/// §3 and the "degrade-and-warn, never crash" rule in docs/ux.md.
public struct TolerantIntent: Codable, Hashable, Sendable {
    public let intent: Intent?
    public let raw: String

    public init(intent: Intent?, raw: String) {
        self.intent = intent
        self.raw = raw
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self.raw = raw
        self.intent = Intent(rawValue: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}
