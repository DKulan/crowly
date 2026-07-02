// CrowlyWidget — the reader widget. Three sizes:
//   - systemSmall : unread count + the latest digest's bottom_line
//   - systemMedium: top 2–3 most-recent digests (job color stripe + title +
//                   bottom_line), each row `widgetURL`-deeplinks to
//                   `crowly://digest/<id>`
//   - systemLarge : same shape as medium, up to 5 rows + a "View all N →"
//                   footer deeplinking to `crowly://inbox` (ux.md § widget)
//
// No interactivity — taps open the app via the row's widget URL. Hard
// invariant (CLAUDE.md): the widget is read-only — `Link`-deeplink rows only,
// NEVER `Button(intent:)`.
//
// Data path (Phase 1 — live widget):
//   - Unpaired  → demo fixtures (the App-Review / first-run experience).
//   - Paired    → fetch `GET /summary` on this provider's own ~15-min
//                 timeline. On success, render the server's rows +
//                 authoritative `unread_count` and cache them to the App Group
//                 snapshot. On failure (offline, VPS asleep), fall back to the
//                 last snapshot the app or a prior fetch wrote.
// `WidgetDigestRow` / `WidgetSnapshot` / `WidgetSnapshotStore` live in
// `Shared/` so the app can build the same rows the widget renders.

import WidgetKit
import SwiftUI

// MARK: - Entry

/// A single timeline entry — a snapshot of the inbox at a moment in time.
struct CrowlyEntry: TimelineEntry {
    let date: Date
    let rows: [WidgetDigestRow]
    let unreadCount: Int
    let latestBottomLine: String?
    /// Total non-archived digests (≥ `rows.count`). Only the large widget uses
    /// it, for the "View all N →" footer. Defaults to `rows.count` so small/
    /// medium and the previews don't have to supply it.
    var total: Int = 0
}

// MARK: - Completion box

/// Carries WidgetKit's non-`@Sendable` timeline completion across the `Task`
/// boundary in `getTimeline`. Swift 6 refuses to let a bare non-Sendable
/// closure be captured by a concurrently-executing closure; wrapping it in an
/// `@unchecked Sendable` box makes the intent explicit and is safe here —
/// WidgetKit invokes the completion exactly once, from one continuation.
private final class CompletionBox: @unchecked Sendable {
    private let completion: (Timeline<CrowlyEntry>) -> Void
    init(_ completion: @escaping (Timeline<CrowlyEntry>) -> Void) {
        self.completion = completion
    }
    func call(_ timeline: Timeline<CrowlyEntry>) { completion(timeline) }
}

// MARK: - Provider

/// Feeds the widget. Branches on pairing:
///   - paired   → live `/summary` fetch with App Group snapshot fallback,
///                reloading on a ~15-min timeline.
///   - unpaired → demo fixtures, no reload (nothing live to chase).
struct CrowlyProvider: TimelineProvider {

    /// Timeline reload floor for the live path — matches the roadmap's
    /// committed "~15-minute reload floor against GET /summary". WidgetKit
    /// treats this as a request, not a guarantee; the OS may space reloads
    /// further apart under budget pressure.
    private static let reloadInterval: TimeInterval = 15 * 60

    private let credentials: CredentialStore = KeychainStore()

    func placeholder(in context: Context) -> CrowlyEntry {
        CrowlyEntry(
            date: .now,
            rows: [],
            unreadCount: 0,
            latestBottomLine: "Digests will appear here"
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (CrowlyEntry) -> Void) {
        // Gallery/transient snapshot: cheap, synchronous. Prefer the last
        // cached snapshot when paired; otherwise show demo.
        if credentials.isPaired, let cached = WidgetSnapshotStore.read() {
            completion(Self.entry(from: cached, at: .now))
        } else {
            completion(demoEntry(at: .now))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CrowlyEntry>) -> Void) {
        // Unpaired: single demo entry, never refresh (no live data to chase).
        guard credentials.isPaired else {
            completion(Timeline(entries: [demoEntry(at: .now)], policy: .never))
            return
        }

        // Precompute everything the async closure needs from non-Sendable
        // inputs (`context`, `self`) up front, so the `Task` captures only
        // Sendable values — Swift 6 flags capturing `Context` in a concurrent
        // closure otherwise. WidgetKit's `completion` isn't `@Sendable`, so it
        // rides through a one-shot box (WidgetKit calls it exactly once).
        let credentials = self.credentials
        let placeholderEntry = placeholder(in: context)
        let sink = CompletionBox(completion)

        // Paired: fetch /summary, fall back to the cached snapshot on failure.
        Task {
            let client = CompanionClient(credentials: credentials)
            let now = Date()
            let next = now.addingTimeInterval(Self.reloadInterval)
            let result: CrowlyEntry
            do {
                let summary = try await client.summary()
                let snapshot = WidgetSnapshot.build(
                    from: summary.latest.map(\.digest),
                    unreadCount: summary.unread_count,
                    // Server's non-archived total (older companion → nil →
                    // falls back to the row count, so the footer just hides).
                    total: summary.total,
                    capturedAt: now
                )
                // Cache so a later failed fetch (or the app's first render)
                // has real data to fall back to.
                WidgetSnapshotStore.write(snapshot)
                result = Self.entry(from: snapshot, at: now)
            } catch {
                // Offline / VPS asleep / transient: show the last known good
                // snapshot rather than a blank card, and retry on schedule.
                result = WidgetSnapshotStore.read().map { Self.entry(from: $0, at: now) }
                    ?? placeholderEntry
            }
            sink.call(Timeline(entries: [result], policy: .after(next)))
        }
    }

    // MARK: Entry builders

    /// Build a timeline entry from a stored/fetched snapshot. Static so the
    /// async `getTimeline` closure can call it without capturing `self`.
    private static func entry(from snapshot: WidgetSnapshot, at date: Date) -> CrowlyEntry {
        CrowlyEntry(
            date: date,
            rows: snapshot.rows,
            unreadCount: snapshot.unreadCount,
            latestBottomLine: snapshot.rows.first?.bottomLine,
            total: snapshot.total
        )
    }

    /// The unpaired demo entry — the first-run / App-Review experience.
    private func demoEntry(at date: Date) -> CrowlyEntry {
        let snapshot = WidgetSnapshot.build(
            from: DemoFixtures.digests,
            // Demo mode treats every fixture digest as unread — the widget
            // process can't see the app's in-memory read state, and there's
            // no companion to ask.
            unreadCount: DemoFixtures.digests.count,
            capturedAt: date
        )
        return Self.entry(from: snapshot, at: date)
    }
}

// MARK: - Entry view

struct CrowlyWidgetEntryView: View {
    let entry: CrowlyEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemMedium: mediumLayout
        case .systemSmall:  smallLayout
        case .systemLarge:  largeLayout
        default:            mediumLayout
        }
    }

    // MARK: - Header

    /// Shared header row (app glyph + name + unread count) used by the medium
    /// and large layouts so they stay visually identical.
    private var header: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "tray.full")
                .widgetAccentable()
            Text("Crowly")
                .font(.caption.weight(.semibold))
            Spacer()
            if entry.unreadCount > 0 {
                Text("\(entry.unreadCount) unread")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .widgetAccentable()
            }
        }
    }

    // MARK: - Medium

    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            header

            if entry.rows.isEmpty {
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Text("No digests yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer(minLength: 0)
            } else {
                VStack(spacing: Space.xs) {
                    ForEach(entry.rows.prefix(3)) { row in
                        WidgetDigestRowView(row: row)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(Space.m)
        .containerBackground(for: .widget) { Color.clear }
    }

    // MARK: - Large

    /// `.systemLarge` — same shape as medium, but up to 5 rows plus a
    /// "View all N →" footer that deeplinks to the inbox root (ux.md § widget).
    /// Read-only, like every widget size: `Link` rows only, no `Button(intent:)`.
    private var largeLayout: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            header

            if entry.rows.isEmpty {
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Text("No digests yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer(minLength: 0)
            } else {
                VStack(spacing: Space.xs) {
                    ForEach(entry.rows.prefix(5)) { row in
                        WidgetDigestRowView(row: row)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)

                // Footer: only when there's more in the inbox than we can show.
                if entry.total > entry.rows.count {
                    Link(destination: URL(string: "crowly://inbox")!) {
                        HStack(spacing: Space.xs) {
                            Text("View all \(entry.total)")
                            Image(systemName: "arrow.right")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .widgetAccentable()
                    }
                }
            }
        }
        .padding(Space.m)
        .containerBackground(for: .widget) { Color.clear }
    }

    // MARK: - Small

    private var smallLayout: some View {
        // Whole-widget deeplink to the latest digest, when there is one.
        let deeplink: URL? = entry.rows.first.flatMap { row in
            URL(string: "crowly://digest/\(row.id)")
        }

        return VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Image(systemName: "tray.full").widgetAccentable()
                Spacer()
                Text("\(entry.unreadCount)")
                    .font(.headline)
                    .widgetAccentable()
            }
            Spacer(minLength: 0)
            Text(entry.latestBottomLine ?? "No digests yet.")
                .font(.subheadline)
                .lineLimit(4)
                .foregroundStyle(entry.latestBottomLine == nil ? .secondary : .primary)
        }
        .padding(Space.m)
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(deeplink)
    }
}

// MARK: - Row

struct WidgetDigestRowView: View {
    let row: WidgetDigestRow
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme)         private var scheme

    var body: some View {
        // Nil-coalesce the URL construction — a malformed id should produce
        // a no-op tap, not crash the widget process.
        let url = URL(string: "crowly://digest/\(row.id)")
            ?? URL(string: "crowly://")!
        return Link(destination: url) {
            HStack(alignment: .top, spacing: Space.s) {
                // Job color stripe — replaced with white in accented mode so
                // the system tinting stays predictable.
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        renderingMode == .accented
                            ? Color.white
                            : JobColor.color(for: row.jobId, in: scheme)
                    )
                    .frame(width: Space.xs, height: 36)
                    .widgetAccentable()

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(row.bottomLine)
                        .font(.caption2)
                        .lineLimit(2)
                        .minimumScaleFactor(0.9)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Widget configuration

struct CrowlyWidget: Widget {
    let kind = "CrowlyDigests"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CrowlyProvider()) { entry in
            CrowlyWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Crowly")
        .description("Your latest digests")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - Bundle

@main
struct CrowlyWidgetBundle: WidgetBundle {
    var body: some Widget {
        CrowlyWidget()
    }
}

// MARK: - Previews

#Preview(as: .systemMedium) {
    CrowlyWidget()
} timeline: {
    CrowlyEntry(
        date: .now,
        rows: [
            WidgetDigestRow(
                id: "dgst_2026-06-29_ai-news",
                jobId: "ai-news-daily",
                title: "AI news — Monday roundup",
                bottomLine: "Two major model releases this weekend.",
                createdAt: .now
            ),
            WidgetDigestRow(
                id: "dgst_2026-06-29_weather",
                jobId: "weather-local",
                title: "Severe thunderstorm watch",
                bottomLine: "Gusts to 90 km/h possible; 2 PM–9 PM.",
                createdAt: .now
            )
        ],
        unreadCount: 5,
        latestBottomLine: "Two major model releases this weekend."
    )
}

#Preview(as: .systemSmall) {
    CrowlyWidget()
} timeline: {
    CrowlyEntry(
        date: .now,
        rows: [
            WidgetDigestRow(
                id: "dgst_2026-06-29_ai-news",
                jobId: "ai-news-daily",
                title: "AI news",
                bottomLine: "Two major model releases this weekend.",
                createdAt: .now
            )
        ],
        unreadCount: 3,
        latestBottomLine: "Two major model releases this weekend."
    )
}

#Preview(as: .systemLarge) {
    CrowlyWidget()
} timeline: {
    CrowlyEntry(
        date: .now,
        rows: [
            WidgetDigestRow(
                id: "dgst_2026-06-29_ai-news",
                jobId: "ai-news-daily",
                title: "AI news — Monday roundup",
                bottomLine: "Two major model releases this weekend.",
                createdAt: .now
            ),
            WidgetDigestRow(
                id: "dgst_2026-06-29_weather",
                jobId: "weather-local",
                title: "Severe thunderstorm watch",
                bottomLine: "Gusts to 90 km/h possible; 2 PM–9 PM.",
                createdAt: .now
            ),
            WidgetDigestRow(
                id: "dgst_2026-06-28_community",
                jobId: "harmony-weekly-public-digest",
                title: "Harmony Community — weekly digest",
                bottomLine: "Council met Thursday — two bylaw drafts in public comment.",
                createdAt: .now
            ),
            WidgetDigestRow(
                id: "dgst_2026-06-28_reminder",
                jobId: "reminders-daily",
                title: "Reminder — recycling pickup",
                bottomLine: "Bins out by 7 AM Monday.",
                createdAt: .now
            ),
            WidgetDigestRow(
                id: "dgst_2026-06-27_market-pulse",
                jobId: "market-pulse-weekly",
                title: "Market Pulse — weekly digest",
                bottomLine: "Nothing actionable. Two headlines flagged for context.",
                createdAt: .now
            )
        ],
        unreadCount: 5,
        latestBottomLine: "Two major model releases this weekend.",
        total: 8
    )
}
