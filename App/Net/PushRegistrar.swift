// PushRegistrar — bridges APNs device-token registration into the relay.
//
// The flow (docs/architecture.md § Pairing, § Push; docs/onboarding.md Step 5):
//
//   1. AFTER the user pairs (and only then) we ask for notification
//      authorization and register for remote notifications. We deliberately
//      do NOT prompt an unpaired/demo user (or an App Reviewer) — there's no
//      relay to register with and no push to receive until they've connected a
//      companion. Prompting earlier would be a gratuitous permission ask.
//   2. iOS calls back with the APNs device token (raw Data).
//   3. We hand the hex-encoded token to the relay's /register, which returns
//      an opaque routing_token.
//   4. We persist the routing_token in the keychain. The user reads it
//      (Settings → "Push routing token") and pastes it into their companion's
//      CROWLY_ROUTING_TOKEN so the companion can drive push.
//
// Best-effort throughout: every step is wrapped so a failure degrades push but
// never the reader. If RelayConfig.url is unset (demo build / no relay yet),
// this is a clean no-op.
//
// Why an AppDelegate: SwiftUI's App lifecycle has no hook for
// `didRegisterForRemoteNotificationsWithDeviceToken`. The standard bridge is
// `UIApplicationDelegateAdaptor`. The delegate owns only the APNs plumbing;
// all decisions live in `PushRegistrar`.

import SwiftUI
import UserNotifications

// MARK: - Registrar

/// Owns the post-pairing push setup. `@MainActor` because it touches
/// `UIApplication` and is observed by the app. Holds no UI state itself.
@MainActor
final class PushRegistrar {

    static let shared = PushRegistrar()

    /// Where the minted routing_token lands. Defaults to the real keychain;
    /// tests inject an in-memory store.
    private let credentials: CredentialStore

    /// Builds a relay client per call so a nil (unconfigured) relay is handled
    /// uniformly. Injectable for tests.
    private let makeRelay: @Sendable () -> RelayClient?

    init(
        credentials: CredentialStore = KeychainStore(),
        makeRelay: @escaping @Sendable () -> RelayClient? = { RelayClient() }
    ) {
        self.credentials = credentials
        self.makeRelay = makeRelay
    }

    /// Call once the user has paired. Requests notification authorization and,
    /// if granted, kicks off APNs registration. No-op when no relay is
    /// configured — push simply isn't available in that build.
    func registerForPushIfPaired() async {
        guard RelayConfig.url != nil else {
            // No central relay baked into this build — push is off. Pull still
            // works; this is the expected demo / early-dev posture.
            return
        }
        guard credentials.isPaired else { return }

        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard granted else {
                // User declined. Push is best-effort; the reader is unaffected.
                return
            }
        } catch {
            #if DEBUG
            print("[PushRegistrar] auth request failed: \(error)")
            #endif
            return
        }

        // Triggers `didRegisterForRemoteNotificationsWithDeviceToken` (or the
        // failure callback) on the app delegate, which routes back to
        // `handleDeviceToken`.
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Called by the app delegate when APNs hands us a device token. Registers
    /// it with the relay and stores the returned routing_token. Best-effort.
    func handleDeviceToken(_ deviceToken: Data) async {
        guard let relay = makeRelay() else { return }
        let hex = deviceToken.apnsHexString
        // Reuse an existing routing_token if we have one, so a token refresh
        // re-binds the same mapping rather than orphaning the companion's
        // CROWLY_ROUTING_TOKEN.
        let existing = credentials.get(.routingToken)
        do {
            let routingToken = try await relay.register(
                deviceToken: hex,
                existingRoutingToken: existing
            )
            try? credentials.set(.routingToken, value: routingToken)
            #if DEBUG
            print("[PushRegistrar] registered with relay; routing_token stored")
            #endif
        } catch {
            // Push registration failed — log and move on. The reader is fully
            // usable; the user can retry by re-opening the app (which re-runs
            // registerForPushIfPaired) or re-pairing.
            #if DEBUG
            print("[PushRegistrar] relay register failed: \(error)")
            #endif
        }
    }

    /// The routing token to surface in Settings for the user to paste into
    /// their companion. Nil until registration has completed at least once.
    var routingTokenForDisplay: String? {
        credentials.get(.routingToken)
    }
}

// MARK: - App delegate adaptor

/// Minimal UIKit delegate that exists only to receive the APNs callbacks
/// SwiftUI's lifecycle doesn't expose, and forward them to `PushRegistrar`.
final class CrowlyAppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            await PushRegistrar.shared.handleDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Common in the simulator (no real APNs) and when offline. Push is
        // best-effort; swallow with a debug log.
        #if DEBUG
        print("[CrowlyAppDelegate] remote notification registration failed: \(error)")
        #endif
    }
}
