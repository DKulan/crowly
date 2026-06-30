// DigestCell — the inbox row. Composes JobColorStripe + title + status dot
// (unread cue) + relative timestamp + bottom_line. A reader-only cell: no
// chips, no open-loop counts, no interactivity.

import SwiftUI

struct DigestCell: View {
    let digest: Digest
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

                // Bottom line — the reason the digest exists.
                if !digest.bottomLine.isEmpty {
                    Text(digest.bottomLine)
                        .font(.crowlyCellBody)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.tail)
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

    private var a11yLabel: String {
        var parts = [digest.title]
        if state == .unread { parts.append("Unread") }
        if digest.urgency == .high || digest.urgency == .urgent {
            parts.append("\(digest.urgency.rawValue) priority")
        }
        if !digest.bottomLine.isEmpty {
            parts.append(digest.bottomLine)
        }
        return parts.joined(separator: ". ")
    }
}
