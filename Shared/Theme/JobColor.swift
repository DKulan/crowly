// JobColor — deterministic per-job color derivation.
//
// Per the invariant in docs/ux.md and the algorithm in docs/design-system.md
// §1.1.2: same `job_id` always yields the same color, no per-job config in
// M1.  FNV-1a 64-bit on the UTF-8 bytes → hue 0..1; saturation/lightness
// fixed per appearance (lighter+more-saturated in dark mode for legibility
// on near-black backgrounds).
//
// **Why not `String.hashValue`:** Swift's native hash is randomized per
// process — same job_id would change color every relaunch. Unusable.

import SwiftUI

public enum JobColor {

    /// Deterministic per-job color. Same `job_id` → same color on any device,
    /// for the lifetime of the schema. Stable across app launches.
    public static func color(for jobId: String, in scheme: ColorScheme) -> Color {
        let hue = self.hue(for: jobId)
        let (s, l): (Double, Double) = scheme == .dark ? (0.65, 0.65) : (0.55, 0.45)
        let (hsbS, hsbB) = hslToHsb(s: s, l: l)
        return Color(hue: hue, saturation: hsbS, brightness: hsbB)
    }

    /// Exposed so tests can verify hue determinism without relying on Color
    /// equality (Color isn't reliably equatable across instances).
    public static func hue(for jobId: String) -> Double {
        let h = fnv1a64(jobId)
        return Double(h % 360) / 360.0
    }

    /// FNV-1a 64-bit. Deterministic — does NOT use Swift's randomized
    /// `String.hashValue`. Algorithm per docs/design-system.md §1.1.2.
    static func fnv1a64(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    /// HSL (CSS-style) → HSB (SwiftUI-style). Same hue, different S/B.
    /// Algorithm per docs/design-system.md §1.1.2.
    static func hslToHsb(s sl: Double, l: Double) -> (Double, Double) {
        let b = l + sl * min(l, 1 - l)
        let sb = b == 0 ? 0 : 2 * (1 - l / b)
        return (sb, b)
    }
}
