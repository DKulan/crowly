// OnboardingView — the first-run swipeable carousel.
//
// Four screens, paged: what Crowly is → stand up the companion → hook up your
// agent → pair. The last screen's CTA either opens the pairing sheet (hand off
// to PairCompanionView) or dismisses into demo mode ("Look around first").
//
// Content is grounded in docs/deployment-learnings.md — the real install shape:
// a self-hosted companion (Tailscale Funnel default TLS), an agent (Hermes)
// emitting over the shared docker net, and a QR/manual pair. We DON'T promise
// zero-touch; the honest ceiling is "download app → ask your agent → one auth
// click → scan one QR."
//
// Visuals match the fixed brand identity: full cream field, the ink crow hero
// (CrowAnimationView), a serif headline, the ——●—— CrowlyDivider signature, a
// custom orange-pill page indicator (OnboardingPageIndicator), and the flat
// orange CTA (.buttonStyle(.crowlyPrimary)). Motion + tokens are shared.

import SwiftUI

struct OnboardingView: View {
    /// Called when the user finishes (or skips) onboarding. The parent flips
    /// `hasOnboarded` and, if `startPairing` is true, presents the pair sheet.
    let onFinish: (_ startPairing: Bool) -> Void

    @State private var page = 0
    /// Drives the hero hand-off: when the user finishes, the whole composition
    /// lifts + scales + fades ("lifting off into the app") before the parent
    /// cross-fades this cover away to reveal the inbox. One continuous motion.
    @State private var handingOff = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let screens = OnboardingScreen.all

    /// Duration of the lift-off before the parent removes the cover. Kept just
    /// under the `heroSettle` spring so the fade overlaps the tail of the lift.
    private static let handoffLead: Duration = .milliseconds(420)

    /// Run the hand-off, then tell the parent we're done. Under Reduce Motion we
    /// skip the lift and finish immediately (the parent's cross-fade remains).
    private func finish(startPairing: Bool) {
        guard !reduceMotion else { onFinish(startPairing); return }
        withAnimation(Motion.heroSettle) { handingOff = true }
        Task {
            try? await Task.sleep(for: Self.handoffLead)
            onFinish(startPairing)
        }
    }

    var body: some View {
        ZStack {
            // Full-bleed warm field — a subtle breathing MeshGradient in the
            // brand palette (holds still under Reduce Motion).
            OnboardingBackground()
                .opacity(handingOff ? 0 : 1)

            VStack(spacing: 0) {
                // Skip — top-right, only on non-final pages
                HStack {
                    Spacer()
                    if page < screens.count - 1 {
                        Button("Skip") { finish(startPairing: false) }
                            .font(.system(.title3, design: .default).weight(.regular))
                            .foregroundStyle(Brand.inkSoft)
                            .padding(.trailing, Space.l)
                            .padding(.top, Space.m)
                            .transition(.opacity)
                    }
                }
                .frame(height: 48)

                // Swipeable page content. Each page reveals its elements in a
                // gentle stagger when it becomes the selected page (`isActive`),
                // and replays when swiped back to.
                TabView(selection: $page) {
                    ForEach(Array(screens.enumerated()), id: \.offset) { index, screen in
                        OnboardingPage(screen: screen, isActive: page == index)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                Spacer()

                // Custom page indicator + CTA
                VStack(spacing: Space.l) {
                    OnboardingPageIndicator(currentPage: page, totalPages: screens.count)

                    Button {
                        if page < screens.count - 1 {
                            withAnimation(Motion.pageAdvance) { page += 1 }
                        } else {
                            finish(startPairing: true)   // last screen → open pairing
                        }
                    } label: {
                        Text(page < screens.count - 1 ? "Next" : "Connect my inbox")
                            // Cross-fade the label as it swaps on the last page
                            // instead of a hard cut.
                            .contentTransition(.opacity)
                    }
                    .buttonStyle(.crowlyPrimary)

                    if page == screens.count - 1 {
                        Button("Look around first") { finish(startPairing: false) }
                            .font(.callout)
                            .foregroundStyle(Brand.inkSoft)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, Space.xl)
                .padding(.bottom, Space.xl)
                .animation(Motion.pageAdvance, value: page)
            }
            // Hero hand-off: on finish the whole composition lifts, scales up a
            // touch, and fades — reading as one continuous "lifting off into the
            // app" motion before the parent cross-fades this cover away to
            // reveal the inbox underneath. `anchor: .top` keeps the crow leading.
            .scaleEffect(handingOff ? 1.06 : 1, anchor: .top)
            .offset(y: handingOff ? -28 : 0)
            .opacity(handingOff ? 0 : 1)
        }
    }
}

// MARK: - One page

private struct OnboardingPage: View {
    let screen: OnboardingScreen
    /// True when this is the selected page. Drives the staggered reveal — and,
    /// because it flips back to false when the page leaves, the reveal replays
    /// on return so swiping back and forth always feels alive.
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Flips true a beat after the page becomes active, kicking off the reveal.
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Space.l)

            // Hero: the crow art with ambient motion
            CrowAnimationView(kind: screen.crow)
                .padding(.bottom, Space.xl)
                .modifier(RevealModifier(index: 0, appeared: appeared, reduceMotion: reduceMotion))

            // Headline: large bold serif
            Text(screen.title)
                .font(.crowlyDisplayLarge)
                .foregroundStyle(Brand.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.xl)
                .padding(.bottom, Space.m)
                .modifier(RevealModifier(index: 1, appeared: appeared, reduceMotion: reduceMotion))

            // Signature divider: ——●——
            CrowlyDivider(width: 132)
                .padding(.bottom, Space.m)
                .modifier(RevealModifier(index: 2, appeared: appeared, reduceMotion: reduceMotion))

            // Body: SF Pro, soft ink, centered, narrow column
            Text(screen.body)
                .font(.body)
                .foregroundStyle(Brand.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)
                .padding(.horizontal, Space.xl + Space.l)
                .modifier(RevealModifier(index: 3, appeared: appeared, reduceMotion: reduceMotion))

            Spacer(minLength: Space.xxl)
        }
        .frame(maxWidth: .infinity)
        // Kick the reveal when the page becomes active; reset when it leaves so
        // returning to it replays the stagger. `initial: true` also fires for
        // the first page on launch.
        .onChange(of: isActive, initial: true) { _, nowActive in
            appeared = nowActive
        }
    }
}

/// Staggered entrance for one onboarding element: fades + rises into place with
/// a per-`index` delay. Reduce Motion drops the offset and the stagger, keeping
/// only a plain cross-fade so the sequence stays accessible.
private struct RevealModifier: ViewModifier {
    let index: Int
    let appeared: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: reveal)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.2)
                    : Motion.reveal.delay(appeared ? Motion.revealDelay(index) : 0),
                value: appeared
            )
    }

    /// The pre-reveal vertical offset — elements start a touch low and rise.
    /// Held flat under Reduce Motion (cross-fade only).
    private var reveal: CGFloat {
        guard !reduceMotion else { return 0 }
        return appeared ? 0 : 16
    }
}

// MARK: - Screen content

/// One onboarding screen's copy + crow. Copy is deliberately honest about the
/// self-hosted shape (docs/deployment-learnings.md) — no zero-touch promise.
struct OnboardingScreen {
    let crow: CrowKind
    let title: String
    let body: String

    static let all: [OnboardingScreen] = [
        OnboardingScreen(
            crow: .welcome,
            title: "Your agents, in one calm inbox",
            body: "Crowly is a reader for the digests your AI agents produce on a schedule — news, weather, briefings. No pings to chase. You open it when you want; nothing acts on your behalf."
        ),
        OnboardingScreen(
            crow: .companion,
            title: "Runs on your own machine",
            body: "Your digests live on a small companion service you host yourself — on a server or your own computer, behind your own TLS. No central Crowly server ever sees your content. A Tailscale Funnel is the easy default: it works whether you're on a VPS or a home machine, with no domain or certificate to wrangle."
        ),
        OnboardingScreen(
            crow: .hermes,
            title: "Your agent fills it",
            body: "Point your agent at the companion with the emitter kit — a few lines of Python, no Docker required — and it posts schema-valid digests on its own schedule. If your agent can run commands on the host, it can even set the companion up for you."
        ),
        OnboardingScreen(
            crow: .pair,
            title: "Pair once, then read",
            body: "Scan the QR your companion prints (or paste its URL + token) to pair this app to your inbox. The pairing secret goes straight into your Keychain — it never leaves your phone. New digests appear whenever your companion is reachable, so it's happiest on a machine that stays awake."
        ),
    ]
}

#Preview {
    OnboardingView { startPairing in
        print("finished, startPairing=\(startPairing)")
    }
}
