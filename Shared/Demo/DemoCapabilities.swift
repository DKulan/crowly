// DemoCapabilities — the canned `GET /capabilities` value used in M1 demo
// mode. Simulates Daniel's box per the team-lead brief:
//
//   "capabilities are a canned set (e.g. task+note available, followup
//   available, simulating Daniel's box)"
//
// In real pairing this is replaced by the live response from the user's
// companion. The RouteResolver indirection above makes that drop-in.

import Foundation

public enum DemoCapabilities {
    /// Daniel's simulated box: Todoist task creation, Obsidian-git note
    /// saving, and Hermes followup re-runs are all wired. `none` and the
    /// `terminal` fallback are always implicitly available.
    public static let standard = Capabilities(
        schemaVersion: 1,
        companionVersion: "0.1.0-demo",
        supportedReplyKinds: [.yesNo, .freeText, .choice],
        supportedRoutes: [.task, .note, .followup, .none]
    )
}
