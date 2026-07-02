// WidgetSnapshotStore — the App Group bridge between the app and the widget.
//
// Phase 1 (live widget) data path:
//   - PRIMARY: the widget fetches `GET /summary` on its own ~15-min timeline
//     (see CrowlyProvider). The server's `unread_count` is authoritative.
//   - FALLBACK / SEED: this snapshot. Written to a shared App Group suite so
//     BOTH targets can reach it. Two writers, two reasons:
//       * The widget writes it after every successful `/summary` fetch, so the
//         last-known state is available when a later fetch fails (offline, VPS
//         asleep) — the widget shows real (if stale) digests instead of a
//         blank card.
//       * The app writes it after each refresh and after read/archive
//         mutations, reflecting local optimistic read-state. That seeds the
//         widget's very first render (before it has ever fetched) and keeps
//         the offline fallback current with what the user has actually read.
//
// This lives in `Shared/` so it compiles into both the app and the widget
// extension. `WidgetDigestRow` moved here (from the widget file) for the same
// reason — the app builds snapshots out of these rows, so the type can't be
// widget-only.
//
// Persistence: JSON in `UserDefaults(suiteName:)`. A snapshot is tiny (≤3
// rows + a count), so a plist value is cheaper than a file container and
// the same App Group entitlement backs both.

import Foundation

// MARK: - Row

/// One row's worth of widget state — a content-only projection of a digest
/// (no `state`; the count carries unread). Shared so the app can build a
/// snapshot and the widget can render one from either `/summary` or the
/// fallback snapshot.
struct WidgetDigestRow: Identifiable, Hashable, Codable, Sendable {
    let id: String          // digest id (used by the deeplink and ForEach)
    let jobId: String
    let title: String
    let bottomLine: String
    let createdAt: Date

    init(id: String, jobId: String, title: String, bottomLine: String, createdAt: Date) {
        self.id = id
        self.jobId = jobId
        self.title = title
        self.bottomLine = bottomLine
        self.createdAt = createdAt
    }
}

// MARK: - Snapshot

/// A serialisable snapshot of the widget surface: the latest few rows, the
/// authoritative unread count, and the total (non-archived) digest count for
/// the large widget's "View all N →" footer — stamped with when it was
/// captured so a fallback render can decide how much to trust it.
struct WidgetSnapshot: Codable, Sendable {
    let rows: [WidgetDigestRow]
    let unreadCount: Int
    /// Total non-archived digests (≥ `rows.count`). Backs the large widget's
    /// "View all N →" footer, shown only when `total > rows.count`.
    let total: Int
    let capturedAt: Date

    init(rows: [WidgetDigestRow], unreadCount: Int, total: Int, capturedAt: Date) {
        self.rows = rows
        self.unreadCount = unreadCount
        self.total = total
        self.capturedAt = capturedAt
    }

    /// Max rows carried — enough to fill the `.systemLarge` widget (4–5 rows
    /// per ux.md). Small/medium render fewer from the same snapshot.
    static let maxRows = 5

    /// Build a snapshot from digests. Shared by the app (its `/list` view)
    /// and the widget (its `/summary` view) so both project + sort rows
    /// identically: newest-first, urgency breaking a same-instant tie, capped
    /// at `maxRows`. `unreadCount` and `total` are passed in — the app derives
    /// them from local state, the widget takes the server's `unread_count` /
    /// `total`. `total` defaults to the digest count when the caller has the
    /// full (non-archived) set in hand.
    static func build(
        from digests: [Digest],
        unreadCount: Int,
        total: Int? = nil,
        capturedAt: Date
    ) -> WidgetSnapshot {
        let sorted = digests.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.urgency > rhs.urgency
        }
        let rows = sorted.prefix(maxRows).map { d in
            WidgetDigestRow(
                id: d.id,
                jobId: d.jobId,
                title: d.title,
                bottomLine: d.bottomLine,
                createdAt: d.createdAt
            )
        }
        return WidgetSnapshot(
            rows: rows,
            unreadCount: unreadCount,
            total: total ?? digests.count,
            capturedAt: capturedAt
        )
    }
}

// MARK: - Store

/// Read/write the shared snapshot. Stateless; every call reaches the App Group
/// `UserDefaults` suite directly (thread-safe).
enum WidgetSnapshotStore {

    /// The App Group suite. Must match the `application-groups` entitlement on
    /// BOTH targets (see project.yml). iOS requires the `group.` prefix.
    static let appGroup = "group.com.crowly"

    /// Bump the suffix if the stored shape ever changes incompatibly — an old
    /// snapshot under a stale key is simply ignored (decode returns nil). v2
    /// added the non-optional `total` field (large-widget footer), so a v1
    /// blob wouldn't decode; the bump avoids relying on that failure path.
    private static let key = "widget_snapshot_v2"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    /// Persist the latest snapshot. Silent no-op if the suite is unavailable
    /// (misconfigured entitlement) or encoding fails — a missing snapshot
    /// just means the widget falls through to its unpaired/placeholder path.
    static func write(_ snapshot: WidgetSnapshot) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    /// The last snapshot written by either target, or nil if none exists yet.
    static func read() -> WidgetSnapshot? {
        guard let defaults,
              let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            return nil
        }
        return snapshot
    }

    /// Drop the snapshot — called on disconnect so a disconnected widget can't
    /// keep showing a previous companion's digests.
    static func clear() {
        defaults?.removeObject(forKey: key)
    }
}
