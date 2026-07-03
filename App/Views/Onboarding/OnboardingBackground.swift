// OnboardingBackground — the warm, gently-breathing field behind the carousel.
//
// Replaces the flat `Brand.cream` fill with a subtle animated `MeshGradient`
// (iOS 18+, native — no dependency) built entirely from the brand palette:
// cream / creamDeep / paper, with a single whisper of warmth (orange blended
// into cream) drifting in one corner. The interior mesh points breathe on a
// long, slow loop via `TimelineView(.animation)`, so the field feels alive
// without ever reading as a "light show" — this is warmth, not motion for its
// own sake.
//
// Reduce Motion holds the mesh still (a static gradient), and the whole thing
// stays within the fixed warm identity — it never flips or brightens.

import SwiftUI

struct OnboardingBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A soft peachy cream — orange blended ~12% into the cream field. The one
    /// hint of the signature accent in the backdrop; kept barely-there so text
    /// legibility on the field is untouched.
    private static let warmGlow = Color(red: 0xFD / 255, green: 0xEA / 255, blue: 0xD8 / 255)

    var body: some View {
        Group {
            if reduceMotion {
                // Held still: the mesh at its rest pose, no per-frame updates.
                mesh(phase: 0)
            } else {
                // A long, slow breathing loop. TimelineView(.animation) ticks
                // per frame; the mesh math is GPU-cheap so this stays smooth.
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    mesh(phase: t)
                }
            }
        }
        .ignoresSafeArea()
    }

    /// A 3×3 mesh. Corners are pinned; the mid-edge and center points drift on
    /// gentle, out-of-phase sinusoids so the warmth slowly migrates across the
    /// field. `phase` is seconds (0 when held still).
    private func mesh(phase t: TimeInterval) -> some View {
        // Small drift amplitude — a few percent of the field. Barely perceptible
        // frame-to-frame; the movement only registers over seconds.
        let a: Float = 0.04
        let drift = { (speed: Double, offset: Double) -> Float in
            Float(sin(t * speed + offset)) * a
        }

        let points: [SIMD2<Float>] = [
            // Row 0 (top): corners pinned, top-mid drifts horizontally
            SIMD2(0, 0),               SIMD2(0.5 + drift(0.13, 0), 0), SIMD2(1, 0),
            // Row 1 (middle): edges drift vertically, center breathes both ways
            SIMD2(0, 0.5 + drift(0.11, 1.7)),
            SIMD2(0.5 + drift(0.09, 3.1), 0.5 + drift(0.10, 0.5)),
            SIMD2(1, 0.5 + drift(0.12, 4.2)),
            // Row 2 (bottom): corners pinned, bottom-mid drifts horizontally
            SIMD2(0, 1),               SIMD2(0.5 + drift(0.14, 2.4), 1), SIMD2(1, 1),
        ]

        // Colors: cream field, deeper cream toward the bottom for grounding,
        // paper highlights, and the single warm glow in the top-right corner.
        let colors: [Color] = [
            Brand.cream,      Brand.paper,     Self.warmGlow,
            Brand.cream,      Brand.paper,     Brand.cream,
            Brand.creamDeep,  Brand.cream,     Brand.creamDeep,
        ]

        return MeshGradient(width: 3, height: 3, points: points, colors: colors)
    }
}

#Preview {
    OnboardingBackground()
}
