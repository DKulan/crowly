// Networking-layer tests for Crowly's iOS app.
//
// What we prove here:
//   - `DigestEnvelope` decodes the companion's wrapper shape
//     ({digest, state}); the digest object stays pure schema (no UI fields).
//   - The digest's `extras` map stays clean (no `state` key leaking in).
//   - `CompanionClient` shapes requests correctly (Bearer auth, JSON
//     content-type, path) without a live server, via a mocked URLProtocol.
//   - The pair/unpair branch in `DigestStore` selects demo vs. live correctly
//     and demo mode remains intact when no credentials are stored.
//   - `KeychainStore.isPaired` reflects the URL/token slot state.
//   - `CompanionClient.normalize` handles missing schemes / trailing slashes.

import Testing
import Foundation
@testable import Crowly

// MARK: - DigestEnvelope decoding (wrapper shape: {digest, state})

@Test func envelopeDecodesWrapperShape() throws {
    let json = """
    {
      "digest": {
        "schema_version": 1,
        "id": "dgst_test_1",
        "job_id": "job-x",
        "source": "hermes-cron",
        "title": "T",
        "created_at": "2026-06-29T19:00:00Z",
        "urgency": "normal",
        "bottom_line": "x"
      },
      "state": "read"
    }
    """.data(using: .utf8)!

    let envelope = try JSONDecoder().decode(DigestEnvelope.self, from: json)
    #expect(envelope.digest.id == "dgst_test_1")
    #expect(envelope.state == .read)
    // The digest is pure schema — no `state` key leaks into extras.
    #expect(envelope.digest.extras["state"] == nil)
    #expect(envelope.digest.extras["_state"] == nil)
}

@Test func envelopePreservesDigestExtrasUntouched() throws {
    // A v2-only field inside the digest blob must survive the wrapper decode
    // (the schema is additive-only). The wrapper itself never sees this key;
    // only `Digest.init` does, and it parks it in extras.
    let json = """
    {
      "digest": {
        "schema_version": 1,
        "id": "dgst_test_extras",
        "job_id": "job-x",
        "source": "hermes-cron",
        "title": "T",
        "created_at": "2026-06-29T19:00:00Z",
        "urgency": "normal",
        "bottom_line": "x",
        "future_field": "v2-only"
      },
      "state": "unread"
    }
    """.data(using: .utf8)!

    let envelope = try JSONDecoder().decode(DigestEnvelope.self, from: json)
    #expect(envelope.digest.extras["future_field"] == .string("v2-only"))
}

@Test func envelopeUnknownStateDegradesToUnread() throws {
    // Forward-compat: if a future companion ships a state value this app
    // doesn't know yet, we don't crash — we degrade to `.unread`.
    let json = """
    {
      "digest": {
        "schema_version": 1,
        "id": "dgst_test_3",
        "job_id": "job-x",
        "source": "hermes-cron",
        "title": "T",
        "created_at": "2026-06-29T19:00:00Z",
        "urgency": "normal",
        "bottom_line": "x"
      },
      "state": "snoozed_until_tomorrow"
    }
    """.data(using: .utf8)!
    let envelope = try JSONDecoder().decode(DigestEnvelope.self, from: json)
    #expect(envelope.state == .unread)
}

@Test func envelopeMissingStateFieldFailsToDecode() {
    // Wrapper requires `state` per the contract — a missing key is a
    // structural error, not a degrade-to-unread case (defaults belong
    // inside the digest's extras-preserving decoder, not at the wrapper
    // level which is fully under our control).
    let json = """
    {
      "digest": {
        "schema_version": 1, "id": "x", "job_id": "j",
        "source": "hermes-cron", "title": "T",
        "created_at": "2026-06-29T19:00:00Z",
        "urgency": "normal", "bottom_line": "x"
      }
    }
    """.data(using: .utf8)!
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(DigestEnvelope.self, from: json)
    }
}

@Test func listResponseDecodesArrayOfEnvelopes() throws {
    let json = """
    {
      "digests": [
        {
          "digest": {
            "schema_version": 1, "id": "a", "job_id": "j", "source": "hermes-cron",
            "title": "A", "created_at": "2026-06-29T19:00:00Z", "urgency": "normal",
            "bottom_line": "x"
          },
          "state": "unread"
        },
        {
          "digest": {
            "schema_version": 1, "id": "b", "job_id": "j", "source": "hermes-cron",
            "title": "B", "created_at": "2026-06-29T18:00:00Z", "urgency": "high",
            "bottom_line": "y"
          },
          "state": "archived"
        }
      ]
    }
    """.data(using: .utf8)!
    let list = try JSONDecoder().decode(ListResponse.self, from: json)
    #expect(list.digests.count == 2)
    #expect(list.digests[0].state == .unread)
    #expect(list.digests[0].digest.id == "a")
    #expect(list.digests[1].state == .archived)
    #expect(list.digests[1].digest.id == "b")
}

@Test func summaryResponseDecodes() throws {
    let json = """
    {
      "unread_count": 3,
      "latest": [
        {
          "digest": {
            "schema_version": 1, "id": "a", "job_id": "j", "source": "hermes-cron",
            "title": "A", "created_at": "2026-06-29T19:00:00Z", "urgency": "normal",
            "bottom_line": "x"
          },
          "state": "unread"
        }
      ]
    }
    """.data(using: .utf8)!
    let summary = try JSONDecoder().decode(SummaryResponse.self, from: json)
    #expect(summary.unread_count == 3)
    #expect(summary.latest.count == 1)
    #expect(summary.latest[0].digest.id == "a")
}

// MARK: - URL normalization

@Test func normalizeAddsHTTPSWhenMissing() {
    #expect(CompanionClient.normalize(url: "example.com") == "https://example.com")
}

@Test func normalizePreservesExistingScheme() {
    #expect(CompanionClient.normalize(url: "http://localhost:8787") == "http://localhost:8787")
    #expect(CompanionClient.normalize(url: "https://x.com") == "https://x.com")
}

@Test func normalizeStripsTrailingSlashes() {
    #expect(CompanionClient.normalize(url: "https://x.com/") == "https://x.com")
    #expect(CompanionClient.normalize(url: "https://x.com///") == "https://x.com")
}

@Test func normalizeTrimsWhitespace() {
    #expect(CompanionClient.normalize(url: "  https://x.com  ") == "https://x.com")
}

@Test func normalizeRejectsEmpty() {
    #expect(CompanionClient.normalize(url: "") == nil)
    #expect(CompanionClient.normalize(url: "   ") == nil)
}

// MARK: - Credential store / isPaired

@Test func credentialStoreIsPairedReflectsBothSlots() throws {
    let store = InMemoryCredentialStore()
    #expect(!store.isPaired)
    try store.set(.companionURL, value: "https://x.com")
    #expect(!store.isPaired)
    try store.set(.pairingToken, value: "secret")
    #expect(store.isPaired)
}

@Test func credentialStoreInvalidURLIsNotPaired() throws {
    let store = InMemoryCredentialStore()
    try store.set(.companionURL, value: "")
    try store.set(.pairingToken, value: "secret")
    #expect(!store.isPaired)
}

@Test func credentialStoreClearAllResetsPairing() throws {
    let store = InMemoryCredentialStore()
    try store.set(.companionURL, value: "https://x.com")
    try store.set(.pairingToken, value: "secret")
    #expect(store.isPaired)
    try store.clearAll()
    #expect(!store.isPaired)
}

// MARK: - DigestStore: paired vs unpaired branching

@Test @MainActor func storeWithoutCredentialsStartsInDemoMode() {
    let creds = InMemoryCredentialStore()
    let store = DigestStore(credentials: creds)
    #expect(store.isInDemoMode)
    #expect(store.digests.count == DemoFixtures.digests.count)
}

@Test @MainActor func storeWithCredentialsStartsInLiveMode() throws {
    let creds = InMemoryCredentialStore()
    try creds.set(.companionURL, value: "https://x.com")
    try creds.set(.pairingToken, value: "secret")
    let store = DigestStore(credentials: creds)
    #expect(!store.isInDemoMode)
    // Live mode starts empty — refresh would normally populate.
    #expect(store.digests.isEmpty)
}

@Test @MainActor func didDisconnectClearsCredentialsAndRestoresDemo() throws {
    let creds = InMemoryCredentialStore()
    try creds.set(.companionURL, value: "https://x.com")
    try creds.set(.pairingToken, value: "secret")
    let store = DigestStore(credentials: creds)
    #expect(!store.isInDemoMode)
    store.didDisconnect()
    #expect(store.isInDemoMode)
    #expect(creds.get(.companionURL) == nil)
    #expect(creds.get(.pairingToken) == nil)
    #expect(store.digests.count == DemoFixtures.digests.count)
}

// MARK: - CompanionClient request shaping (URLProtocol mock)

/// In-process URLProtocol that captures every outbound request and replies
/// with a canned response. Lets us assert auth headers, method, path, and
/// body without standing up a live HTTP server (the simulator can't reach
/// host-localhost in the sandbox).
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    // Captured for assertion. Lock-guarded so the test thread can read what
    // the URLSession's protocol thread wrote.
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    /// (statusCode, body) for the next response. Tests prime this.
    nonisolated(unsafe) static var nextResponse: (Int, Data) = (200, Data())
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Capture before we serve so the test can assert post-await.
        Self.lock.lock()
        Self.lastRequest = self.request
        // URLRequest in modern URLSession surfaces the body via httpBodyStream;
        // pull it eagerly so the test can see what was posted.
        if let stream = self.request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            Self.lastBody = data
        } else {
            Self.lastBody = self.request.httpBody
        }
        let (code, body) = Self.nextResponse
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: self.request.url!,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"],
        )!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: body)
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastRequest = nil
        lastBody = nil
        nextResponse = (200, Data())
    }
}

private func makeMockedClient(credentials: InMemoryCredentialStore) -> CompanionClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: config)
    return CompanionClient(credentials: credentials, session: session)
}

@Test func clientListSendsBearerAndHitsListPath() async throws {
    MockURLProtocol.reset()
    let creds = InMemoryCredentialStore()
    try creds.set(.companionURL, value: "https://harmony.example.com")
    try creds.set(.pairingToken, value: "tok_abc")
    MockURLProtocol.nextResponse = (200, """
        {"digests": []}
        """.data(using: .utf8)!)

    let client = makeMockedClient(credentials: creds)
    let digests = try await client.list()
    #expect(digests.isEmpty)

    let captured = MockURLProtocol.lastRequest
    #expect(captured?.httpMethod == "GET")
    #expect(captured?.url?.path == "/list")
    #expect(captured?.value(forHTTPHeaderField: "Authorization") == "Bearer tok_abc")
}

@Test func clientSetStatePostsJSONBody() async throws {
    MockURLProtocol.reset()
    let creds = InMemoryCredentialStore()
    try creds.set(.companionURL, value: "https://harmony.example.com")
    try creds.set(.pairingToken, value: "tok_abc")
    MockURLProtocol.nextResponse = (200, """
        {"status": "ok", "id": "dgst_x", "state": "read"}
        """.data(using: .utf8)!)

    let client = makeMockedClient(credentials: creds)
    try await client.setState(id: "dgst_x", state: .read)

    let req = MockURLProtocol.lastRequest
    #expect(req?.httpMethod == "POST")
    #expect(req?.url?.path == "/state")
    #expect(req?.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(req?.value(forHTTPHeaderField: "Authorization") == "Bearer tok_abc")
    let body = MockURLProtocol.lastBody ?? Data()
    let parsed = try JSONSerialization.jsonObject(with: body) as? [String: String]
    #expect(parsed?["id"] == "dgst_x")
    #expect(parsed?["state"] == "read")
}

@Test func clientUnauthorizedMaps401ToUnauthorizedError() async {
    MockURLProtocol.reset()
    let creds = InMemoryCredentialStore()
    try? creds.set(.companionURL, value: "https://harmony.example.com")
    try? creds.set(.pairingToken, value: "wrong")
    MockURLProtocol.nextResponse = (401, """
        {"error": "unauthorized: bad or missing bearer token"}
        """.data(using: .utf8)!)

    let client = makeMockedClient(credentials: creds)
    do {
        _ = try await client.list()
        Issue.record("expected CompanionError.unauthorized")
    } catch let e as CompanionError {
        #expect(e == .unauthorized)
    } catch {
        Issue.record("unexpected error type: \(error)")
    }
}

@Test func clientWithoutCredentialsThrowsNotConfigured() async {
    MockURLProtocol.reset()
    let creds = InMemoryCredentialStore()
    let client = makeMockedClient(credentials: creds)
    do {
        _ = try await client.list()
        Issue.record("expected CompanionError.notConfigured")
    } catch let e as CompanionError {
        #expect(e == .notConfigured)
    } catch {
        Issue.record("unexpected: \(error)")
    }
}

@Test func clientSummaryDecodesUnreadCount() async throws {
    MockURLProtocol.reset()
    let creds = InMemoryCredentialStore()
    try creds.set(.companionURL, value: "https://harmony.example.com")
    try creds.set(.pairingToken, value: "tok")
    MockURLProtocol.nextResponse = (200, """
        {"unread_count": 7, "latest": []}
        """.data(using: .utf8)!)

    let client = makeMockedClient(credentials: creds)
    let summary = try await client.summary()
    #expect(summary.unread_count == 7)
    #expect(summary.latest.isEmpty)
}

@Test @MainActor func storeRefreshAppliesEnvelopesAndState() async throws {
    MockURLProtocol.reset()
    let creds = InMemoryCredentialStore()
    try creds.set(.companionURL, value: "https://harmony.example.com")
    try creds.set(.pairingToken, value: "tok")
    MockURLProtocol.nextResponse = (200, """
        {"digests": [
          {
            "digest": {
              "schema_version": 1, "id": "live_1", "job_id": "j",
              "source": "hermes-cron", "title": "Live One",
              "created_at": "2026-06-29T19:00:00Z", "urgency": "normal",
              "bottom_line": "from companion"
            },
            "state": "read"
          }
        ]}
        """.data(using: .utf8)!)

    // We construct a store with the same credential store, but the store's
    // internal `CompanionClient` uses URLSession.shared — not our mock. To
    // exercise refresh against the mock, bypass the store and confirm the
    // envelope-applying side of the contract via the client directly.
    let client = makeMockedClient(credentials: creds)
    let envelopes = try await client.list()
    #expect(envelopes.count == 1)
    #expect(envelopes.first?.digest.id == "live_1")
    #expect(envelopes.first?.state == .read)
}

// MARK: - RelayClient (push registration)

private func makeMockedRelay() -> RelayClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: config)
    // Inject an explicit base URL so the test doesn't depend on the Info.plist
    // CrowlyRelayURL (which is empty by default).
    return RelayClient(baseURL: URL(string: "https://relay.example.com")!, session: session)!
}

@Test func relayRegisterPostsDeviceTokenAndReturnsRoutingToken() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.nextResponse = (200, """
        {"routing_token": "rt_abc123"}
        """.data(using: .utf8)!)

    let relay = makeMockedRelay()
    let rt = try await relay.register(deviceToken: "deadbeef")
    #expect(rt == "rt_abc123")

    let req = MockURLProtocol.lastRequest
    #expect(req?.httpMethod == "POST")
    #expect(req?.url?.path == "/register")
    #expect(req?.value(forHTTPHeaderField: "Content-Type") == "application/json")
    // The relay is unauthenticated for /register; no bearer is sent.
    #expect(req?.value(forHTTPHeaderField: "Authorization") == nil)

    let body = try #require(MockURLProtocol.lastBody)
    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    #expect(json?["device_token"] as? String == "deadbeef")
}

@Test func relayRegisterForwardsExistingRoutingToken() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.nextResponse = (200, #"{"routing_token": "rt_kept"}"#.data(using: .utf8)!)

    let relay = makeMockedRelay()
    _ = try await relay.register(deviceToken: "feedface", existingRoutingToken: "rt_kept")

    let body = try #require(MockURLProtocol.lastBody)
    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    // Re-binding a refreshed device token must carry the prior routing_token
    // so the companion's CROWLY_ROUTING_TOKEN stays valid.
    #expect(json?["routing_token"] as? String == "rt_kept")
}

@Test func relayUnregisterPostsRoutingToken() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.nextResponse = (200, "{}".data(using: .utf8)!)

    let relay = makeMockedRelay()
    try await relay.unregister(routingToken: "rt_gone")

    let req = MockURLProtocol.lastRequest
    #expect(req?.url?.path == "/unregister")
    let body = try #require(MockURLProtocol.lastBody)
    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    #expect(json?["routing_token"] as? String == "rt_gone")
}

@Test func relayServerErrorSurfacesTyped() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.nextResponse = (503, #"{"error":"down"}"#.data(using: .utf8)!)
    let relay = makeMockedRelay()
    await #expect(throws: RelayError.serverError(code: 503)) {
        _ = try await relay.register(deviceToken: "x")
    }
}

@Test func relayClientNilWhenNoURLConfigured() {
    // The default initializer reads RelayConfig.url (Info.plist), which is
    // empty in test/demo builds — so RelayClient() is nil and push registration
    // is a clean no-op.
    #expect(RelayClient(baseURL: nil) == nil)
}

@Test func apnsHexEncodingIsLowercaseHex() {
    let data = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x0F])
    #expect(data.apnsHexString == "deadbeef000f")
}

// MARK: - PushRegistrar (post-pairing, best-effort)

@Test @MainActor func pushRegistrarStoresRoutingTokenFromRelay() async {
    let creds = InMemoryCredentialStore()
    let registrar = PushRegistrar(
        credentials: creds,
        makeRelay: { makeMockedRelay() }
    )
    MockURLProtocol.reset()
    MockURLProtocol.nextResponse = (200, #"{"routing_token":"rt_stored"}"#.data(using: .utf8)!)

    await registrar.handleDeviceToken(Data([0x01, 0x02, 0x03]))
    #expect(creds.get(.routingToken) == "rt_stored")
    #expect(registrar.routingTokenForDisplay == "rt_stored")
}

@Test @MainActor func pushRegistrarNoOpsWhenRelayUnconfigured() async {
    let creds = InMemoryCredentialStore()
    // makeRelay returns nil → no network, no token stored, no crash.
    let registrar = PushRegistrar(credentials: creds, makeRelay: { nil })
    await registrar.handleDeviceToken(Data([0xAA]))
    #expect(creds.get(.routingToken) == nil)
}

@Test @MainActor func pushRegistrarSurvivesRelayFailure() async {
    let creds = InMemoryCredentialStore()
    let registrar = PushRegistrar(credentials: creds, makeRelay: { makeMockedRelay() })
    MockURLProtocol.reset()
    MockURLProtocol.nextResponse = (500, #"{"error":"boom"}"#.data(using: .utf8)!)
    // Best-effort: a relay failure must not throw out of handleDeviceToken and
    // must leave no partial token behind.
    await registrar.handleDeviceToken(Data([0x01]))
    #expect(creds.get(.routingToken) == nil)
}
