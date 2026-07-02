// ContentView — the app's root view. Hosts the first-run onboarding gate and
// InboxView, and injects the DigestStore. In M1 demo mode the store is seeded
// with `DemoFixtures` so the inbox renders without any companion connection.

import SwiftUI

struct ContentView: View {
    /// Live store — credentials come from the real Keychain. If the user
    /// hasn't paired yet, `DigestStore` falls back to demo fixtures
    /// automatically.
    @State private var store = DigestStore(credentials: KeychainStore())

    /// First-run gate. False until the user completes (or skips) onboarding;
    /// persisted so the carousel shows exactly once. A `crowly://onboarding`
    /// deeplink resets it for testing (see the router / CrowlyApp handler).
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    @Environment(DeepLinkRouter.self) private var router

    /// How often to re-pull `/list` while the app is foregrounded. The
    /// companion is a personal VPS serving one reader, so a gentle poll is
    /// cheap; digests arrive on cron schedules (minutes-to-hours), not
    /// live, so a minute of latency is imperceptible.
    private static let pollInterval: Duration = .seconds(60)

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            inbox
            if !hasOnboarded {
                OnboardingView { startPairing in
                    withAnimation(.snappy) { hasOnboarded = true }
                    // Hand off to the pairing sheet InboxView already owns,
                    // via the router slot it observes. Deferred a beat so the
                    // sheet presents after the onboarding cover transitions out.
                    if startPairing {
                        router.pendingPair = true
                    }
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        // A `crowly://onboarding` deeplink flips this back on to replay the
        // flow (testing / "show me that again"). Handled here because the gate
        // state lives in this view.
        .onChange(of: router.replayOnboarding) { _, _ in
            withAnimation(.snappy) { hasOnboarded = false }
        }
    }

    private var inbox: some View {
        InboxView()
            .environment(store)
            // Auto-refresh replaces pull-to-refresh: refresh whenever the
            // app becomes active (launch or foreground) and then poll on an
            // interval. The task id folds in `isInDemoMode` as well as
            // `scenePhase` so the loop restarts on *either* transition:
            // leaving `.active` cancels the poll, and pairing/disconnecting
            // (which flips demo mode without any scene change) starts or
            // stops it. Keying on `scenePhase` alone would leave the poll off
            // for the whole first session after an in-app pair.
            .task(id: RefreshTrigger(scenePhase: scenePhase, isInDemoMode: store.isInDemoMode)) {
                guard scenePhase == .active, !store.isInDemoMode else { return }
                await store.refresh()
                // Poll until the task is cancelled (scene left `.active`).
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.pollInterval)
                    if Task.isCancelled { break }
                    await store.refresh()
                }
            }
    }
}

/// Identity for the auto-refresh `.task`. Changing any field cancels the
/// running poll loop and starts a fresh one — see the `.task(id:)` call.
private struct RefreshTrigger: Equatable {
    let scenePhase: ScenePhase
    let isInDemoMode: Bool
}

#Preview {
    ContentView()
        .environment(DeepLinkRouter())
}
