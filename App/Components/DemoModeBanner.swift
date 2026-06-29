// DemoModeBanner — pinned safe-area banner shown when the app is using
// canned data.  Per docs/ux.md → Onboarding and docs/design-system.md §1.4.

import SwiftUI

struct DemoModeBanner: View {
    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "sparkles")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Demo Mode")
                    .font(.subheadline.weight(.semibold))
                Text("Showing canned digests. Connect a Crowly inbox to see real ones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(
            Capsule().fill(.orange.opacity(0.12))
        )
        .overlay(
            Capsule().strokeBorder(.orange.opacity(0.25), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Demo mode. Showing canned digests.")
    }
}

#Preview {
    DemoModeBanner().padding()
}
