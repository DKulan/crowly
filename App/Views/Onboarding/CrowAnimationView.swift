// CrowAnimationView — the animated crow that fronts each onboarding screen.
//
// SwiftUI-native animation (no Lottie / no third-party dependency). The motion
// is code-driven so it needs only a STATIC crow image — which is all our art
// tool produces. Two layers, both on a cream "stage" so the near-black crow
// stays legible even in dark mode (the app background is near-black then):
//
//   1. Motion streaks — the app icon's signature orange/grey speed lines,
//      drawn + animated in a `Canvas` (see `streaks`). This is the brand tie
//      and the part that reads as "alive".
//   2. The crow — a bundled transparent PNG named `crow-<kind>` (or a generic
//      `crow`) if present, else an SF Symbol placeholder. It glides + bobs.
//
// To drop in real art: add a transparent crow PNG to the asset catalog named
// `crow-welcome` / `crow-companion` / `crow-hermes` / `crow-pair` (or a single
// `crow` reused by all four). No code change — `crowImage` picks it up.
//
// Palette is sampled from the app icon (App/Assets.xcassets/AppIcon): cream
// #FEF9F2, ink #070C12, streak orange #F88817.

import SwiftUI

/// Which crow beat to show. One per onboarding screen; also names the crow
/// image asset so the art mapping lives in one place.
enum CrowKind: String, CaseIterable {
    case welcome        // curious crow, head-tilt
    case companion      // crow carrying a little parcel (the self-hosted service)
    case hermes         // crow chattering (the agent hookup)
    case pair           // crow with a key / QR glint (pairing)

    /// Asset name for this screen's crow art. `crowImage` falls back to a
    /// generic `crow` asset, then an SF Symbol, if this isn't in the bundle.
    var imageName: String { "crow-\(rawValue)" }

    /// Placeholder SF Symbol until real crow art lands. `bird.fill` is the
    /// crow stand-in.
    var placeholderSymbol: String { "bird.fill" }

    /// A small accent glyph hinting at each screen's subject — keeps the four
    /// screens visually distinct while the crow art itself is shared.
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Brand palette, sampled from the app icon.
    private static let cream = Color(red: 0xFE / 255, green: 0xF9 / 255, blue: 0xF2 / 255)
    private static let ink   = Color(red: 0x07 / 255, green: 0x0C / 255, blue: 0x12 / 255)
    private static let orange = Color(red: 0xF8 / 255, green: 0x88 / 255, blue: 0x17 / 255)

    /// Drives the crow's gentle glide/bob loop.
    @State private var bob = false

    var body: some View {
        ZStack {
            // Cream stage: keeps the ink crow legible on any system theme
            // (Color.crowlyBackground is near-black in dark mode, where a
            // near-black crow would vanish). This also mirrors the icon, which
            // lives on the same cream field.
            RoundedRectangle(cornerRadius: Radius.surface, style: .continuous)
                .fill(Self.cream)

            // Motion streaks (behind the crow) — the icon's signature.
            streaks

            // Subject-hint glyph, low-key, lower-trailing corner.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Image(systemName: kind.accentSymbol)
                        .font(.title3)
                        .foregroundStyle(Self.ink.opacity(0.18))
                        .padding(Space.m)
                }
            }

            crow
                .rotationEffect(.degrees(bob ? 3 : -3))
                .offset(y: bob ? -8 : 4)
                .animation(
                    reduceMotion ? nil
                        : .easeInOut(duration: 1.8).repeatForever(autoreverses: true),
                    value: bob
                )
        }
        .frame(height: 200)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Space.xl)
        .onAppear { bob = true }
        .accessibilityHidden(true)   // decorative; each screen carries its copy
    }

    // MARK: - Crow

    @ViewBuilder
    private var crow: some View {
        if let ui = UIImage(named: kind.imageName) ?? UIImage(named: "crow") {
            // Real art (transparent PNG). Faces its native direction — no flip.
            Image(uiImage: ui)
                .resizable()
                .scaledToFit()
                .frame(height: 128)
        } else {
            // Placeholder until real crow art is dropped into the asset catalog.
            // Flipped so the SF Symbol bird faces into the page like the icon.
            Image(systemName: kind.placeholderSymbol)
                .resizable()
                .scaledToFit()
                .frame(height: 96)
                .foregroundStyle(Self.ink)
                .scaleEffect(x: -1, y: 1)
        }
    }

    // MARK: - Streaks

    /// Animated speed lines. A `TimelineView(.animation)` feeds a continuous
    /// clock into a `Canvas`; each streak sweeps leftward, fading in and out,
    /// so the crow reads as flying fast — the icon's motion device brought to
    /// life. Honors Reduce Motion by rendering a single static frame.
    @ViewBuilder
    private var streaks: some View {
        if reduceMotion {
            Canvas { ctx, size in Self.drawStreaks(ctx, size, t: 0) }
        } else {
            TimelineView(.animation) { tl in
                Canvas { ctx, size in
                    Self.drawStreaks(ctx, size, t: tl.date.timeIntervalSinceReferenceDate)
                }
            }
        }
    }

    /// One streak's fixed parameters. `y`/`length` are fractions of the canvas.
    private struct Streak {
        let y: CGFloat          // vertical position, 0…1
        let length: CGFloat     // fraction of width
        let width: CGFloat      // line thickness
        let period: Double      // seconds for one sweep
        let offset: Double      // phase offset, 0…1 (staggers the streaks)
        let orange: Bool        // orange accent vs. grey
        let maxAlpha: Double
    }

    private static let streakSpecs: [Streak] = [
        Streak(y: 0.30, length: 0.20, width: 3, period: 2.2, offset: 0.0,  orange: false, maxAlpha: 0.35),
        Streak(y: 0.40, length: 0.28, width: 4, period: 2.8, offset: 0.35, orange: true,  maxAlpha: 0.85),
        Streak(y: 0.52, length: 0.16, width: 3, period: 1.9, offset: 0.6,  orange: false, maxAlpha: 0.30),
        Streak(y: 0.60, length: 0.30, width: 4, period: 3.1, offset: 0.15, orange: true,  maxAlpha: 0.80),
        Streak(y: 0.70, length: 0.22, width: 3, period: 2.5, offset: 0.5,  orange: false, maxAlpha: 0.32),
        Streak(y: 0.80, length: 0.18, width: 3, period: 2.1, offset: 0.8,  orange: true,  maxAlpha: 0.55),
    ]

    /// Draw the streaks for time `t`. Static so the `Canvas` closures don't
    /// capture `self`. Streaks travel across the left ~60% of the stage —
    /// behind and trailing the (roughly centered) crow, matching the icon.
    private static func drawStreaks(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        let travel = size.width * 0.62
        let startX = size.width * 0.52
        for s in streakSpecs {
            let phase = ((t / s.period) + s.offset).truncatingRemainder(dividingBy: 1)
            let x = startX - phase * travel
            let y = size.height * s.y
            let len = s.length * size.width
            // Fade in over the first 15%, out over the last 30%.
            let fadeIn = min(1, phase / 0.15)
            let fadeOut = 1 - max(0, (phase - 0.70) / 0.30)
            let alpha = fadeIn * fadeOut * s.maxAlpha
            guard alpha > 0.01 else { continue }
            var path = Path()
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x - len, y: y))
            let color = (s.orange ? orange : Color.gray).opacity(alpha)
            ctx.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: s.width, lineCap: .round))
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
