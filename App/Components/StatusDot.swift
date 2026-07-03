// StatusDot — the read indicator on every inbox cell.
//
// Three states: unread (filled accent / urgency-tinted) → read (hidden) →
// archived (hidden from the main list entirely). Layered with urgency tint
// when the state is `unread` and urgency ≥ .high.

import SwiftUI

struct StatusDot: View {
    enum State { case unread, read, archived }

    let state: State
    var urgency: Urgency = .normal

    var body: some View {
        Group {
            switch state {
            case .unread:
                Circle().fill(unreadColor)
            case .read, .archived:
                EmptyView()
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityLabel(a11yLabel)
    }

    private var unreadColor: Color {
        urgency == .high || urgency == .urgent
            ? Color.urgency(urgency)
            : Color.crowlyAccent
    }

    private var a11yLabel: String {
        switch state {
        case .unread:
            switch urgency {
            case .urgent: return "Unread, urgent"
            case .high:   return "Unread, high priority"
            default:      return "Unread"
            }
        case .read, .archived: return ""
        }
    }
}

#Preview {
    HStack(spacing: 16) {
        StatusDot(state: .unread)
        StatusDot(state: .unread, urgency: .urgent)
        StatusDot(state: .read)
    }
    .padding()
}
