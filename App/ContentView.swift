// ContentView — the app's root view. Hosts InboxView and injects the
// DigestStore. In M1 demo mode the store is seeded with `DemoFixtures` so
// the inbox renders without any companion connection.

import SwiftUI

struct ContentView: View {
    @State private var store = DigestStore()

    var body: some View {
        InboxView()
            .environment(store)
    }
}

#Preview {
    ContentView()
        .environment(DeepLinkRouter())
}
