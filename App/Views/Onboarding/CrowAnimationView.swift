// CrowAnimationView — the crow hero that fronts each onboarding screen.
//
// The bundled `crow` asset (Crow.imageset) is the right-facing ink-black crow
// with the signature orange/grey speed lines already baked in — extracted from
// the app icon and matching the owner's onboarding art exactly. It floats on
// the page's cream field (no stage), scaled to a hero size, with a gentle bob
// for life. Reduce Motion holds it still. No Lottie, no third-party dependency,
// no separate animated streak layer (the PNG carries its own).
//
// `CrowKind` remains for API stability but every case now resolves to the same
// shared `crow` asset.

import SwiftUI

/// Which crow beat to show. One per onboarding screen. The asset is now a
/// single shared `crow` image (the right-facing crow with orange speed lines),
/// so all four cases use the same art — the enum remains for API stability.
enum CrowKind: String, CaseIterable {
    case welcome        // curious crow, head-tilt
    case companion      // crow carrying a little parcel (the self-hosted service)
    case hermes         // crow chattering (the agent hookup)
    case pair           // crow with a key / QR glint (pairing)

    /// Asset name: all four now share the single `crow` asset.
    var imageName: String { "crow" }

    /// Placeholder SF Symbol until real crow art lands. `bird.fill` is the
    /// crow stand-in.
    var placeholderSymbol: String { "bird.fill" }
}

struct CrowAnimationView: View {
    let kind: CrowKind

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Ink used for the SF Symbol placeholder (until the crow asset resolves).
    private static let ink = Brand.ink

    /// Drives the crow's gentle glide/bob loop.
    @State private var bob = false

    var body: some View {
        // The bundled `crow` asset already carries the exact orange/grey speed
        // lines from the onboarding art (extracted from the app icon), so it IS
        // the hero composition — no separate streak layer needed. A gentle bob
        // gives it life; Reduce Motion holds it still.
        crow
            .rotationEffect(.degrees(bob ? 1.5 : -1.5))
            .offset(y: bob ? -6 : 3)
            .animation(
                reduceMotion ? nil
                    : .easeInOut(duration: 2.2).repeatForever(autoreverses: true),
                value: bob
            )
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .onAppear { bob = true }
            .accessibilityHidden(true)   // decorative; each screen carries its copy
    }

    // MARK: - Crow

    @ViewBuilder
    private var crow: some View {
        if let ui = UIImage(named: "crow") {
            // The bundled crow asset: right-facing ink-black crow with orange
            // speed lines, on a transparent background. Sized to the hero scale
            // from the screenshot — fills most of the width.
            Image(uiImage: ui)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Space.l)
        } else {
            // Placeholder until real crow art is dropped into the asset catalog.
            // Flipped so the SF Symbol bird faces into the page like the icon.
            Image(systemName: kind.placeholderSymbol)
                .resizable()
                .scaledToFit()
                .frame(height: 160)
                .foregroundStyle(Self.ink)
                .scaleEffect(x: -1, y: 1)
        }
    }

}

#Preview("Crow kinds") {
    VStack(spacing: 24) {
        ForEach(CrowKind.allCases, id: \.self) { kind in
            CrowAnimationView(kind: kind)
        }
    }
    .padding()
    .background(Color.crowlyBackground)
}
