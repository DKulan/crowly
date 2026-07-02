// Widget data-path tests (Phase 1 — live widget).
//
// What we prove here:
//   - `WidgetSnapshot.build` projects digests into rows the widget renders:
//     newest-first, urgency breaking a same-instant tie, capped at 3.
//   - The App Group snapshot round-trips through `WidgetSnapshotStore`
//     (write → read → clear) so the widget's offline fallback and the app's
//     seed write agree on the wire shape.
//
// These back the invariant that the widget shows *real* data: the app builds
// snapshots with the exact same sort/limit the widget uses, so what the user
// sees in the inbox and on the home screen can't diverge.

import Testing
import Foundation
@testable import Crowly

// MARK: - Helpers

private func digest(
    id: String,
    urgency: Urgency = .normal,
    createdAt: String,
    bottomLine: String = "bl"
) -> Digest {
    Digest(
        schemaVersion: 1,
        id: id,
        jobId: "job-\(id)",
        source: "hermes-cron",
        title: "Title \(id)",
        createdAt: CrowlyISO8601.parse(createdAt)!,
        urgency: urgency,
        bottomLine: bottomLine
    )
}

// MARK: - build()

@Test func snapshotBuildSortsNewestFirst() {
    let digests = [
        digest(id: "old", createdAt: "2026-06-27T09:00:00Z"),
        digest(id: "new", createdAt: "2026-06-29T09:00:00Z"),
        digest(id: "mid", createdAt: "2026-06-28T09:00:00Z"),
    ]
    let snap = WidgetSnapshot.build(from: digests, unreadCount: 3, capturedAt: Date())
    #expect(snap.rows.map(\.id) == ["new", "mid", "old"])
}

@Test func snapshotBuildBreaksTiesByUrgency() {
    // Same instant → higher urgency wins the ordering.
    let ts = "2026-06-29T09:00:00Z"
    let digests = [
        digest(id: "low", urgency: .low, createdAt: ts),
        digest(id: "urgent", urgency: .urgent, createdAt: ts),
        digest(id: "normal", urgency: .normal, createdAt: ts),
    ]
    let snap = WidgetSnapshot.build(from: digests, unreadCount: 0, capturedAt: Date())
    #expect(snap.rows.map(\.id) == ["urgent", "normal", "low"])
}

@Test func snapshotBuildCapsAtFiveRows() {
    // maxRows == 5 so the large widget can fill its 4–5 rows.
    let digests = (0..<8).map { i in
        digest(id: "d\(i)", createdAt: "2026-06-2\(i)T09:00:00Z")
    }
    let snap = WidgetSnapshot.build(from: digests, unreadCount: 8, capturedAt: Date())
    #expect(snap.rows.count == 5)
    // unreadCount is passed through verbatim — NOT clamped to the row count.
    #expect(snap.unreadCount == 8)
}

@Test func snapshotBuildTotalDefaultsToDigestCount() {
    // When the caller has the full (non-archived) set in hand and passes no
    // explicit total, `total` reflects the full count even though rows cap at 5.
    let digests = (0..<8).map { i in
        digest(id: "d\(i)", createdAt: "2026-06-2\(i)T09:00:00Z")
    }
    let snap = WidgetSnapshot.build(from: digests, unreadCount: 8, capturedAt: Date())
    #expect(snap.rows.count == 5)
    #expect(snap.total == 8)   // full inbox size → drives "View all 8 →"
}

@Test func snapshotBuildTotalHonorsExplicitServerValue() {
    // The widget passes the server's `total` even when it only received a few
    // rows in /summary.latest — so the footer reflects the real inbox size.
    let digests = [
        digest(id: "a", createdAt: "2026-06-29T09:00:00Z"),
        digest(id: "b", createdAt: "2026-06-28T09:00:00Z"),
    ]
    let snap = WidgetSnapshot.build(from: digests, unreadCount: 2, total: 12, capturedAt: Date())
    #expect(snap.rows.count == 2)
    #expect(snap.total == 12)
}

@Test func snapshotBuildCarriesRowFields() {
    let d = digest(id: "x", urgency: .high, createdAt: "2026-06-29T09:00:00Z", bottomLine: "the line")
    let snap = WidgetSnapshot.build(from: [d], unreadCount: 1, capturedAt: Date())
    let row = try! #require(snap.rows.first)
    #expect(row.id == "x")
    #expect(row.jobId == "job-x")
    #expect(row.title == "Title x")
    #expect(row.bottomLine == "the line")
}

// MARK: - Store round-trip

@Test func snapshotStoreRoundTrips() throws {
    WidgetSnapshotStore.clear()
    defer { WidgetSnapshotStore.clear() }

    let captured = CrowlyISO8601.parse("2026-06-29T12:00:00Z")!
    let original = WidgetSnapshot.build(
        from: [digest(id: "a", createdAt: "2026-06-29T09:00:00Z")],
        unreadCount: 4,
        total: 9,
        capturedAt: captured
    )
    WidgetSnapshotStore.write(original)

    let read = try #require(WidgetSnapshotStore.read())
    #expect(read.unreadCount == 4)
    #expect(read.total == 9)
    #expect(read.rows.map(\.id) == ["a"])
    // Date survives the JSON round-trip to the second.
    #expect(abs(read.capturedAt.timeIntervalSince(captured)) < 1)
}

@Test func snapshotStoreClearRemovesSnapshot() {
    WidgetSnapshotStore.write(
        WidgetSnapshot.build(
            from: [digest(id: "a", createdAt: "2026-06-29T09:00:00Z")],
            unreadCount: 1,
            capturedAt: Date()
        )
    )
    WidgetSnapshotStore.clear()
    #expect(WidgetSnapshotStore.read() == nil)
}
