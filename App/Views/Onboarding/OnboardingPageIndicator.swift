// OnboardingPageIndicator — the custom page-dot row for onboarding.
//
// A row of 4 dots: the active one is an ORANGE PILL (wider), inactive ones are
// small grey circles. Matches the onboarding screenshot's signature look.
//
// The active pill uses `matchedGeometryEffect` so it *slides and morphs*
// between dot slots on a page change rather than popping in and out — each
// slot reserves a fixed pill-width footprint so the row never reflows as the
// pill travels. Reduce Motion falls back to an instant (un-animated) move.

import SwiftUI

struct OnboardingPageIndicator: View {
    let currentPage: Int
    let totalPages: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pill

    private static let pillID = "activePill"
    private static let dot: CGFloat = 8
    private static let pillWidth: CGFloat = 24

    var body: some View {
        HStack(spacing: Space.s) {
            ForEach(0..<totalPages, id: \.self) { index in
                // Each slot reserves the pill's full width so the row layout is
                // stable; the grey dot sits centered, and the active slot hosts
                // the matched orange pill.
                ZStack {
                    Circle()
                        .fill(Brand.hairline.opacity(0.35))
                        .frame(width: Self.dot, height: Self.dot)

                    if index == currentPage {
                        Capsule()
                            .fill(Brand.orange)
                            .frame(width: Self.pillWidth, height: Self.dot)
                            .matchedGeometryEffect(id: Self.pillID, in: pill)
                    }
                }
                .frame(width: Self.pillWidth, height: Self.dot)
            }
        }
        .animation(Motion.maybe(Motion.settle, reduceMotion: reduceMotion), value: currentPage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(currentPage + 1) of \(totalPages)")
    }
}

#Preview {
    VStack(spacing: 32) {
        ForEach(0..<4) { page in
            OnboardingPageIndicator(currentPage: page, totalPages: 4)
        }
    }
    .padding()
    .background(Brand.cream)
}
