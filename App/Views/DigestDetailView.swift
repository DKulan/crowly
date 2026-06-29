// DigestDetailView — the bound-answer screen. Per docs/ux.md §Digest detail
// screen and docs/design-system.md §3.2.
//
// Order: Header → Bottom-line callout → Questions → Action items → Body
// sections → Sources → Bottom bar. Open loops sit ABOVE the body — they're
// the reason the digest was opened.

import SwiftUI

struct DigestDetailView: View {
    let digest: Digest
    @Environment(DigestStore.self) private var store
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {

                // Bottom line callout (opaque, tinted — not glass)
                if !digest.bottomLine.isEmpty {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Bottom line")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(digest.bottomLine)
                            .font(.crowlyDetailCallout)
                            .foregroundStyle(.primary)
                    }
                    .padding(Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.surface, style: .continuous)
                            .fill(Color.accentColor.opacity(0.08))
                    )
                }

                // Questions
                if !digest.questions.isEmpty {
                    SectionHeader(
                        title: "Questions",
                        badge: openQuestionsBadge
                    )
                    VStack(spacing: Space.l) {
                        ForEach(digest.questions) { q in
                            QuestionRow(question: q, digestId: digest.id)
                                .animation(
                                    reduceMotion ? nil : .snappy(duration: 0.25),
                                    value: store.answerState(digestId: digest.id, questionId: q.id)
                                )
                        }
                    }
                }

                // Action items
                if !digest.actionItems.isEmpty {
                    SectionHeader(
                        title: "Action items",
                        badge: openActionsBadge
                    )
                    VStack(spacing: Space.l) {
                        ForEach(digest.actionItems) { a in
                            ActionItemRow(action: a, digestId: digest.id)
                                .animation(
                                    reduceMotion ? nil : .snappy(duration: 0.25),
                                    value: store.actionState(digestId: digest.id, actionId: a.id)
                                )
                        }
                    }
                }

                // Body sections
                if !digest.sections.isEmpty {
                    VStack(alignment: .leading, spacing: Space.l) {
                        ForEach(digest.sections) { s in
                            VStack(alignment: .leading, spacing: Space.s) {
                                Text(s.heading).font(.crowlyCellTitle)
                                Text(s.body).font(.body)
                            }
                        }
                    }
                }

                // Sources
                if !digest.sources.isEmpty {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Sources")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        ForEach(digest.sources) { src in
                            Button {
                                openURL(src.url)
                            } label: {
                                Label(src.title, systemImage: "arrow.up.right.square")
                                    .font(.callout)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.l)
            // Bug #5 (review pass B): reserve space at the bottom of the
            // scroll content so the glass `.bottomBar` capsules don't
            // overlap the last row (sources / action items). The bar
            // height + its own padding is ~80pt; round up a touch.
            .padding(.bottom, 88)
        }
        .background(Color.crowlyBackground)
        .navigationTitle(digest.title)
        .navigationBarTitleDisplayMode(.large)
        // P1-3: the subtitle already exists on Digest — wire it in. Reads
        // "Sun, Jun 29 at 7:00 PM · low urgency" per design-system.md §3.2.
        .navigationSubtitle(digest.subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    store.markHandled(digest)
                } label: {
                    Label("Mark handled", systemImage: "checkmark.circle")
                }
                Spacer()
                Button {
                    store.archive(digest)
                } label: {
                    Label("Archive", systemImage: "tray.and.arrow.down")
                }
                // P1-9: ⋯ menu — Mute job lives here so it matches the
                // inbox swipe action's surface area without crowding the
                // primary buttons. Per docs/ux.md §Digest detail screen.
                Menu {
                    Button("Mute job", systemImage: "bell.slash") {
                        store.muteJob(digest.jobId)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: - Subtitle / badges

    private var openQuestionsBadge: String? {
        let n = store.openQuestionCount(for: digest)
        guard n > 0 else { return nil }
        return n == 1 ? "1 open" : "\(n) open"
    }

    private var openActionsBadge: String? {
        let n = digest.actionItems
            .filter { store.actionState(digestId: digest.id, actionId: $0.id) == .unresolved }
            .count
        guard n > 0 else { return nil }
        return "\(n)"
    }
}

// MARK: - SectionHeader

struct SectionHeader: View {
    let title: String
    var badge: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.weight(.semibold))
            if let badge {
                Text(badge)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - QuestionRow

struct QuestionRow: View {
    let question: Question
    let digestId: String
    @Environment(DigestStore.self) private var store

    private var answer: AnswerState {
        store.answerState(digestId: digestId, questionId: question.id)
    }
    private var yesResolution: RouteResolution { store.resolution(forAnswer: "yes", of: question) }
    private var noResolution: RouteResolution { store.resolution(forAnswer: "no", of: question) }

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            OpenLoopGlyph(kind: .question, isResolved: answer.isResolved)

            VStack(alignment: .leading, spacing: Space.s) {
                Text(question.text).font(.crowlyDetailQ)

                switch question.replyKind {
                case .yesNo:
                    if !answer.isResolved {
                        GlassEffectContainer(spacing: Space.s) {     // [iOS 26]
                            HStack(spacing: Space.s) {
                                Button {
                                    store.answer(question, in: digestId, value: "yes")
                                } label: {
                                    Text("Yes")
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .buttonStyle(.glassProminent)         // [iOS 26]

                                Button {
                                    store.answer(question, in: digestId, value: "no")
                                } label: {
                                    Text("No")
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .buttonStyle(.glass)                  // [iOS 26]
                            }
                        }
                        ResolutionPreview(mode: .willResolve, resolution: yesResolution)
                            .padding(.top, Space.xs)
                    } else if let r = answer.resolution {
                        ResolutionPreview(
                            mode: answer.failed ? .failed : .didResolve,
                            resolution: r
                        )
                    }

                case .choice:
                    VStack(spacing: Space.s) {
                        ForEach(question.options ?? [], id: \.self) { opt in
                            let res = store.resolution(forAnswer: opt, of: question)
                            Button {
                                store.answer(question, in: digestId, value: opt)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(opt).font(.body.weight(.medium))
                                    Text(res.sublabel ?? "Will \(res.verb.lowercased())")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, Space.s)
                                .padding(.horizontal, Space.m)
                            }
                            .buttonStyle(.glass)                       // [iOS 26]
                        }
                    }

                case .freeText:
                    // P1-1 fix: don't render a no-op `Reply…` button — that's
                    // a dead affordance (the action is empty in M1) which
                    // violates the no-dead-buttons invariant. Show an honest
                    // "coming soon" caption instead. When the sheet flow
                    // lands in M2, swap this back to a real button.
                    Text("Reply in the app (coming soon)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - ActionItemRow

struct ActionItemRow: View {
    let action: ActionItem
    let digestId: String
    @Environment(DigestStore.self) private var store

    private var state: ActionState {
        store.actionState(digestId: digestId, actionId: action.id)
    }
    private var resolution: RouteResolution { store.resolution(for: action) }

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            OpenLoopGlyph(kind: .action, isResolved: state.isResolved)

            VStack(alignment: .leading, spacing: Space.s) {
                Text(action.text).font(.body)

                let chips = action.hintsChips
                if !chips.isEmpty {
                    HStack(spacing: Space.s) {
                        ForEach(chips, id: \.self) { hint in
                            Text(hint)
                                .font(.crowlyChip)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, Space.s)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.10)))
                        }
                    }
                }

                if !state.isResolved {
                    HStack(spacing: Space.s) {
                        RouteButton(resolution: resolution) {
                            store.executeAction(action, in: digestId)
                        }
                        if resolution.hasOverrides {
                            Menu {
                                Button("Edit project…", systemImage: "folder") { }
                                Button("Edit due…",     systemImage: "calendar") { }
                                Button("Edit labels…",  systemImage: "tag") { }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.glass)                        // [iOS 26]
                        }
                    }
                } else if let r = state.resolution {
                    ResolutionPreview(mode: .didResolve, resolution: r)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        DigestDetailView(digest: DemoFixtures.harmonyDigest)
            .environment(DigestStore())
    }
}
