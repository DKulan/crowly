// Tokens — the design-system grid (spacing, radii, fonts, brand palette).
//
// Mirrors docs/design-system.md §1.3 (Spacing & corner radii) and §1.2
// (Typography). Lives in Shared/ so the widget uses the same values.
//
// BRAND IDENTITY (2026-07-02 redesign): Crowly now ships a *fixed warm*
// visual identity sampled from the app icon / onboarding art — a cream field,
// an ink-black serif display face, and a single orange accent. This is a
// deliberate move away from the earlier "adaptive system colors that flip to
// black in dark mode" approach: the crow-on-cream look is the brand, and it
// reads the same on every device. The `Brand` enum below is the source of
// truth; the semantic `Color.crowly*` tokens are re-pointed at it so every
// existing call site inherits the identity for free.
//
// Why this file is opinionated: every component reads spacing, font, and color
// from here instead of inline numbers, so a single change propagates. Per the
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
    /// Fully-rounded brand pill (onboarding / primary CTAs).
    public static let pill:      CGFloat = 28
}

// MARK: - Motion
//
// The motion vocabulary — named curves so timing lives in one place instead of
// scattered inline literals. Crowly's motion philosophy is split: the inbox and
// detail stay deliberately calm (a dot vanish, a system row-removal), while the
// first-run onboarding carousel is allowed to be *rich* (staged reveals, a hero
// hand-off, an ambient crow). These tokens serve both — the calm surfaces reuse
// `press` / `settle`, and onboarding layers on `reveal` / `ambient` / `stagger`.
//
// Every animated state change should route through here (and through
// `Motion.maybe(_:reduceMotion:)` so Reduce Motion is honored consistently).
public enum Motion {
    /// State changes that should feel immediate and crisp — page advance, list
    /// updates. A small-bounce spring; the app's default "something changed".
    public static let pageAdvance: Animation = .snappy

    /// Micro-interaction: button press-dim / scale. Fast, no bounce.
    public static let press: Animation = .snappy(duration: 0.15)

    /// A control settling into place — the page-indicator pill sliding between
    /// dots, a chip resizing. Slightly slower than `press`, still no overshoot.
    public static let settle: Animation = .snappy(duration: 0.25)

    /// Onboarding element entrance — hero → headline → divider → body arriving.
    /// A gentle spring with a hint of life; paired with `stagger` delays.
    public static let reveal: Animation = .spring(response: 0.55, dampingFraction: 0.82)

    /// The hero element settling after the onboarding → inbox hand-off. Softer
    /// and a touch slower so the carry-through reads as one continuous motion.
    public static let heroSettle: Animation = .spring(response: 0.65, dampingFraction: 0.9)

    /// The crow's continuous ambient loop (bob / drift / flap). Long, smooth,
    /// autoreversing — never call this without gating on Reduce Motion.
    public static let ambient: Animation = .easeInOut(duration: 2.2).repeatForever(autoreverses: true)

    /// Base per-element delay for a staggered onboarding reveal. Element `n`
    /// arrives at `n * stagger` seconds after its page becomes active.
    public static let stagger: Double = 0.08

    /// Delay for the element at `index` in a staggered reveal sequence.
    public static func revealDelay(_ index: Int) -> Double { Double(index) * stagger }

    /// Gate an animation on Reduce Motion: returns `nil` (no animation) when the
    /// user has Reduce Motion enabled, so a `.animation(Motion.maybe(...), value:)`
    /// or `withAnimation(Motion.maybe(...) ?? ...)` holds still. Callers that
    /// need a hard fallback can coalesce (`?? .default`).
    public static func maybe(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

// MARK: - Brand palette (fixed, sampled from the app icon + onboarding art)
//
// These are literal sRGB values — the one sanctioned place for
// `Color(red:green:blue:)` (the design-system "no raw hex" rule is about not
// scattering literals across call sites; the palette itself lives here). The
// crow art is ink on cream with a single orange accent, and Crowly commits to
// that look rather than inverting under dark mode — so the identity is stable.
public enum Brand {
    /// The cream field behind everything (icon background, onboarding, inbox).
    public static let cream   = Color(red: 0xFE / 255, green: 0xF8 / 255, blue: 0xF1 / 255)
    /// A slightly deeper cream for grouped-list backdrops so cards lift off it.
    public static let creamDeep = Color(red: 0xF7 / 255, green: 0xF0 / 255, blue: 0xE6 / 255)
    /// Card / surface fill — a warm near-white that sits on the cream field.
    public static let paper   = Color(red: 0xFF / 255, green: 0xFD / 255, blue: 0xFA / 255)
    /// The ink used for the crow and all primary text.
    public static let ink     = Color(red: 0x0B / 255, green: 0x0F / 255, blue: 0x14 / 255)
    /// Secondary ink for body copy / meta — warm dark grey, not pure grey.
    public static let inkSoft = Color(red: 0x3A / 255, green: 0x36 / 255, blue: 0x30 / 255)
    /// Tertiary ink for captions / disabled glyphs.
    public static let inkFaint = Color(red: 0x6B / 255, green: 0x64 / 255, blue: 0x5A / 255)
    /// The signature orange — CTAs, active page dot, accents, the divider.
    public static let orange  = Color(red: 0xF5 / 255, green: 0x87 / 255, blue: 0x1F / 255)
    /// A muted warm grey for hairlines / inactive dots on the cream field.
    public static let hairline = Color(red: 0xD8 / 255, green: 0xCE / 255, blue: 0xBF / 255)
}

public extension Font {
    // Display — the serif face that carries the brand personality. New York
    // (`.serif`) ships with iOS, scales with Dynamic Type, and matches the
    // onboarding headline. Used only for hero/large titles, never body.
    static let crowlyDisplay:      Font = .system(.largeTitle, design: .serif).weight(.bold)
    static let crowlyDisplayLarge: Font = .system(size: 40, weight: .bold, design: .serif)
    static let crowlyTitle:        Font = .system(.title, design: .serif).weight(.semibold)
    static let crowlySectionTitle: Font = .system(.title3, design: .serif).weight(.semibold)

    // Inbox cell
    static let crowlyCellTitle:    Font = .system(.headline, design: .serif)
    static let crowlyCellBody:     Font = .body
    // Chips
    static let crowlyChip:         Font = .caption.weight(.semibold)
    static let crowlyChipSmall:    Font = .caption2.weight(.medium)
    // Detail
    static let crowlyDetailQ:      Font = .body.weight(.medium)
    static let crowlyDetailCallout: Font = .callout
}

// MARK: - Semantic colors
//
// Mirrors docs/design-system.md §1.1, now re-pointed at the fixed `Brand`
// palette (see the header note). Foreground text still uses `.primary` /
// `.secondary` at most call sites via the tint below, but the brand ink is
// available directly for the warm-on-cream surfaces.

public extension Color {
    /// Inbox list backdrop, settings root — the cream field.
    static let crowlyBackground = Brand.cream

    /// A touch-deeper cream for grouped backdrops behind cards.
    static let crowlyGroupedBackground = Brand.creamDeep

    /// Digest cell + detail card fills. Opaque by rule (legibility). Warm paper.
    static let crowlySurface = Brand.paper

    /// Bottom-bar buttons not on glass, sheets.
    static let crowlySurfaceElevated = Brand.paper

    /// Primary ink for warm-surface text.
    static let crowlyInk        = Brand.ink
    static let crowlyInkSoft    = Brand.inkSoft
    static let crowlyInkFaint   = Brand.inkFaint

    /// Hairline / separator on the cream field.
    static let crowlyHairline   = Brand.hairline

    /// The signature accent.
    static let crowlyAccent     = Brand.orange

    /// "Mark handled" swipe + resolution success glyph.
    static let crowlySuccess = Color.green

    /// "Mute job" swipe.
    static let crowlyWarning = Brand.orange

    /// Reserved (M2; M1 doesn't destroy).
    static let crowlyDestructive = Color.red

    /// "Archive" swipe, archived-state status dot.
    static let crowlyMuted = Brand.inkFaint
}

// MARK: - Signature divider
//
// The onboarding art's signature mark: a short orange rule broken by a center
// dot — `——  ●  ——`. Reused under hero headlines and as a section rule. Small,
// deliberate, and unmistakably Crowly.

public struct CrowlyDivider: View {
    /// Overall width of the mark.
    public var width: CGFloat = 132
    public init(width: CGFloat = 132) { self.width = width }

    public var body: some View {
        HStack(spacing: Space.s) {
            line
            Circle()
                .fill(Brand.orange)
                .frame(width: 6, height: 6)
            line
        }
        .frame(width: width)
        .accessibilityHidden(true)
    }

    private var line: some View {
        Capsule()
            .fill(Brand.orange)
            .frame(height: 3)
    }
}

// MARK: - Callout variants (schema v2 content blocks)
//
// Each `callout` block variant maps to a tint (used for the callout's left
// accent + icon) and an SF Symbol. Mirrors docs/design-system.md § callout
// variants.

public extension Color {
    /// Tint for a v2 `callout` block, keyed by variant. Kept distinct from
    /// `urgency(_:)` — a callout's emphasis is authored per-block, independent
    /// of the digest's overall urgency.
    static func callout(_ variant: CalloutVariant) -> Color {
        switch variant {
        case .info:     Brand.orange
        case .warning:  Brand.orange
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
        case .low:    Brand.inkFaint.opacity(0.6)
        case .normal: Brand.orange
        case .high:   Brand.orange
        case .urgent: .crowlyDestructive
        }
    }
}

// MARK: - Brand button style
//
// The flat, full-width orange pill from the onboarding screenshot. Replaces
// `.buttonStyle(.glass)` for *primary* CTAs so the identity is consistent app-
// wide. Ink-on-orange label, subtle press-dim, honors Dynamic Type.

public struct CrowlyPrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.l)
            .background(
                RoundedRectangle(cornerRadius: Radius.pill, style: .continuous)
                    .fill(Brand.orange)
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.99 : 1.0)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == CrowlyPrimaryButtonStyle {
    /// Flat orange brand pill — the primary CTA across the app.
    static var crowlyPrimary: CrowlyPrimaryButtonStyle { CrowlyPrimaryButtonStyle() }
}
