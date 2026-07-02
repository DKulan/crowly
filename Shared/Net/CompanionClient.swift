// CompanionClient — the iOS app's typed wrapper around the user's companion
// HTTP API.
//
// What this owns:
//   - Building requests (URL + bearer auth)
//   - Decoding /list and /summary into `{digest, state}` wrappers (the
//     `DigestEnvelope` type below) — the digest itself stays pure schema.
//   - Mirroring app-side state changes via POST /state
//   - Mapping URLSession / HTTP / decode failures into a small typed enum so
//     callers can present sensible UI (unreachable vs. unauthorized vs. junk).
//
// What this does NOT own:
//   - Storage of credentials (lives in KeychainStore)
//   - State (lives in DigestStore)
//   - Push notifications — out of scope for the MVP; the app is pull-only.
//
// Wire contract — see docs/architecture.md § Pairing/Networking and
// companion/server.py:
//   GET  /health             unauth — used by the pairing view to validate
//                            "this URL really is a Crowly companion before we
//                            commit credentials to the keychain."
//   GET  /pair               unauth — `{companion_url, pairing_token}`. The
//                            app reads this after a QR scan (post-M1) so the
//                            user only has to scan one URL.
//   GET  /list               bearer — `{"digests": [{"digest": <Digest>, "state": "..."}, ...]}`,
//                            newest-first. State lives at the wrapper level so
//                            the digest blob stays a pure content document.
//   GET  /summary            bearer — `{"unread_count", "latest": [{"digest":…,"state":…}, …]}`.
//   POST /state              bearer — `{"id", "state"}` mirrors a read/archive.
//
// Concurrency: a value type `Sendable` — every method is `async` and the
// underlying URLSession is `Sendable`. Callers (DigestStore, the pair view)
// can hop actors freely.

import Foundation

// MARK: - Typed errors

/// Surface the pairing/refresh views care about. We don't blast raw
/// `URLError`/`NSError` upstream because they're too noisy for the spec'd UI
/// — the only distinctions that drive different copy are these.
enum CompanionError: Error, Equatable, Sendable {
    /// Couldn't even reach the server — DNS, TLS, timeout, offline.
    case unreachable(underlying: String)
    /// 401/403 — pairing token is wrong or revoked.
    case unauthorized
    /// 4xx other than 401 — request is malformed for this server.
    case clientError(code: Int, message: String?)
    /// 5xx — server's broken.
    case serverError(code: Int)
    /// Response wasn't HTTP at all (shouldn't happen via URLSession, defensive).
    case invalidResponse
    /// JSON decode failure. The schema is additive-only so an unknown field
    /// is NEVER a decode failure — if we land here it's a structural problem
    /// (missing required field, wrong type for a known field).
    case decodingFailed(description: String)
    /// The companion URL or token slots are empty. Caller should re-pair.
    case notConfigured

    static func == (lhs: CompanionError, rhs: CompanionError) -> Bool {
        switch (lhs, rhs) {
        case (.unauthorized, .unauthorized),
             (.invalidResponse, .invalidResponse),
             (.notConfigured, .notConfigured):
            return true
        case let (.unreachable(a), .unreachable(b)):
            return a == b
        case let (.clientError(c1, m1), .clientError(c2, m2)):
            return c1 == c2 && m1 == m2
        case let (.serverError(c1), .serverError(c2)):
            return c1 == c2
        case let (.decodingFailed(a), .decodingFailed(b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Wire payloads

/// A digest-plus-state pair as it arrives from `/list` and `/summary`.
///
/// Wire shape (post code-review correction; companion-dev is shipping this):
///   `{ "digest": <full verbatim Digest JSON>, "state": "unread|read|archived" }`
///
/// The `digest` object is pure schema — state lives at the wrapper level,
/// not inside the digest. That keeps the digest contract content-only
/// (docs/schema.md), `Digest.init`'s extras pass-through stays clean (no
/// UI key masquerading as a content field), and the round-trip through an
/// older companion can't accidentally promote `state` into schema territory.
///
/// Tolerant decode: an unknown state string degrades to `.unread` rather
/// than throw, matching `Urgency`'s degrade-don't-crash rule.
struct DigestEnvelope: Decodable, Sendable {
    let digest: Digest
    let state: DigestState

    private enum CodingKeys: String, CodingKey {
        case digest, state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.digest = try container.decode(Digest.self, forKey: .digest)
        let raw = try container.decode(String.self, forKey: .state)
        self.state = DigestState(rawValue: raw) ?? .unread
    }
}

/// Response wrapper for `GET /list`.
struct ListResponse: Decodable, Sendable {
    let digests: [DigestEnvelope]
}

/// Response wrapper for `GET /summary`.
///
/// `total` is the count of non-archived digests, backing the large widget's
/// "View all N →" footer. Optional + additive: an older companion that doesn't
/// send it decodes fine (nil), and the widget just omits the footer.
struct SummaryResponse: Decodable, Sendable {
    let unread_count: Int
    let latest: [DigestEnvelope]
    let total: Int?
}

/// Response wrapper for `GET /health`.
struct HealthResponse: Decodable, Sendable {
    let status: String
    let stored: Int?
    let schema_versions_supported: [Int]?
}

// MARK: - Client

/// Async HTTP client against one paired companion.
///
/// A new client value is cheap — it carries the credential store and the
/// URLSession (defaulting to `.shared`). Tests can inject a custom session
/// with a mocked `URLProtocol` to drive request shaping without a live
/// server.
struct CompanionClient: Sendable {

    /// The credential source. Reads the URL + token on every call so a
    /// re-pair takes effect without rebuilding the client.
    private let credentials: CredentialStore
    private let session: URLSession

    init(credentials: CredentialStore, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    // MARK: Endpoints

    /// `GET /list`. Newest-first list of every digest plus its per-digest state.
    func list() async throws -> [DigestEnvelope] {
        let request = try buildRequest(path: "/list", method: "GET", authed: true)
        let data = try await perform(request)
        do {
            return try Self.decoder.decode(ListResponse.self, from: data).digests
        } catch {
            throw CompanionError.decodingFailed(description: String(describing: error))
        }
    }

    /// `GET /summary`. Cheap pull for the widget surface.
    func summary() async throws -> SummaryResponse {
        let request = try buildRequest(path: "/summary", method: "GET", authed: true)
        let data = try await perform(request)
        do {
            return try Self.decoder.decode(SummaryResponse.self, from: data)
        } catch {
            throw CompanionError.decodingFailed(description: String(describing: error))
        }
    }

    /// `POST /state`. Mirror an app-side state change so the companion
    /// stays the source of truth (architecture.md § Companion → Store).
    /// Idempotent; the companion swallows duplicates.
    func setState(id: String, state: DigestState) async throws {
        var request = try buildRequest(path: "/state", method: "POST", authed: true)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["id": id, "state": state.rawValue]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await perform(request)
    }

    /// `GET /health`. Used by the pairing view to confirm a URL+token combo
    /// before we commit it to the keychain. Returns the health payload so
    /// the UI can show "stored: N" as a sanity-check.
    func health() async throws -> HealthResponse {
        // `/health` is unauthenticated per server.py — but we still send the
        // bearer so this call doubles as a token-validity check (a wrong
        // token would 401 on /list; /health alone wouldn't catch that).
        // The pairing view also exercises a `list()` post-health for that.
        let request = try buildRequest(path: "/health", method: "GET", authed: false)
        let data = try await perform(request)
        do {
            return try Self.decoder.decode(HealthResponse.self, from: data)
        } catch {
            throw CompanionError.decodingFailed(description: String(describing: error))
        }
    }

    // MARK: Helpers

    /// JSON decoder used for every response. We deliberately do NOT set a
    /// `keyDecodingStrategy` here: the wire shape is already snake_case and
    /// the existing `Digest.init` reads snake_case keys explicitly. Letting
    /// the strategy auto-camelCase would only affect `ListResponse` /
    /// `SummaryResponse` (which use snake_case fields too) and risks
    /// fighting the manual decoder in `Digest`.
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    private func buildRequest(path: String, method: String, authed: Bool) throws -> URLRequest {
        guard let urlString = credentials.get(.companionURL),
              let base = URL(string: urlString),
              let url = URL(string: path, relativeTo: base) else {
            throw CompanionError.notConfigured
        }
        var request = URLRequest(url: url.absoluteURL)
        request.httpMethod = method
        request.timeoutInterval = 15
        if authed {
            guard let token = credentials.get(.pairingToken), !token.isEmpty else {
                throw CompanionError.notConfigured
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if let token = credentials.get(.pairingToken), !token.isEmpty {
            // `/health` doesn't require auth, but if the caller has a token,
            // send it — it's a free signal that the pairing is intact.
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CompanionError.unreachable(underlying: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CompanionError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw CompanionError.unauthorized
        case 400..<500:
            throw CompanionError.clientError(
                code: http.statusCode,
                message: Self.extractError(from: data),
            )
        case 500..<600:
            throw CompanionError.serverError(code: http.statusCode)
        default:
            throw CompanionError.invalidResponse
        }
    }

    /// Pull the `error` field out of a JSON error body if present. The
    /// companion always returns `{"error": "..."}` on 4xx/5xx; this lets the
    /// pairing view show the server's message rather than a status code.
    private static func extractError(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = obj["error"] as? String else {
            return nil
        }
        return msg
    }
}

// MARK: - URL normalization

extension CompanionClient {

    /// Tidy a user-typed URL into something `URL(string:)` won't choke on.
    /// Strips trailing slashes (the request builder uses `/list` style
    /// relative paths) and prepends `https://` if the scheme is missing.
    /// Returns nil for input that can't be salvaged.
    ///
    /// Why this lives on the client: the pairing view needs the same rule
    /// when validating, and so does the keychain write path.
    static func normalize(url raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme: String
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            withScheme = trimmed
        } else {
            withScheme = "https://" + trimmed
        }
        // Drop trailing slashes — `URL(string: "/list", relativeTo: ...)`
        // appends, so we don't want `https://x.com//list`.
        let stripped: String = {
            var s = withScheme
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }()
        guard URL(string: stripped) != nil else { return nil }
        return stripped
    }
}
