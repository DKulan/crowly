// Auto-refresh reentrancy tests for `DigestStore.refresh()`.
//
// What we prove here:
//   - The `isRefreshing` guard drops an overlapping refresh: two concurrent
//     `refresh()` calls result in exactly ONE network `/list` request. This is
//     the guard that keeps the foreground poll (ContentView's
//     `.task(id: scenePhase)` loop) from racing a manual pull-to-refresh and
//     letting a stale snapshot clobber a fresher one.
//   - Positive control: a single live `refresh()` actually applies the
//     companion's snapshot (so the count assertion above isn't passing because
//     the transport is dead).
//
// Seam note: `DigestStore` builds its own `CompanionClient` internally, and
// that client uses `URLSession.shared` (there's no session/client injection
// point). To intercept the store's real network path without a live server we
// register a counting `URLProtocol` *globally* via `URLProtocol.registerClass`
// — `URLSession.shared` consults globally-registered protocol classes — and
// unregister it in a `defer`. This is deliberately scoped to these tests so it
// can't leak into the rest of the suite. The existing `MockURLProtocol`
// (CompanionClientTests) rides on a custom ephemeral session and so can't see
// `.shared`; hence a separate, self-contained protocol here.

import Testing
import Foundation
@testable import Crowly

/// Counts every request that reaches the transport and serves a canned
/// `/list` body. Registered globally for the lifetime of a single test so it
/// intercepts the `URLSession.shared` used by `DigestStore`'s internal
/// `CompanionClient`.
final class CountingListURLProtocol: URLProtocol, @unchecked Sendable {
    /// Number of requests that started loading. Guarded so the test thread can
    /// read what the URLSession's protocol thread wrote.
    nonisolated(unsafe) static var requestCount = 0
    /// If set, `startLoading` blocks on this before responding — used to hold
    /// the first refresh's `list()` in flight while a second refresh races it.
    nonisolated(unsafe) static var gate: DispatchSemaphore?
    static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        requestCount = 0
        gate = nil
    }

    static var count: Int {
        lock.lock(); defer { lock.unlock() }
        return requestCount
    }

    override class func canInit(with request: URLRequest) -> Bool {
        // Only intercept the companion's /list — leave anything else alone.
        request.url?.path == "/list"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        let gate = Self.gate
        Self.lock.unlock()

        // Hold the in-flight request open so an overlapping refresh has a real
        // window to race into. Without the guard, the second refresh would
        // reach this point and bump the count to 2.
        gate?.wait()

        let body = """
        {"digests": [
          {
            "digest": {
              "schema_version": 1, "id": "live_guard_1", "job_id": "j",
              "source": "hermes-cron", "title": "Guard One",
              "created_at": "2026-06-29T19:00:00Z", "urgency": "normal",
              "bottom_line": "from companion"
            },
            "state": "unread"
          }
        ]}
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"],
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Build a paired live-mode `DigestStore`. Its internal `CompanionClient`
/// targets `URLSession.shared`, which is what `CountingListURLProtocol`
/// intercepts once registered.
@MainActor
private func makeLiveStore() throws -> DigestStore {
    let creds = InMemoryCredentialStore()
    try creds.set(.companionURL, value: "https://harmony.example.com")
    try creds.set(.pairingToken, value: "tok_guard")
    let store = DigestStore(credentials: creds)
    #expect(!store.isInDemoMode)
    return store
}

@Test @MainActor func refreshGuardDropsOverlappingRefresh() async throws {
    URLProtocol.registerClass(CountingListURLProtocol.self)
    defer { URLProtocol.unregisterClass(CountingListURLProtocol.self) }
    CountingListURLProtocol.reset()

    // Hold the first refresh's /list open so the second refresh overlaps it.
    let gate = DispatchSemaphore(value: 0)
    CountingListURLProtocol.gate = gate

    let store = try makeLiveStore()

    // Kick off the first refresh. It hops to the main actor, flips
    // `isRefreshing = true`, then suspends awaiting the (gated) /list.
    async let first: Void = store.refresh()

    // Give the first refresh a beat to actually enter `refresh()` and set the
    // guard + start the request before we fire the second. We poll on the
    // request count rather than sleeping blindly so the test isn't timing-fragile.
    var spins = 0
    while CountingListURLProtocol.count < 1 && spins < 500 {
        try await Task.sleep(for: .milliseconds(2))
        spins += 1
    }
    #expect(CountingListURLProtocol.count == 1, "first refresh should have started exactly one /list")

    // Second refresh while the first is still in flight — the guard must drop it.
    await store.refresh()

    // Release the first refresh and let it finish.
    gate.signal()
    await first

    // The overlapping call was dropped, so only ONE /list ever hit the wire.
    #expect(CountingListURLProtocol.count == 1, "overlapping refresh must be dropped by the isRefreshing guard")
    // And the guard reset — a later refresh can still run.
    #expect(store.digests.count == 1)
    #expect(store.digests.first?.id == "live_guard_1")
}

@Test @MainActor func singleRefreshAppliesCompanionSnapshot() async throws {
    // Positive control: proves the counting transport actually feeds the store,
    // so the "== 1" assertion above isn't green because nothing hit the wire.
    URLProtocol.registerClass(CountingListURLProtocol.self)
    defer { URLProtocol.unregisterClass(CountingListURLProtocol.self) }
    CountingListURLProtocol.reset()
    CountingListURLProtocol.gate = nil // no gating — respond immediately

    let store = try makeLiveStore()
    #expect(store.digests.isEmpty)

    await store.refresh()

    #expect(CountingListURLProtocol.count == 1)
    #expect(store.digests.count == 1)
    #expect(store.digests.first?.id == "live_guard_1")
    #expect(store.digestState(for: "live_guard_1") == .unread)
    #expect(store.lastRefreshError == nil)

    // A second, sequential (non-overlapping) refresh is allowed — the guard
    // only drops *concurrent* calls, not later ones.
    await store.refresh()
    #expect(CountingListURLProtocol.count == 2)
}
