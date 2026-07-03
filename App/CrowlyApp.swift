import SwiftUI

@main
struct CrowlyApp: App {
    /// The deeplink router is owned at the scene level so the URL handler
    /// can write to it; InboxView reads it via the environment. Bug #2
    /// fix from review pass B.
    @State private var router = DeepLinkRouter()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(router)
                // Brand identity is a fixed warm palette (cream field, ink
                // text, orange accent) — it does not invert under dark mode.
                // Lock the light appearance so system `.primary`/`.secondary`
                // resolve to dark-on-cream, and tint everything brand orange.
                .tint(Brand.orange)
                .preferredColorScheme(.light)
                .onOpenURL { url in
                    router.handle(url)
                }
        }
    }
}
