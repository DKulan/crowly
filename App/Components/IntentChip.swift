// IntentChip — capsule pill that says "this cell has N open items of intent X".
//
// Per docs/design-system.md §2.2.  Vanishes at zero (the "did the work" decay).
// The chip's label can also act as a question counter (caller-supplied label
// for the "1 question" / "2 questions" row, which isn't an Intent).

import SwiftUI

struct IntentChip: View {
    enum Style { case cell, detail }

    /// The intent or question-counter mode.
    let mode: Mode
    let openCount: Int
    var style: Style = .cell

    enum Mode {
        case intent(Intent)
        case question        // questions aren't an Intent — use this case
    }

    var body: some View {
        // P1-5: skip chips whose noun is empty (Intent.none). The cell
        // shouldn't render an empty pill — and the a11y label would speak
        // "1 open " with a trailing space.
        if openCount == 0 || !isRenderable {
            EmptyView()
        } else {
            Label {
                Text(label).font(.crowlyChipSmall)
            } icon: {
                Image(systemName: symbol).font(.crowlyChipSmall)
            }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs)
            .background(
                Capsule().fill(Color.secondary.opacity(0.10))
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(a11yLabel)
        }
    }

    /// Whether this chip should render. Defensive — DigestCell already
    /// filters by `chipRenderable`, but IntentChip is also reused in
    /// previews and the detail view.
    private var isRenderable: Bool {
        switch mode {
        case .intent(let i): return i.chipRenderable
        case .question:      return true
        }
    }

    private var symbol: String {
        switch mode {
        case .intent(let i): return i.symbol
        case .question:      return "questionmark.circle"
        }
    }

    private var label: String {
        switch (mode, style) {
        case (.intent(let i), .cell):   return "\(openCount) \(i.noun(pluralFor: openCount))"
        case (.intent(let i), .detail): return i.verb
        case (.question, _):
            return openCount == 1 ? "\(openCount) question" : "\(openCount) questions"
        }
    }

    private var a11yLabel: String {
        switch mode {
        case .intent(let i): return "\(openCount) open \(i.noun(pluralFor: openCount))"
        case .question:      return label    // "1 question" / "2 questions"
        }
    }
}

#Preview {
    HStack {
        IntentChip(mode: .question, openCount: 1)
        IntentChip(mode: .intent(.task), openCount: 2)
        IntentChip(mode: .intent(.note), openCount: 1)
        IntentChip(mode: .intent(.followup), openCount: 0)  // hidden
    }
    .padding()
}
