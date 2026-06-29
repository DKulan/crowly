// RouteResolver — maps a schema-level `Intent` (route) onto a concrete
// `RouteResolution` (verb, sublabel, sfSymbol, enabled, confirmation),
// gated by the companion's declared capabilities.
//
// This is the single binding point the UI uses — **no button anywhere in
// the app renders without a RouteResolution.** That is what guarantees the
// "no dead buttons, ever" invariant from CLAUDE.md and docs/ux.md.
//
// In demo mode the capabilities are a canned set (simulating Daniel's box).
// When real pairing arrives in M2, the capabilities come from
// `GET /capabilities` — the resolver indirection stays exactly the same.
//
// The resolver also implements the **terminal fallback**: when no companion
// capability matches an intent, the resolver returns a `.terminal`
// resolution ("Log in inbox") so nothing is ever silently dropped.

import Foundation

/// A resolved route: what to show on a button, what will happen on tap,
/// and whether to render the button at all (per docs/design-system.md §5).
public struct RouteResolution: Hashable, Sendable {
    public let intent: Intent           // resolver-level (may be .terminal even if raw was .task)
    public let verb: String             // e.g., "Add as task"
    public let sublabel: String?        // e.g., "Will create a Todoist task"
    public let symbol: String           // SF Symbol
    public let confirmation: String     // post-tap: "task created"
    public let enabled: Bool            // false → caller drops the button
    public let hasOverrides: Bool       // action items only: ⋯ menu

    public init(
        intent: Intent,
        verb: String,
        sublabel: String?,
        symbol: String,
        confirmation: String,
        enabled: Bool,
        hasOverrides: Bool = false
    ) {
        self.intent = intent
        self.verb = verb
        self.sublabel = sublabel
        self.symbol = symbol
        self.confirmation = confirmation
        self.enabled = enabled
        self.hasOverrides = hasOverrides
    }
}

/// Capability-aware resolver. Built from a `Capabilities` value (either the
/// real `GET /capabilities` response or the canned demo set).
public struct RouteResolver: Sendable {
    public let capabilities: Capabilities

    public init(capabilities: Capabilities) {
        self.capabilities = capabilities
    }

    /// Resolve an `ActionItem`'s `route` to a button-renderable resolution.
    /// Always returns *something* — the terminal fallback ("Log in inbox")
    /// is the safety net so an action is never silently dropped.
    public func resolve(_ action: ActionItem) -> RouteResolution {
        let raw = action.route.intent ?? .terminal
        return resolve(rawIntent: raw, hints: action.hints, overridesAllowed: true)
    }

    /// Resolve one leg of a question's `on_answer` map — i.e., "if the user
    /// answers `value`, what route fires?".  Falls back to `.terminal` if
    /// the answer isn't in the map (defensive — schema requires it but old
    /// data may lack it).
    public func resolve(forAnswer value: String, of question: Question) -> RouteResolution {
        let leg = question.onAnswer?[value]
        let raw = leg?.route.intent ?? question.defaultRoute?.intent ?? .terminal
        return resolve(rawIntent: raw, hints: leg?.hints, overridesAllowed: false)
    }

    /// Resolve a single raw intent — the workhorse the others call. This is
    /// where the terminal-fallback rule lives: if the intent is
    /// capability-aware and unsupported, fall through to `.terminal`.
    public func resolve(
        rawIntent: Intent,
        hints: [String: JSONValue]? = nil,
        overridesAllowed: Bool = false
    ) -> RouteResolution {
        let effective: Intent = {
            if rawIntent.isCapabilityAware,
               !capabilities.supportedRoutes.contains(rawIntent) {
                return .terminal
            }
            return rawIntent
        }()

        let sublabel: String?
        let confirmation: String

        switch effective {
        case .task:
            sublabel = "Will create a task"
            confirmation = "task created"
        case .note:
            sublabel = "Will save as note"
            confirmation = "note saved"
        case .followup:
            sublabel = "Will queue an agent run"
            confirmation = "queued for Hermes"
        case .none:
            sublabel = nil
            confirmation = "dismissed"
        case .terminal:
            // When we degraded from a capability-aware intent, say so: the
            // app must never lie about what will happen.
            if effective != rawIntent {
                sublabel = "Will keep in inbox (\(rawIntent.rawValue) unavailable)"
            } else {
                sublabel = "Will keep in inbox"
            }
            confirmation = "kept in inbox"
        }

        // Overrides are only meaningful when there are hint fields the user
        // could override (project / due / labels) AND the resolved intent is
        // task-like.
        let hasOverrides = overridesAllowed
            && effective == .task
            && (hints?.keys.contains(where: { ["project", "due", "labels"].contains($0) }) ?? false)

        return RouteResolution(
            intent: effective,
            verb: effective.verb,
            sublabel: sublabel,
            symbol: effective.symbol,
            confirmation: confirmation,
            enabled: true,                // terminal-fallback is always enabled
            hasOverrides: hasOverrides
        )
    }
}
