// RelayClient — the iOS app's typed wrapper around the central push relay.
//
// The relay is the ONE piece of Crowly the user doesn't self-host: APNs auth
// keys are bound to the app's Apple credential, so push fan-out is operated
// centrally by the project (docs/architecture.md § Push, § Pairing). The app
// talks to it for exactly two things:
//
//   POST /register    {device_token, routing_token?} -> {routing_token}
//                     Called after APNs hands us a device token. The relay
//                     mints (or reuses) an opaque routing_token mapping
//                     routing_token -> device_token, and NOTHING else. The app
//                     then hands that routing_token to its companion so the
//                     companion can ask the relay to push (without the relay
//                     ever learning the companion or the content).
//   POST /unregister  {routing_token} -> 200/404
//                     The "disconnect" privacy purge.
//
// What this does NOT do: it never sends digest content, titles, or URLs to the
// relay (there's nothing to send — register/unregister carry only tokens). The
// relay is best-effort and never on the read path; a registration failure
// degrades push, not the reader.
//
// Relay URL: a BUILD constant (Info.plist `CrowlyRelayURL`), not user config —
// the relay is central. It is EMPTY by default so demo-mode / App-Review
// builds never reach out to a relay (mirrors the companion's
// push-disabled-when-unconfigured posture). `RelayConfig.url` is nil when
// unset, and `PushRegistrar` no-ops in that case.
//
// Concurrency: a `Sendable` value type; every method is `async`.

import Foundation

// MARK: - Config

enum RelayConfig {
    /// The central relay base URL, read from the app's Info.plist key
    /// `CrowlyRelayURL`. Returns nil when unset/blank so push registration
    /// is a clean no-op (demo builds, App Review, or a dev build with no
    /// relay yet). Set it in project.yml's app `info.properties`.
    static var url: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CrowlyRelayURL") as? String,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: raw) else {
            return nil
        }
        return url
    }
}

// MARK: - Errors

/// Mirrors `CompanionError`'s spirit but for the relay. Kept separate because
/// the relay's failure surface is narrower and best-effort — callers mostly
/// log these rather than show UI.
enum RelayError: Error, Equatable, Sendable {
    case notConfigured                 // no relay URL baked in
    case unreachable(underlying: String)
    case clientError(code: Int, message: String?)
    case serverError(code: Int)
    case invalidResponse
    case decodingFailed(description: String)
}

// MARK: - Wire payloads

private struct RegisterRequest: Encodable {
    let device_token: String
    let routing_token: String?
}

private struct RegisterResponse: Decodable {
    let routing_token: String
}

// MARK: - Client

struct RelayClient: Sendable {

    private let baseURL: URL
    private let session: URLSession

    /// Fails to build (returns nil) when no relay URL is configured — callers
    /// treat that as "push not set up" and skip registration entirely.
    init?(baseURL: URL? = RelayConfig.url, session: URLSession = .shared) {
        guard let baseURL else { return nil }
        self.baseURL = baseURL
        self.session = session
    }

    /// Register this device's APNs token with the relay. Returns the opaque
    /// routing_token the app then hands to its companion. Pass an existing
    /// routing_token to re-bind it to a refreshed device token (idempotent).
    func register(deviceToken: String, existingRoutingToken: String? = nil) async throws -> String {
        let body = RegisterRequest(device_token: deviceToken, routing_token: existingRoutingToken)
        let data = try await post(path: "/register", body: body)
        do {
            return try JSONDecoder().decode(RegisterResponse.self, from: data).routing_token
        } catch {
            throw RelayError.decodingFailed(description: String(describing: error))
        }
    }

    /// Purge this device's mapping (the in-app "disconnect" privacy path).
    func unregister(routingToken: String) async throws {
        struct Body: Encodable { let routing_token: String }
        _ = try await post(path: "/unregister", body: Body(routing_token: routingToken))
    }

    // MARK: Helpers

    private func post<T: Encodable>(path: String, body: T) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw RelayError.notConfigured
        }
        var request = URLRequest(url: url.absoluteURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RelayError.unreachable(underlying: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw RelayError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 400..<500:
            throw RelayError.clientError(code: http.statusCode, message: Self.extractError(from: data))
        case 500..<600:
            throw RelayError.serverError(code: http.statusCode)
        default:
            throw RelayError.invalidResponse
        }
    }

    private static func extractError(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = obj["error"] as? String else {
            return nil
        }
        return msg
    }
}

// MARK: - Device-token formatting

extension Data {
    /// APNs hands the device token as raw `Data`; the relay (and Apple's
    /// HTTP/2 API) expect it lowercase-hex-encoded. Isolated here so the
    /// AppDelegate callback and tests share one definition.
    var apnsHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
