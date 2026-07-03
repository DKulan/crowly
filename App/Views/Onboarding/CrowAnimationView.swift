// CrowAnimationView — the layered crow hero that fronts each onboarding screen.
//
// The crow is a sleek wings-up flight pose (matched to the reference art),
// composed from three transparent PNG layers all registered on the same square
// canvas so they reassemble with no offset:
//   • crow-body  — the complete ink-black crow with a FILLED shoulder (the
//                  "clean" body variant), so no cutout shows when the wing
//                  rotates away; head, eye, beak, tail all intact.
//   • crow-lines — the thin tapered orange/grey speed streaks trailing left.
//   • crow-wing  — the raised swept-back wing fan, with a shoulder root that
//                  overlaps the back so it flaps cleanly around the shoulder.
// Stack order (bottom→top): body → lines → wing.
//
// A single `KeyframeAnimator` drives one `CrowMotion` value whose properties are
// applied to different layers on independent tracks — the whole crow bobs,
// tilts, and breathes together, the wing additionally flaps around the shoulder,
// and the speed lines additionally drift + pulse. This is the WWDC23 (session
// 10157) "separate tracks, each with their own timing" pattern. Per-screen
// personality comes from a `CrowMotionProfile` keyed to `CrowKind`.
//
// Reduce Motion renders the composed crow completely still. If the layer assets
// are missing, it falls back to the single flat `crow` asset, then to an SF
// Symbol. No Lottie, no third-party dependency — all native SwiftUI.

import SwiftUI

/// Which crow beat to show. One per onboarding screen. The layers are shared
/// art; each kind varies the *motion* (see `CrowMotionProfile`), not the image.
enum CrowKind: String, CaseIterable {
    case welcome        // curious crow, head-tilt
    case companion      // crow carrying a little parcel (the self-hosted service)
    case hermes         // crow chattering (the agent hookup)
    case pair           // crow with a key / QR glint (pairing)

    /// Asset name for the flat single-image fallback (all kinds share it).
    var imageName: String { "crow" }

    /// Placeholder SF Symbol if even the flat asset is missing. `bird.fill` is
    /// the crow stand-in.
    var placeholderSymbol: String { "bird.fill" }

    /// The motion personality for this screen.
    ///
    /// Flap amplitudes are deliberately small (≤6°): in this wings-up pose the
    /// raised fan sits over a narrow slice of body, so a large rotation would
    /// swing the wing's own anti-aliased edge out over open silhouette and
    /// flash a hairline seam. Small flaps keep the stroked edge seated on the
    /// body while still reading as a live flutter. hermes stays the liveliest.
    var motion: CrowMotionProfile {
        switch self {
        case .welcome:   CrowMotionProfile(bob: 7, tilt: 1.4, flap: 4, drift: 8,  period: 2.8)
        case .companion: CrowMotionProfile(bob: 6, tilt: 0.8, flap: 3, drift: 6,  period: 3.0)
        case .hermes:    CrowMotionProfile(bob: 8, tilt: 1.0, flap: 6, drift: 12, period: 2.4)
        case .pair:      CrowMotionProfile(bob: 7, tilt: 1.2, flap: 4, drift: 9,  period: 2.7)
        }
    }
}

/// The animated state, driven as one value across independent keyframe tracks.
struct CrowMotion {
    /// Vertical bob of the whole crow (points; negative = up).
    var bodyLift: CGFloat = 0
    /// Subtle nose up/down of the whole crow (degrees).
    var bodyTilt: Double = 0
    /// Wing flap around the shoulder (degrees).
    var wingAngle: Double = 0
    /// Horizontal sway of the speed lines (points; negative = trailing further).
    var lineDrift: CGFloat = 0
    /// Speed-line pulse.
    var lineOpacity: Double = 1
    /// Gentle breathe of the whole crow.
    var scale: CGFloat = 1
}

/// Per-screen amplitudes + loop length. Keeps the keyframe math readable and
/// lets each `CrowKind` feel distinct without duplicating tracks.
struct CrowMotionProfile {
    var bob: CGFloat
    var tilt: Double
    var flap: Double
    var drift: CGFloat
    var period: TimeInterval
}

struct CrowAnimationView: View {
    let kind: CrowKind

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Ink used for the SF Symbol placeholder (last-resort fallback).
    private static let ink = Brand.ink

    /// Rotation anchor for the wing flap — the shoulder, where the wing joins
    /// the back. Unit-space within the fitted square; measured from the
    /// reference-matched wings-up layer art (self-check pivot ≈ 0.625, 0.542).
    private static let wingPivot = UnitPoint(x: 0.625, y: 0.542)

    /// True when all three layer assets are present. When false we fall back to
    /// the flat single crow (older behavior) so the view never breaks.
    private var hasLayers: Bool {
        UIImage(named: "crow-body") != nil
            && UIImage(named: "crow-wing") != nil
            && UIImage(named: "crow-lines") != nil
    }

    var body: some View {
        Group {
            if hasLayers {
                if reduceMotion {
                    // Held still: the composed crow at rest, no per-frame work.
                    composed(CrowMotion())
                } else {
                    let profile = kind.motion
                    KeyframeAnimator(initialValue: CrowMotion(), repeating: true) { motion in
                        composed(motion)
                    } keyframes: { _ in
                        crowKeyframes(profile)
                    }
                }
            } else {
                flatFallback
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .accessibilityHidden(true)   // decorative; each screen carries its copy
    }

    // MARK: - Composed layered crow

    /// The three layers stacked and transformed by the current `motion`. The
    /// whole crow bobs/tilts/breathes together (outer modifiers); the wing and
    /// lines add their own motion on top.
    @ViewBuilder
    private func composed(_ motion: CrowMotion) -> some View {
        ZStack {
            layer("crow-body")

            layer("crow-lines")
                .offset(x: motion.lineDrift)
                .opacity(motion.lineOpacity)

            layer("crow-wing")
                .rotationEffect(.degrees(motion.wingAngle), anchor: Self.wingPivot)
        }
        .scaleEffect(motion.scale)
        .offset(y: motion.bodyLift)
        .rotationEffect(.degrees(motion.bodyTilt))
        .padding(.horizontal, Space.l)
    }

    private func layer(_ name: String) -> some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
    }

    // MARK: - Keyframes
    //
    // Every track sums to `profile.period` so the loop is seamless. Bob and
    // breathe are smooth cubics; the wing holds a glide then fires a spring
    // downstroke-and-recover (an occasional flap, not a constant beat); the
    // lines gently sway + pulse.

    @KeyframesBuilder<CrowMotion>
    private func crowKeyframes(_ p: CrowMotionProfile) -> some Keyframes<CrowMotion> {
        // Gentle bob: down then back up.
        KeyframeTrack(\.bodyLift) {
            CubicKeyframe(-p.bob, duration: p.period * 0.5)
            CubicKeyframe(0,      duration: p.period * 0.5)
        }
        // Subtle tilt: 0 → +t → 0 → -t → 0 for a smooth, drift-free loop.
        KeyframeTrack(\.bodyTilt) {
            CubicKeyframe(p.tilt,  duration: p.period * 0.25)
            CubicKeyframe(0,       duration: p.period * 0.25)
            CubicKeyframe(-p.tilt, duration: p.period * 0.25)
            CubicKeyframe(0,       duration: p.period * 0.25)
        }
        // Wing: glide, then a snappy flap (down, slight up, settle), then glide.
        KeyframeTrack(\.wingAngle) {
            LinearKeyframe(0,             duration: p.period * 0.30)
            SpringKeyframe(p.flap,        duration: p.period * 0.14, spring: .snappy)
            SpringKeyframe(-p.flap * 0.35, duration: p.period * 0.14)
            SpringKeyframe(0,             duration: p.period * 0.14)
            LinearKeyframe(0,             duration: p.period * 0.28)
        }
        // Speed lines: gentle sway out and back.
        KeyframeTrack(\.lineDrift) {
            CubicKeyframe(-p.drift, duration: p.period * 0.5)
            CubicKeyframe(0,        duration: p.period * 0.5)
        }
        // Speed lines: soft pulse.
        KeyframeTrack(\.lineOpacity) {
            CubicKeyframe(0.55, duration: p.period * 0.5)
            CubicKeyframe(1.0,  duration: p.period * 0.5)
        }
        // Whole-crow breathe.
        KeyframeTrack(\.scale) {
            CubicKeyframe(1.02, duration: p.period * 0.5)
            CubicKeyframe(1.0,  duration: p.period * 0.5)
        }
    }

    // MARK: - Fallbacks

    /// If the layer assets are missing, fall back to the single flat crow with a
    /// simple bob (the pre-layering behavior), then to an SF Symbol.
    @ViewBuilder
    private var flatFallback: some View {
        if let ui = UIImage(named: "crow") {
            FlatCrowBob(image: ui, reduceMotion: reduceMotion)
        } else {
            Image(systemName: kind.placeholderSymbol)
                .resizable()
                .scaledToFit()
                .frame(height: 160)
                .foregroundStyle(Self.ink)
                .scaleEffect(x: -1, y: 1)
        }
    }
}

/// The pre-layering flat-crow bob, retained as a fallback for when the layered
/// assets aren't present.
private struct FlatCrowBob: View {
    let image: UIImage
    let reduceMotion: Bool
    @State private var bob = false

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Space.l)
            .rotationEffect(.degrees(bob ? 1.5 : -1.5))
            .offset(y: bob ? -6 : 3)
            .animation(Motion.maybe(Motion.ambient, reduceMotion: reduceMotion), value: bob)
            .onAppear { bob = true }
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
