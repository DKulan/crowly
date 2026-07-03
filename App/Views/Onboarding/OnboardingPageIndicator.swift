// OnboardingPageIndicator — the custom page-dot row for onboarding.
//
// A row of 4 dots: the active one is an ORANGE PILL (wider), inactive ones are
// small grey circles. Matches the onboarding screenshot's signature look.

import SwiftUI

struct OnboardingPageIndicator: View {
    let currentPage: Int
    let totalPages: Int

    var body: some View {
        HStack(spacing: Space.s) {
            ForEach(0..<totalPages, id: \.self) { index in
                if index == currentPage {
                    // Active: orange elongated pill
                    Capsule()
                        .fill(Brand.orange)
                        .frame(width: 24, height: 8)
                } else {
                    // Inactive: small grey circle
                    Circle()
                        .fill(Brand.hairline.opacity(0.35))
                        .frame(width: 8, height: 8)
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: currentPage)
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
