// CrowAnimationView — the animated crow that fronts each onboarding screen.
//
// STATUS: SwiftUI **placeholder** motion (SF Symbol + PhaseAnimator). The
// design calls for Lottie crow animations (one per screen); the real `.lottie`
// / `.json` assets aren't sourced yet. This view is the swap point:
//
//   To adopt Lottie later, add `lottie-ios` to the app target in project.yml,
//   drop the crow `.lottie` files into the bundle, and replace the `body` of
//   this view with `LottieView(animation: .named(kind.lottieName)).looping()`.
//   Nothing else in the onboarding flow references Lottie — callers only ever
//   see `CrowAnimationView(kind:)`, so the swap is local to this file.
//
// The placeholder is intentionally characterful (a crow that bobs + tilts per
// screen) so the flow reads as finished-enough to demo, and so layout/timing
// are already tuned when the real art drops in.

import SwiftUI

/// Which crow beat to show. One per onboarding screen; also names the eventual
/// Lottie asset so the mapping is declared in one place.
enum CrowKind: String, CaseIterable {
    case welcome        // curious crow, head-tilt
    case companion      // crow carrying a little parcel (the self-hosted service)
    case hermes         // crow chattering (the agent hookup)
    case pair           // crow with a key / QR glint (pairing)

    /// The Lottie asset name this screen will use once real art is sourced.
    /// Referenced by the future `LottieView(animation: .named(...))` swap.
    var lottieName: String { "crow-\(rawValue)" }

    /// Placeholder SF Symbol until Lottie art lands. `bird.fill` is the crow
    /// stand-in; the accent glyph hints at each screen's subject.
    var placeholderSymbol: String { "bird.fill" }

    /// A small secondary glyph layered behind the crow to differentiate the
    /// screens while we're on placeholder art.
    var accentSymbol: String {
        switch self {
        case .welcome:   "sparkles"
        case .companion: "shippingbox.fill"
        case .hermes:    "bubble.left.and.bubble.right.fill"
        case .pair:      "qrcode"
        }
    }
}

struct CrowAnimationView: View {
    let kind: CrowKind

    /// Drives the placeholder bob/tilt loop. When Lottie lands this state (and
    /// the PhaseAnimator) goes away — the Lottie view owns its own timeline.
    @State private var animating = false

    var body: some View {
        ZStack {
            // Soft accent halo — the screen's subject glyph, low-contrast.
            Image(systemName: kind.accentSymbol)
                .font(.system(size: 96))
                .foregroundStyle(Color.accentColor.opacity(0.12))
                .offset(y: -8)

            // The crow. PhaseAnimator gives it a gentle, looping bob + tilt so
            // the placeholder doesn't read as a static icon.
            PhaseAnimator([0, 1, 2], trigger: animating) { phase in
                Image(systemName: kind.placeholderSymbol)
                    .font(.system(size: 108))
                    .foregroundStyle(.tint)
                    .rotationEffect(.degrees(tilt(for: phase)))
                    .offset(y: bob(for: phase))
                    .scaleEffect(x: -1, y: 1)   // face the page content, not away
            } animation: { _ in
                .easeInOut(duration: 1.1)
            }
            .accessibilityHidden(true)          // decorative; screens carry the copy
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
        .onAppear { animating = true }
    }

    /// Head-tilt per phase, in degrees. A small ±6° sway.
    private func tilt(for phase: Int) -> Double {
        switch phase {
        case 0: -6
        case 1:  0
        default: 6
        }
    }

    /// Vertical bob per phase, in points.
    private func bob(for phase: Int) -> CGFloat {
        switch phase {
        case 0:  0
        case 1: -10
        default: 0
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
