// DigestCell — the inbox row. Composes JobColorStripe + title + status dot +
// bottom_line + intent chips. Per docs/design-system.md §2.7.
//
// Must-build #1 of the triad.

import SwiftUI

struct DigestCell: View {
    let digest: Digest
    let questionOpenCount: Int                 // questions aren't an Intent
    let openLoopCounts: [Intent: Int]
    let state: StatusDot.State

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            JobColorStripe(jobId: digest.jobId)

            VStack(alignment: .leading, spacing: Space.s) {
                // Title row
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(digest.title)
                        .font(.crowlyCellTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    StatusDot(state: state, urgency: digest.urgency)
                }

                // Meta row (urgency badge + relative timestamp)
                HStack(spacing: Space.xs) {
                    if digest.urgency == .high || digest.urgency == .urgent {
                        Image(systemName: digest.urgency == .urgent
                              ? "exclamationmark.2" : "exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(Color.urgency(digest.urgency))
                            .accessibilityHidden(true)
                    }
                    Text(digest.createdAt, format: .relative(presentation: .named))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                // Bottom line
                if !digest.bottomLine.isEmpty {
                    Text(digest.bottomLine)
                        .font(.crowlyCellBody)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }

                // Intent chips strip — questions first, then task/followup/note.
                // P1-5: skip non-renderable intents (Intent.none has no noun
                // and shouldn't pollute the chip row or a11y label).
                if hasAnyOpenChips {
                    HStack(spacing: Space.s) {
                        if questionOpenCount > 0 {
                            IntentChip(mode: .question, openCount: questionOpenCount)
                        }
                        ForEach(Intent.cellOrdering, id: \.self) { intent in
                            if intent.chipRenderable,
                               let count = openLoopCounts[intent], count > 0 {
                                IntentChip(mode: .intent(intent), openCount: count)
                            }
                        }
                    }
                    .padding(.top, Space.xs)
                }
            }
            .padding(.vertical, Space.s)
        }
        .padding(.horizontal, Space.m)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.crowlySurface)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
    }

    private var hasAnyOpenChips: Bool {
        if questionOpenCount > 0 { return true }
        // P1-5: only count chips that will actually render.
        return openLoopCounts.contains { intent, count in
            count > 0 && intent.chipRenderable
        }
    }

    private var a11yLabel: String {
        var parts = [digest.title]
        switch state {
        case .unread:   parts.append("Unread")
        case .readOpen: parts.append("Read")
        case .handled:  parts.append("Handled")
        case .archived: break
        }
        if digest.urgency == .high || digest.urgency == .urgent {
            parts.append("\(digest.urgency.rawValue) priority")
        }
        if !digest.bottomLine.isEmpty {
            parts.append(digest.bottomLine)
        }
        if questionOpenCount > 0 {
            parts.append(questionOpenCount == 1 ? "1 open question" : "\(questionOpenCount) open questions")
        }
        for intent in Intent.cellOrdering {
            if intent.chipRenderable,
               let count = openLoopCounts[intent], count > 0 {
                parts.append("\(count) open \(intent.noun(pluralFor: count))")
            }
        }
        return parts.joined(separator: ". ")
    }
}
