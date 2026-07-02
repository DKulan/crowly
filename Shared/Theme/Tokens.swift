// Tokens — the design-system grid (spacing, radii, fonts).
//
// Mirrors docs/design-system.md §1.3 (Spacing & corner radii) and §1.2
// (Typography). Lives in Shared/ so the widget uses the same values.
//
// Why this file is opinionated: every component reads spacing and font from
// here instead of inline numbers, so a single change propagates. Per the
// design-system rule, **never use fixed `.system(size:)`** — all fonts are
// TextStyle-based so Dynamic Type scales the app for free.

import SwiftUI

public enum Space {
    public static let xs: CGFloat = 4
    public static let s:  CGFloat = 8
    public static let m:  CGFloat = 12
    public static let l:  CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

public enum Radius {
    public static let card:      CGFloat = 14
    public static let surface:   CGFloat = 18
    public static let widgetRow: CGFloat = 12
}

public extension Font {
    // Inbox cell
    static let crowlyCellTitle:    Font = .headline
    static let crowlyCellBody:     Font = .body
    // Chips
    static let crowlyChip:         Font = .caption.weight(.medium)
    static let crowlyChipSmall:    Font = .caption2.weight(.medium)
    // Detail
    static let crowlyDetailQ:      Font = .body.weight(.medium)
    static let crowlyDetailCallout: Font = .callout
}

// MARK: - Semantic colors
//
// Mirrors docs/design-system.md §1.1. We use Apple system colors directly
// (label / secondaryLabel / systemGroupedBackground / etc.) so Dynamic
// Type, Smart Invert, Increased Contrast, and dark mode inherit for free
// without an asset catalog drop.

public extension Color {
    /// Inbox list backdrop, settings root (light: systemGroupedBackground,
    /// dark: black). Per docs/design-system.md §1.1.
    static let crowlyBackground = Color(.systemGroupedBackground)

    /// Digest cell + detail card fills. Opaque by rule (legibility against
    /// any wallpaper). Per docs/design-system.md §1.1.
    static let crowlySurface = Color(.secondarySystemGroupedBackground)

    /// Bottom-bar buttons not on glass, sheets.
    static let crowlySurfaceElevated = Color(.tertiarySystemGroupedBackground)

    /// "Mark handled" swipe + resolution success glyph.
    static let crowlySuccess = Color.green

    /// "Mute job" swipe.
    static let crowlyWarning = Color.orange

    /// Reserved (M2; M1 doesn't destroy).
    static let crowlyDestructive = Color.red

    /// "Archive" swipe, archived-state status dot.
    static let crowlyMuted = Color(.systemGray)
}

// MARK: - Callout variants (schema v2 content blocks)
//
// Each `callout` block variant maps to a tint (used for the callout's left
// accent + icon) and an SF Symbol. Mirrors docs/design-system.md § callout
// variants. Colors are system semantic colors so dark mode / contrast inherit.

public extension Color {
    /// Tint for a v2 `callout` block, keyed by variant. Kept distinct from
    /// `urgency(_:)` — a callout's emphasis is authored per-block, independent
    /// of the digest's overall urgency.
    static func callout(_ variant: CalloutVariant) -> Color {
        switch variant {
        case .info:     .accentColor
        case .warning:  .crowlyWarning
        case .success:  .crowlySuccess
        case .critical: .crowlyDestructive
        }
    }
}

public extension CalloutVariant {
    /// SF Symbol paired with each callout variant.
    var symbolName: String {
        switch self {
        case .info:     "info.circle.fill"
        case .warning:  "exclamationmark.triangle.fill"
        case .success:  "checkmark.circle.fill"
        case .critical: "exclamationmark.octagon.fill"
        }
    }
}

// MARK: - Urgency tinting

public extension Color {
    /// Maps a digest's urgency to the accent used on the status dot. Body
    /// text never tints by urgency (legibility rule).
    /// docs/design-system.md §1.1.1.
    static func urgency(_ u: Urgency) -> Color {
        switch u {
        case .low:    .secondary.opacity(0.5)
        case .normal: .accentColor
        case .high:   .crowlyWarning
        case .urgent: .crowlyDestructive
        }
    }
}
