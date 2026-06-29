// RouteButton — the route-aware verb button for action items.
// Capability-aware via the `resolution`: **never renders when disabled**
// (the caller drops it, per the no-dead-buttons invariant). Per
// docs/design-system.md §2.3.

import SwiftUI

struct RouteButton: View {
    enum Prominence { case primary, secondary }

    let resolution: RouteResolution
    let action: () -> Void
    var prominence: Prominence = .secondary

    var body: some View {
        Button(action: action) {
            Label {
                Text(resolution.verb).font(.body.weight(.medium))
            } icon: {
                Image(systemName: resolution.symbol)
            }
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.glass)                    // [iOS 26]
        .controlSize(.large)
        .accessibilityHint(resolution.sublabel ?? "")
    }
}
