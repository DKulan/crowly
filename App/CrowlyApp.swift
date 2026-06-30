import SwiftUI

@main
struct CrowlyApp: App {
    /// The deeplink router is owned at the scene level so the URL handler
    /// can write to it; InboxView reads it via the environment. Bug #2
    /// fix from review pass B.
    @State private var router = DeepLinkRouter()

    /// UIKit delegate adaptor — exists only to receive the APNs device-token
    /// callbacks SwiftUI's lifecycle doesn't expose, and forward them to
    /// `PushRegistrar`. See App/Net/PushRegistrar.swift.
    @UIApplicationDelegateAdaptor(CrowlyAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(router)
                .onOpenURL { url in
                    router.handle(url)
                }
                .task {
                    // If the user is already paired from a previous launch,
                    // (re-)register for push so a refreshed APNs token rebinds.
                    // No-op for demo/unpaired and for builds with no relay URL.
                    await PushRegistrar.shared.registerForPushIfPaired()
                }
        }
    }
}
