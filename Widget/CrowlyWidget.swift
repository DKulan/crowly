// CrowlyWidget — the reader widget. Two sizes:
//   - systemSmall : unread count + the latest digest's bottom_line
//   - systemMedium: top 2–3 most-recent digests (job color stripe + title +
//                   bottom_line), each row `widgetURL`-deeplinks to
//                   `crowly://digest/<id>`
//
// No interactivity — taps open the app via the row's widget URL.

import WidgetKit
import SwiftUI

// MARK: - Entry

/// One row's worth of state for the widget.
struct WidgetDigestRow: Identifiable, Hashable {
    let id: String          // digest id (used by the deeplink and ForEach)
    let jobId: String
    let title: String
    let bottomLine: String
    let createdAt: Date
}

/// A single timeline entry — a snapshot of the inbox at a moment in time.
struct CrowlyEntry: TimelineEntry {
    let date: Date
    let rows: [WidgetDigestRow]
    let unreadCount: Int
    let latestBottomLine: String?
}

// MARK: - Provider

/// Reads from `DemoFixtures` in M1 demo mode. In real mode this would hit
/// `GET /summary` on the user's companion — same entry shape.
struct CrowlyProvider: TimelineProvider {
    func placeholder(in context: Context) -> CrowlyEntry {
        CrowlyEntry(
            date: .now,
            rows: [],
            unreadCount: 0,
            latestBottomLine: "Digests will appear here"
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (CrowlyEntry) -> Void) {
        completion(snapshot(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CrowlyEntry>) -> Void) {
        // M1 demo: single entry, never refresh (no live data to chase).
        let entry = snapshot(at: .now)
        completion(Timeline(entries: [entry], policy: .never))
    }

    private func snapshot(at date: Date) -> CrowlyEntry {
        // Sort by recency (urgency breaks ties — a high-urgency digest from
        // the same minute beats a low-urgency one).
        let sorted = DemoFixtures.digests.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.urgency > rhs.urgency
        }

        let rows: [WidgetDigestRow] = sorted.prefix(3).map { d in
            WidgetDigestRow(
                id: d.id,
                jobId: d.jobId,
                title: d.title,
                bottomLine: d.bottomLine,
                createdAt: d.createdAt
            )
        }

        return CrowlyEntry(
            date: date,
            rows: rows,
            // M1 demo mode treats every fixture digest as unread on each
            // widget snapshot — the widget process can't see the app's
            // `DigestStore`. M2 will read state from a shared App Group.
            unreadCount: DemoFixtures.digests.count,
            latestBottomLine: sorted.first?.bottomLine
        )
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
        default:            mediumLayout
        }
    }

    // MARK: - Medium

    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: Space.s) {
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
        .supportedFamilies([.systemSmall, .systemMedium])
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
