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

    private let screens = OnboardingScreen.all

    var body: some View {
        ZStack {
            // Full-bleed cream background
            Brand.cream.ignoresSafeArea()

            VStack(spacing: 0) {
                // Skip — top-right, only on non-final pages
                HStack {
                    Spacer()
                    if page < screens.count - 1 {
                        Button("Skip") { onFinish(false) }
                            .font(.system(.title3, design: .default).weight(.regular))
                            .foregroundStyle(Brand.inkSoft)
                            .padding(.trailing, Space.l)
                            .padding(.top, Space.m)
                            .transition(.opacity)
                    }
                }
                .frame(height: 48)

                // Swipeable page content
                TabView(selection: $page) {
                    ForEach(Array(screens.enumerated()), id: \.offset) { index, screen in
                        OnboardingPage(screen: screen)
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
                            withAnimation(.snappy) { page += 1 }
                        } else {
                            onFinish(true)   // last screen → open pairing
                        }
                    } label: {
                        Text(page < screens.count - 1 ? "Next" : "Connect my inbox")
                    }
                    .buttonStyle(.crowlyPrimary)

                    if page == screens.count - 1 {
                        Button("Look around first") { onFinish(false) }
                            .font(.callout)
                            .foregroundStyle(Brand.inkSoft)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, Space.xl)
                .padding(.bottom, Space.xl)
                .animation(.snappy, value: page)
            }
        }
    }
}

// MARK: - One page

private struct OnboardingPage: View {
    let screen: OnboardingScreen

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Space.l)

            // Hero: the crow art with ambient motion
            CrowAnimationView(kind: screen.crow)
                .padding(.bottom, Space.xl)

            // Headline: large bold serif
            Text(screen.title)
                .font(.crowlyDisplayLarge)
                .foregroundStyle(Brand.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.xl)
                .padding(.bottom, Space.m)

            // Signature divider: ——●——
            CrowlyDivider(width: 132)
                .padding(.bottom, Space.m)

            // Body: SF Pro, soft ink, centered, narrow column
            Text(screen.body)
                .font(.body)
                .foregroundStyle(Brand.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)
                .padding(.horizontal, Space.xl + Space.l)

            Spacer(minLength: Space.xxl)
        }
        .frame(maxWidth: .infinity)
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
