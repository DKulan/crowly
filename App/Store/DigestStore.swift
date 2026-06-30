// DigestStore — the in-memory view-model that the app reads from.
//
// In M1 demo mode this is fed by `DemoFixtures`. When real ingestion arrives,
// this same store will be backed by HTTP/JSON from the user's companion — the
// UI surface doesn't change.
//
// What lives here:
//   - The canonical list of digests (newest-first)
//   - Per-digest read/archived state
//   - Inbox sectioning by relative date
//   - Search + the most-recent archive undo target
//
// Concurrency: @MainActor — all UI state changes happen on the main actor,
// which keeps Swift 6 strict-concurrency happy and matches the SwiftUI
// rendering model.

import SwiftUI
import Foundation
import Observation

@MainActor
@Observable
final class DigestStore {

    // MARK: - Inputs

    /// Demo-mode flag. Drives the demo banner and seeds the store with
    /// `DemoFixtures.digests`. M1 default is `true`.
    var isInDemoMode: Bool

    // MARK: - Backing state

    private(set) var digests: [Digest]

    /// Per-digest UI state (unread / read / archived).
    private var digestStates: [String: DigestState] = [:]

    /// Most recently archived digest id — surfaces an undo affordance after
    /// a swipe.
    private(set) var lastArchivedId: String?

    // MARK: - Init

    init(
        digests: [Digest] = DemoFixtures.digests,
        isInDemoMode: Bool = true
    ) {
        self.digests = digests
        self.isInDemoMode = isInDemoMode
        // All digests start `.unread` so the inbox shows the right cue.
        for d in digests {
            self.digestStates[d.id] = .unread
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
    /// archived.
    func markRead(_ digest: Digest) {
        if digestStates[digest.id] == .unread || digestStates[digest.id] == nil {
            digestStates[digest.id] = .read
        }
    }

    /// Archive a digest. Captures the id so the swipe-undo affordance can
    /// surface the most recent archive.
    func archive(_ digest: Digest) {
        digestStates[digest.id] = .archived
        lastArchivedId = digest.id
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
        return id
    }

    // MARK: - Demo refresh (no-op; surface for `.refreshable`)

    func refresh() async {
        // No-op in demo mode; real mode hits the companion.
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    var isEmpty: Bool { digests.isEmpty }

    func isEmpty(forQuery query: String) -> Bool {
        sectionedDigests(matching: query).isEmpty
    }
}
