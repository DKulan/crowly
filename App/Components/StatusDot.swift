// StatusDot — the four-state read indicator on every inbox cell.
//
// Per docs/design-system.md §2.1 + §1.1.3.  Single source of truth for cell
// read/handled/archived state — **never a badge stack.**  Layered with
// urgency tint when the state is `unread` and urgency ≥ .high.

import SwiftUI

struct StatusDot: View {
    enum State { case unread, readOpen, handled, archived }

    let state: State
    var urgency: Urgency = .normal

    var body: some View {
        Group {
            switch state {
            case .unread:
                Circle().fill(unreadColor)
            case .readOpen:
                Circle().strokeBorder(Color.accentColor, lineWidth: 1.5)
            case .handled:
                Circle().fill(Color.secondary)
            case .archived:
                EmptyView()
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityLabel(a11yLabel)
    }

    private var unreadColor: Color {
        urgency == .high || urgency == .urgent
            ? Color.urgency(urgency)
            : .accentColor
    }

    private var a11yLabel: String {
        switch state {
        case .unread:
            switch urgency {
            case .urgent: return "Unread, urgent"
            case .high:   return "Unread, high priority"
            default:      return "Unread"
            }
        case .readOpen: return "Read, has open items"
        case .handled:  return "Handled"
        case .archived: return ""
        }
    }
}

#Preview {
    HStack(spacing: 16) {
        StatusDot(state: .unread)
        StatusDot(state: .unread, urgency: .urgent)
        StatusDot(state: .readOpen)
        StatusDot(state: .handled)
    }
    .padding()
}
