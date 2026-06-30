// ContentView — the app's root view. Hosts InboxView and injects the
// DigestStore. In M1 demo mode the store is seeded with `DemoFixtures` so
// the inbox renders without any companion connection.

import SwiftUI

struct ContentView: View {
    /// Live store — credentials come from the real Keychain. If the user
    /// hasn't paired yet, `DigestStore` falls back to demo fixtures
    /// automatically.
    @State private var store = DigestStore(credentials: KeychainStore())

    var body: some View {
        InboxView()
            .environment(store)
            .task {
                // If we launched into live mode (already paired), pull a
                // fresh /list so the inbox doesn't sit empty before the
                // user pulls-to-refresh.
                if !store.isInDemoMode {
                    await store.refresh()
                }
            }
    }
}

#Preview {
    ContentView()
        .environment(DeepLinkRouter())
}
