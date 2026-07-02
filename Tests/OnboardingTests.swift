// Onboarding content tests (Swift Testing).
//
// The onboarding UI itself isn't unit-testable headlessly, but its content
// contract is: the deck exists, every screen has copy + a crow, and the crow
// kinds map to stable Lottie asset names (so the future asset swap lines up).

import Testing
import Foundation
@testable import Crowly

@Test func onboardingDeckHasScreens() {
    // A carousel with fewer than 2 pages isn't a carousel. We ship 4.
    #expect(OnboardingScreen.all.count >= 3)
}

@Test func everyOnboardingScreenHasCopy() {
    for screen in OnboardingScreen.all {
        #expect(!screen.title.isEmpty, "a screen is missing its title")
        #expect(!screen.body.isEmpty, "screen \(screen.title) is missing body copy")
    }
}

@Test func onboardingCoversTheInstallShape() {
    // The deck must explain the self-hosted shape, not oversell zero-touch:
    // it should mention the companion/server and pairing somewhere.
    let corpus = OnboardingScreen.all
        .map { ($0.title + " " + $0.body).lowercased() }
        .joined(separator: " ")
    #expect(corpus.contains("server") || corpus.contains("companion"))
    #expect(corpus.contains("pair"))
}

@Test func crowKindsMapToStableImageNames() {
    // The crow image asset name is the art-swap contract; keep it derived from
    // the raw value so a rename can't silently break the asset lookup.
    #expect(CrowKind.welcome.imageName == "crow-welcome")
    #expect(CrowKind.pair.imageName == "crow-pair")
    for kind in CrowKind.allCases {
        #expect(kind.imageName == "crow-\(kind.rawValue)")
        #expect(!kind.placeholderSymbol.isEmpty)
        #expect(!kind.accentSymbol.isEmpty)
    }
}
