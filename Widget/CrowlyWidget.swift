// CrowlyWidget — the systemMedium widget. Up to two open loops from the SAME
// demo fixtures the app uses, inline yes/no buttons via AppIntent.
// Per docs/ux.md §Interactive widget and docs/design-system.md §3.3.

import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Entry

/// One timeline entry — the snapshot of open loops at a moment in time.
struct CrowlyEntry: TimelineEntry {
    let date: Date
    let openLoops: [OpenLoopEntry]
    let totalOpenLoops: Int
    let latestBottomLine: String?
}

/// One open-loop row's worth of state. Sourced from a demo digest's
/// question. Carries enough to render + fire the intent, including the
/// **pre-resolved** route resolutions for "yes" and "no" — the widget
/// must obey the same no-dead-buttons invariant as the app, so the
/// resolver runs in the provider, NOT in the view.
///
/// (P0-1 fix from review pass A: previously the widget rendered raw
/// yes/no buttons with no capability check, bypassing RouteResolver.)
struct OpenLoopEntry: Identifiable, Hashable {
    let id: String
    let digestId: String
    let jobId: String
    let questionId: String
    let text: String
    let replyKind: ReplyKind
    let yesResolution: RouteResolution
    let noResolution:  RouteResolution
    /// Whether the companion's `supported_reply_kinds` includes this loop's
    /// `replyKind` (e.g. yes_no). If false, we must NOT render answer
    /// buttons — only a "Open Crowly to act" hint, per docs/schema.md §3:
    /// "A reply_kind the companion can't handle is hidden with a notice."
    let replyKindSupported: Bool
}

// MARK: - Provider

/// Pulls open loops from `DemoFixtures` and filters out any the user has
/// already answered locally (per `DemoAnswerLog`). In real mode this would
/// hit `GET /summary` on the companion — same shape.
struct CrowlyProvider: TimelineProvider {
    func placeholder(in context: Context) -> CrowlyEntry {
        CrowlyEntry(
            date: .now,
            openLoops: [],
            totalOpenLoops: 0,
            latestBottomLine: "Open loops will appear here"
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (CrowlyEntry) -> Void) {
        completion(snapshot(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CrowlyEntry>) -> Void) {
        // M1 demo: no schedule (the intent forces reloads). Single entry, never refresh.
        let entry = snapshot(at: .now)
        completion(Timeline(entries: [entry], policy: .never))
    }

    private func snapshot(at date: Date) -> CrowlyEntry {
        let log = DemoAnswerLog.shared
        // P0-1: build the resolver once per snapshot, route both answers
        // through it, and pre-stash the resolutions on each entry. The view
        // never resolves intents itself — that's the invariant.
        let capabilities = DemoCapabilities.standard
        let resolver = RouteResolver(capabilities: capabilities)

        var loops: [OpenLoopEntry] = []

        // Sort digests urgency-desc, then time-desc — the same order the
        // inbox uses for surfacing.
        let sorted = DemoFixtures.digests.sorted { lhs, rhs in
            if lhs.urgency != rhs.urgency { return lhs.urgency > rhs.urgency }
            return lhs.createdAt > rhs.createdAt
        }

        for digest in sorted {
            for q in digest.questions {
                if log.isAnswered(digestId: digest.id, questionId: q.id) { continue }
                loops.append(OpenLoopEntry(
                    id: "\(digest.id):q:\(q.id)",
                    digestId: digest.id,
                    jobId: digest.jobId,
                    questionId: q.id,
                    text: q.text,
                    replyKind: q.replyKind,
                    yesResolution: resolver.resolve(forAnswer: "yes", of: q),
                    noResolution:  resolver.resolve(forAnswer: "no",  of: q),
                    replyKindSupported: capabilities.supportedReplyKinds.contains(q.replyKind)
                ))
            }
            // P0-5: action items intentionally OMITTED from the widget for
            // M1. The widget is yes_no-only per the ux.md cut order #3
            // ("`choice`/`free_text` **in the widget** — `yes_no`-only on
            // the widget"). Without yes_no buttons an action would render
            // text-only with no way to decay — surfacing it on the widget
            // is dishonest. Actions live in the app's detail view.
        }

        return CrowlyEntry(
            date: date,
            openLoops: loops,
            totalOpenLoops: loops.count,
            latestBottomLine: DemoFixtures.digests.first?.bottomLine
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

    // MARK: - Medium (the must-build)

    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            // Header: app id + total open count
            HStack(spacing: Space.s) {
                Image(systemName: "tray.full")
                    .widgetAccentable()
                Text("Crowly")
                    .font(.caption.weight(.semibold))
                Spacer()
                if entry.totalOpenLoops > 2 {
                    Text("\(entry.totalOpenLoops) open")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .widgetAccentable()
                }
            }

            // Up to two open loops
            if entry.openLoops.isEmpty {
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Text("All clear.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer(minLength: 0)
            } else {
                VStack(spacing: Space.s) {
                    ForEach(entry.openLoops.prefix(2)) { loop in
                        WidgetLoopRow(loop: loop)
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
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Image(systemName: "tray.full").widgetAccentable()
                Spacer()
                Text("\(entry.totalOpenLoops)")
                    .font(.headline)
                    .widgetAccentable()
            }
            Spacer(minLength: 0)
            if let top = entry.openLoops.first {
                Text(top.text)
                    .font(.subheadline)
                    .lineLimit(2)
                if top.replyKind == .yesNo && top.replyKindSupported {
                    GlassEffectContainer(spacing: 6) {            // [iOS 26]
                        HStack(spacing: 6) {
                            yesButton(for: top, compact: true)
                            noButton(for: top, compact: true)
                        }
                    }
                } else {
                    Text("Open Crowly to act")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(entry.latestBottomLine ?? "All clear.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Space.m)
        .containerBackground(for: .widget) { Color.clear }
    }
}

// MARK: - Row

struct WidgetLoopRow: View {
    let loop: OpenLoopEntry
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme)         private var scheme

    var body: some View {
        // P1-6: nil-coalesce the URL construction. The digestId comes from
        // the schema and is well-formed in M1, but a future ingestion path
        // could let an exotic character through — we'd rather render a
        // dead `crowly://` placeholder (which the app's .onOpenURL just
        // ignores) than crash the widget process.
        let url = URL(string: "crowly://digest/\(loop.digestId)")
            ?? URL(string: "crowly://")!
        return Link(destination: url) {
            HStack(alignment: .top, spacing: Space.s) {
                // Job color stripe — replaced with white in accented mode so
                // the system tinting stays predictable.
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        renderingMode == .accented
                            ? Color.white
                            : JobColor.color(for: loop.jobId, in: scheme)
                    )
                    .frame(width: Space.xs, height: 36)
                    .widgetAccentable()

                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(loop.text)
                        .font(.caption)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(.primary)

                    // P0-1: only render answer buttons when the companion's
                    // capabilities include this reply_kind AND yes/no
                    // resolutions exist. Otherwise show a terminal sublabel
                    // so the row stays honest.
                    if loop.replyKind == .yesNo, loop.replyKindSupported {
                        GlassEffectContainer(spacing: 6) {        // [iOS 26]
                            HStack(spacing: 6) {
                                yesButton(for: loop, compact: true)
                                noButton(for: loop, compact: true)
                            }
                        }
                        // Terminal-fallback honesty: when "yes" resolved
                        // to .terminal (e.g. the route was capability-aware
                        // and unsupported), surface the resolver's sublabel
                        // beneath so the user knows what'll really happen.
                        if loop.yesResolution.intent == .terminal,
                           let sub = loop.yesResolution.sublabel {
                            Text(sub)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text("Open Crowly to answer")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Button helpers
//
// We expose these as free fns so both the row and the small-layout use the
// same intent + styling. `@inline(__always)` keeps the call site cheap.

@inline(__always)
func yesButton(for loop: OpenLoopEntry, compact: Bool) -> some View {
    Button(intent: AnswerQuestionIntent(
        digestId: loop.digestId,
        questionId: loop.questionId,
        value: "yes"
    )) {
        Text("Yes")
            .font(.caption.weight(.semibold))
            .frame(minWidth: 44, minHeight: 28)
    }
    .buttonStyle(.glassProminent)                                 // [iOS 26]
}

@inline(__always)
func noButton(for loop: OpenLoopEntry, compact: Bool) -> some View {
    Button(intent: AnswerQuestionIntent(
        digestId: loop.digestId,
        questionId: loop.questionId,
        value: "no"
    )) {
        Text("No")
            .font(.caption.weight(.semibold))
            .frame(minWidth: 44, minHeight: 28)
    }
    .buttonStyle(.glass)                                          // [iOS 26]
}

// MARK: - Widget configuration

struct CrowlyWidget: Widget {
    let kind = "CrowlyOpenLoops"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CrowlyProvider()) { entry in
            CrowlyWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Crowly")
        .description("Open loops from your agents")
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
    let caps = DemoCapabilities.standard
    let resolver = RouteResolver(capabilities: caps)
    let q1 = Question(
        id: "q1", text: "Track the bylaw?", replyKind: .yesNo,
        onAnswer: [
            "yes": OnAnswerLeg(route: TolerantIntent(intent: Intent.task, raw: "task")),
            "no":  OnAnswerLeg(route: TolerantIntent(intent: Intent.none, raw: "none"))
        ]
    )
    CrowlyEntry(
        date: .now,
        openLoops: [
            OpenLoopEntry(
                id: "1",
                digestId: "dgst_x",
                jobId: "harmony-weekly-public-digest",
                questionId: "q1",
                text: "Should I start tracking the off-site levy bylaw as a recurring watch?",
                replyKind: .yesNo,
                yesResolution: resolver.resolve(forAnswer: "yes", of: q1),
                noResolution:  resolver.resolve(forAnswer: "no",  of: q1),
                replyKindSupported: true
            ),
            OpenLoopEntry(
                id: "2",
                digestId: "dgst_y",
                jobId: "alberta-move-coordination",
                questionId: "q1",
                text: "Should I draft a polite nudge to the seller's lawyer?",
                replyKind: .yesNo,
                yesResolution: resolver.resolve(forAnswer: "yes", of: q1),
                noResolution:  resolver.resolve(forAnswer: "no",  of: q1),
                replyKindSupported: true
            )
        ],
        totalOpenLoops: 5,
        latestBottomLine: nil
    )
}
