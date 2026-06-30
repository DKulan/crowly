// DeepLinkRouter — the bridge from `.onOpenURL` (app scene) into the
// `NavigationStack` (`InboxView`).
//
// The URL handler at the scene level doesn't sit *above* the
// NavigationStack — so we can't drive navigation by mutating its path
// directly from there. Instead the scene parses the URL into a
// `pendingDigestId`, and `InboxView` watches the router with `.onChange`
// and appends the id to its own `NavigationPath` when it lands.
//
// Why a separate object instead of a binding through `ContentView`:
// the digest URL might arrive while the user is already deep in another
// digest. The router's "pending" semantics let `InboxView` decide
// whether to pop-to-root first, reuse the existing destination, etc.
//
// Bug #2 fix from review pass B.

import Observation
import SwiftUI

@MainActor
@Observable
final class DeepLinkRouter {
    /// The digest id the user wants to jump to. `InboxView` clears this
    /// after pushing the destination so the same link can fire twice.
    var pendingDigestId: String? = nil

    /// Set when a `crowly://pair` URL arrives — drives the inbox into
    /// presenting `PairCompanionView`. The URL is undocumented and exists
    /// so an App Reviewer (and the run-crowly skill) has a deterministic
    /// way to surface the pairing UI without touching the screen.
    var pendingPair: Bool = false

    /// Parse a `crowly://digest/<id>` URL. Returns the id, or `nil` if the
    /// URL isn't a digest deeplink. Defensive: ignores unknown hosts /
    /// trailing slashes so future URL shapes can be added additively.
    ///
    /// Pure function — `nonisolated` so tests + the `.onOpenURL` closure
    /// can call it without main-actor hops.
    nonisolated static func digestId(from url: URL) -> String? {
        guard url.scheme == "crowly" else { return nil }
        guard url.host == "digest" else { return nil }
        let trimmed = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// True iff the URL is `crowly://pair` (the pair-sheet shortcut).
    nonisolated static func isPairURL(_ url: URL) -> Bool {
        url.scheme == "crowly" && url.host == "pair"
    }

    /// Route a URL into the right pending slot. No-op if neither matches.
    func handle(_ url: URL) {
        if let id = Self.digestId(from: url) {
            pendingDigestId = id
            return
        }
        if Self.isPairURL(url) {
            pendingPair = true
        }
    }
}
