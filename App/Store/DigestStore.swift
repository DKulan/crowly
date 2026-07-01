// DigestStore — the in-memory view-model the app reads from.
//
// Two modes, picked at launch from the credential store:
//
//   * **Demo mode** (unpaired). Seeded from `DemoFixtures.digests`; mutations
//     are local-only. This is the first-run default and the only thing a
//     non-self-hoster (incl. an App Reviewer) sees. CLAUDE.md hard invariant:
//     demo mode stays intact unless the user has paired.
//
//   * **Live mode** (paired). Pulled from the user's companion via
//     `CompanionClient.list()`. Read/archive mutations mirror to the
//     companion via `POST /state` so it remains the source of truth
//     (architecture.md § Companion → Store: "state lives here too, mirrored
//     from the app via simple state-change writes").
//
// The UI never branches on mode — the inbox just reads `digests` and the
// mutation API. The store handles the rest.
//
// Concurrency: @MainActor — all UI state changes happen on the main actor.
// Mirror writes to the companion are fired off as detached tasks so a slow
// POST never blocks the optimistic local flip.

import SwiftUI
import Foundation
import Observation

@MainActor
@Observable
final class DigestStore {

    // MARK: - Inputs

    /// Demo-mode flag. Drives the demo banner and seeds the store with
    /// `DemoFixtures.digests`. Computed from `credentials.isPaired` at
    /// launch and after a successful pair / disconnect.
    private(set) var isInDemoMode: Bool

    // MARK: - Backing state

    private(set) var digests: [Digest]

    /// Per-digest UI state (unread / read / archived).
    private var digestStates: [String: DigestState] = [:]

    /// Most recently archived digest id — surfaces an undo affordance after
    /// a swipe.
    private(set) var lastArchivedId: String?

    /// Last refresh failure, surfaced to the UI for the pull-to-refresh
    /// error path. Cleared on the next successful refresh.
    private(set) var lastRefreshError: CompanionError?

    /// Guards against overlapping refreshes. The foreground poll and a
    /// manual pull-to-refresh can both call `refresh()`; without this they
    /// could fire two concurrent `/list` calls and let a stale snapshot
    /// clobber a fresher one.
    private var isRefreshing = false

    // MARK: - Dependencies

    /// Source of credentials. Tests swap in `InMemoryCredentialStore`.
    private let credentials: CredentialStore

    /// Real client when paired; `nil` in demo mode. We build this lazily
    /// (and rebuild it on re-pair) so a stale client never out-lives a
    /// disconnect.
    private var client: CompanionClient?

    // MARK: - Init

    /// Default path: demo mode with bundled fixtures, no credential store
    /// access. Used by previews and the existing test suite — the test
    /// store should never reach into the real keychain.
    convenience init() {
        self.init(credentials: InMemoryCredentialStore())
    }

    /// Live/test path. Pass `KeychainStore()` from the app for the real
    /// keychain-backed credential source; pass `InMemoryCredentialStore()`
    /// for tests. When `credentials.isPaired` is true we start empty and
    /// the caller refreshes; otherwise we seed demo fixtures.
    init(
        credentials: CredentialStore,
        seedDigests: [Digest]? = nil
    ) {
        self.credentials = credentials
        let paired = credentials.isPaired
        self.isInDemoMode = !paired

        if paired {
            // Live mode: start empty so the inbox doesn't briefly show demo
            // fixtures over a real account. The view triggers a refresh.
            self.digests = seedDigests ?? []
            self.client = CompanionClient(credentials: credentials)
        } else {
            // Demo mode: seed from fixtures, identical to prior behaviour.
            self.digests = seedDigests ?? DemoFixtures.digests
            self.client = nil
            for d in self.digests {
                self.digestStates[d.id] = .unread
            }
        }
    }

    // MARK: - Lookups

    func digest(byId id: String) -> Digest? {
        digests.first(where: { $0.id == id })
    }

    func digestState(for digestId: String) -> DigestState {
        digestStates[digestId] ?? .unread
    }

    // MARK: - Status dot

    func statusDotState(for digest: Digest) -> StatusDot.State {
        switch digestState(for: digest.id) {
        case .unread:   return .unread
        case .read:     return .read
        case .archived: return .archived
        }
    }

    // MARK: - Sections

    struct Section: Identifiable, Hashable {
        let id: String
        let title: String
        let digests: [Digest]
    }

    /// Non-archived digests sorted by urgency desc, then time desc, then
    /// sectioned by relative date. Search filters across title, bottom_line,
    /// and summary.
    func sectionedDigests(matching query: String) -> [Section] {
        let now = Date()
        let cal = Calendar.current
        let visible = digests.filter { digestState(for: $0.id) != .archived }
        let filtered: [Digest] = {
            guard !query.isEmpty else { return visible }
            let q = query.lowercased()
            return visible.filter { d in
                d.title.lowercased().contains(q)
                    || d.bottomLine.lowercased().contains(q)
                    || d.summary?.lowercased().contains(q) == true
            }
        }()

        let sorted = filtered.sorted { lhs, rhs in
            if lhs.urgency != rhs.urgency { return lhs.urgency > rhs.urgency }
            return lhs.createdAt > rhs.createdAt
        }

        // Section by relative date.
        var sections: [String: [Digest]] = [:]
        for d in sorted {
            let key = sectionKey(for: d.createdAt, now: now, calendar: cal)
            sections[key, default: []].append(d)
        }

        let order = ["Today", "Yesterday", "This week", "Earlier"]
        return order.compactMap { key in
            guard let items = sections[key] else { return nil }
            return Section(id: key, title: key, digests: items)
        }
    }

    private func sectionKey(for date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
           date > weekAgo {
            return "This week"
        }
        return "Earlier"
    }

    // MARK: - Mutations

    /// Mark a digest as read. Idempotent — once read, it stays read until
    /// archived. In live mode the change mirrors to the companion in the
    /// background; a network failure does NOT roll back the local flip
    /// (the app stays usable offline; a future refresh resyncs).
    func markRead(_ digest: Digest) {
        guard digestStates[digest.id] == .unread || digestStates[digest.id] == nil else {
            return
        }
        digestStates[digest.id] = .read
        mirrorState(id: digest.id, state: .read)
    }

    /// Archive a digest. Captures the id so the swipe-undo affordance can
    /// surface the most recent archive.
    func archive(_ digest: Digest) {
        digestStates[digest.id] = .archived
        lastArchivedId = digest.id
        mirrorState(id: digest.id, state: .archived)
    }

    /// Undo the most recent archive. Returns the unarchived digest's id (or
    /// nil if nothing to undo).
    @discardableResult
    func undoArchive() -> String? {
        guard let id = lastArchivedId else { return nil }
        // Restore to .read — if the user had already opened it before
        // archiving, leaving it unread on undo would be a lie.
        digestStates[id] = .read
        lastArchivedId = nil
        mirrorState(id: id, state: .read)
        return id
    }

    /// Fire-and-forget state mirror. Demo mode skips it; live mode posts
    /// without awaiting (the local mutation has already happened, and the
    /// inbox UI is optimistic). A logged failure here is fine — the next
    /// successful `refresh()` will pull authoritative state.
    private func mirrorState(id: String, state: DigestState) {
        guard let client else { return }
        Task.detached(priority: .utility) {
            do {
                try await client.setState(id: id, state: state)
            } catch {
                // Best-effort: log to console; UI doesn't surface this.
                // Reasoning: state writes are an optimization for cross-device
                // sync (architecture.md § Push reload), not a user-facing
                // contract. If a write drops, the next /list re-snapshots it.
                #if DEBUG
                print("[DigestStore] mirrorState failed: \(error)")
                #endif
            }
        }
    }

    // MARK: - Refresh

    /// Pull-to-refresh handler. In demo mode it's a brief no-op so the
    /// `.refreshable` spinner feels honest; in live mode it hits `/list`
    /// and replaces the in-memory state with the companion's view.
    func refresh() async {
        guard let client else {
            // Demo mode: a tiny pause so the spinner doesn't disappear instantly.
            try? await Task.sleep(nanoseconds: 200_000_000)
            return
        }
        // Drop the call if one is already in flight (e.g. the interval poll
        // fires while a manual pull is still awaiting). The in-flight refresh
        // will deliver the freshest snapshot.
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let envelopes = try await client.list()
            apply(envelopes: envelopes)
            lastRefreshError = nil
        } catch let error as CompanionError {
            lastRefreshError = error
        } catch {
            lastRefreshError = .unreachable(underlying: error.localizedDescription)
        }
    }

    /// Replace the digest list + state from a fresh `/list`. Local archive-
    /// undo affordances are cleared — once the server's authoritative state
    /// arrives, an undo against a stale archive isn't meaningful anyway.
    private func apply(envelopes: [DigestEnvelope]) {
        self.digests = envelopes.map(\.digest)
        var states: [String: DigestState] = [:]
        for env in envelopes {
            states[env.digest.id] = env.state
        }
        self.digestStates = states
        self.lastArchivedId = nil
    }

    // MARK: - Pairing transitions

    /// Called by the pairing view after credentials have been written to
    /// the keychain. Flips the store into live mode and triggers an initial
    /// refresh so the first real digest replaces the demo fixtures.
    func didPair() async {
        // Rebuild the client against the freshly-stored credentials.
        self.client = CompanionClient(credentials: credentials)
        self.isInDemoMode = false
        self.digests = []
        self.digestStates = [:]
        self.lastArchivedId = nil
        await refresh()
    }

    /// Called by the settings/disconnect path. Clears credentials and falls
    /// back to demo fixtures so the inbox is never empty.
    func didDisconnect() {
        try? credentials.clearAll()
        self.client = nil
        self.isInDemoMode = true
        self.digests = DemoFixtures.digests
        self.digestStates = [:]
        for d in self.digests {
            self.digestStates[d.id] = .unread
        }
        self.lastArchivedId = nil
        self.lastRefreshError = nil
    }

    // MARK: - Convenience

    var isEmpty: Bool { digests.isEmpty }

    func isEmpty(forQuery query: String) -> Bool {
        sectionedDigests(matching: query).isEmpty
    }
}
