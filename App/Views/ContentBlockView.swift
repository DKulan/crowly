// ContentBlockView — renders one schema-v2 `ContentBlock` with bespoke SwiftUI.
//
// The detail view maps a digest's `content` array to a stack of these. Each
// block type gets a purpose-built layout using the shared design tokens
// (`Space`, `Radius`, `Font`, `Color`) so it matches the rest of the reader.
// Inline text (paragraph / callout / list items) runs through CrowlyMarkdown
// for the restricted **bold** / *italic* / `code` / [link](url) subset.
//
// Invariant: degrade-and-warn. Empty/unknown blocks are filtered out upstream
// (`ContentBlock.isRenderable`), and an `.unknown` block that slips through
// renders its `text` if it has one, else nothing — never a crash, never raw
// JSON on screen.

import SwiftUI

struct ContentBlockView: View {
    let block: ContentBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(CrowlyMarkdown.attributed(text))
                .font(.body)
                .foregroundStyle(Color.crowlyInk)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .heading(let text):
            Text(text)
                .font(.crowlySectionTitle)
                .foregroundStyle(Color.crowlyInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                // A little breathing room above a heading that follows prose.
                .padding(.top, Space.xs)

        case .list(let style, let items):
            ListBlock(style: style, items: items)

        case .callout(let variant, let title, let text):
            CalloutBlock(variant: variant, title: title, text: text)

        case .metrics(let items):
            MetricsBlock(items: items)

        case .divider:
            Divider().padding(.vertical, Space.xs)

        case .unknown(_, let raw):
            // Forward-compat: an unrecognized block type from a newer emitter.
            // Surface its `text` as plain prose if present; otherwise render
            // nothing (the raw JSON is preserved in the model for round-trip,
            // but we never show it to the user).
            if let text = raw.objectValue?["text"]?.stringValue, !text.isEmpty {
                Text(CrowlyMarkdown.attributed(text))
                    .font(.body)
                    .foregroundStyle(Color.crowlyInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - List

private struct ListBlock: View {
    let style: BlockListStyle
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(marker(for: index))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(Color.crowlyInkSoft)
                    Text(CrowlyMarkdown.attributed(item))
                        .font(.body)
                        .foregroundStyle(Color.crowlyInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func marker(for index: Int) -> String {
        switch style {
        case .bullet:  "•"
        case .ordered: "\(index + 1)."
        }
    }
}

// MARK: - Callout

private struct CalloutBlock: View {
    let variant: CalloutVariant
    let title: String?
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: variant.symbolName)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.callout(variant))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.crowlyInk)
                }
                Text(CrowlyMarkdown.attributed(text))
                    .font(.callout)
                    .foregroundStyle(Color.crowlyInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Space.l)
        .background(
            RoundedRectangle(cornerRadius: Radius.surface, style: .continuous)
                .fill(Color.callout(variant).opacity(0.10))
        )
        .overlay(alignment: .leading) {
            // A left accent bar echoes the variant tint without tinting the
            // body text (legibility rule).
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.callout(variant))
                .frame(width: 3)
                .padding(.vertical, Space.s)
        }
    }
}

// MARK: - Metrics

private struct MetricsBlock: View {
    let items: [Metric]

    // Two-column grid: label/value stacks flow, wrapping on narrow widths.
    private let columns = [
        GridItem(.flexible(), spacing: Space.m, alignment: .leading),
        GridItem(.flexible(), spacing: Space.m, alignment: .leading),
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Space.m) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, metric in
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(metric.value)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.crowlyInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(metric.label)
                        .font(.caption)
                        .foregroundStyle(Color.crowlyInkSoft)
                        .textCase(.uppercase)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.m)
                .background(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .fill(Color.crowlySurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(Color.crowlyHairline, lineWidth: 0.5)
                )
            }
        }
    }
}
