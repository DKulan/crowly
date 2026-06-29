// OpenLoopGlyph — leading glyph on each open-loop row in detail and widget.
//
// Per the invariant in docs/ux.md and docs/design-system.md §2.5:
// **shape stays put — only fill changes** so resolution decay is visible
// without redrawing the layout.

import SwiftUI

struct OpenLoopGlyph: View {
    enum Kind { case question, action }

    let kind: Kind
    let isResolved: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.title3)                        // scales with Dynamic Type
            .foregroundStyle(isResolved ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
            .symbolRenderingMode(.hierarchical)
            .accessibilityHidden(true)            // row label carries semantics
    }

    private var symbol: String {
        switch (kind, isResolved) {
        case (.question, false): "questionmark.circle"
        case (.question, true):  "questionmark.circle.fill"
        case (.action,   false): "circle"
        case (.action,   true):  "checkmark.circle.fill"
        }
    }
}

#Preview {
    HStack(spacing: 24) {
        OpenLoopGlyph(kind: .question, isResolved: false)
        OpenLoopGlyph(kind: .question, isResolved: true)
        OpenLoopGlyph(kind: .action, isResolved: false)
        OpenLoopGlyph(kind: .action, isResolved: true)
    }
    .padding()
}
