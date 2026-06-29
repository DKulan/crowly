// ResolutionPreview — "Will create a Todoist task" / "Answered: yes — task
// created" / "Tap to retry".  The trust affordance that makes the bound loop
// real.  Per docs/design-system.md §2.4.

import SwiftUI

struct ResolutionPreview: View {
    enum Mode { case willResolve, didResolve, failed }

    let mode: Mode
    let resolution: RouteResolution

    var body: some View {
        Label {
            Text(text).font(.footnote)
        } icon: {
            Image(systemName: symbol).font(.footnote)
        }
        .foregroundStyle(color)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityLabel(text)
    }

    private var symbol: String {
        switch mode {
        case .willResolve: resolution.symbol
        case .didResolve:  "checkmark.circle.fill"
        case .failed:      "arrow.clockwise"
        }
    }

    private var color: Color {
        switch mode {
        case .willResolve: .secondary
        case .didResolve:  .green
        case .failed:      .orange
        }
    }

    private var text: String {
        switch mode {
        case .willResolve:
            // Use the resolver's sublabel if available — it carries the
            // honest "Will keep in inbox (task unavailable)" when degraded.
            return resolution.sublabel ?? "Will \(resolution.verb.lowercased())"
        case .didResolve:
            return "Answered — \(resolution.confirmation)"
        case .failed:
            return "Tap to retry"
        }
    }
}
