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
                .onOpenURL { url in
                    router.handle(url)
                }
        }
    }
}
