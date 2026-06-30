// KeychainStore — tiny wrapper around the Security framework's keychain for
// Crowly's companion credentials.
//
// What we persist:
//   - companion URL (the HTTPS base, e.g. `https://harmony.example.com`)
//   - pairing token (bearer for all authenticated endpoints)
//
// Why the keychain and not UserDefaults: the pairing token is a long-lived
// secret. The architecture (docs/architecture.md § Pairing) is explicit —
// "stores both in the Keychain." UserDefaults would round-trip through plist
// backups and iCloud sync without us asking.
//
// Item shape: a single generic password (`kSecClassGenericPassword`) per slot,
// keyed by a string account name. The bundle id is the service so a future
// share-extension or sibling app doesn't collide. `kSecAttrAccessible` is
// `WhenUnlockedThisDeviceOnly` — the token is per-device (it's bound to a
// specific companion pairing) and should not migrate via iCloud Keychain or
// be readable while the device is locked.
//
// Concurrency: SecItem* calls are thread-safe; this wrapper holds no state.

import Foundation
import Security

/// Errors surfaced by `KeychainStore`. We don't leak `OSStatus` codes to
/// callers — the pairing view only needs "did the write succeed."
enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case dataEncodingFailed
}

/// Slots we persist. New slots get a new case so the call sites stay readable.
enum KeychainKey: String {
    case companionURL    = "companion_url"
    case pairingToken    = "pairing_token"
}

/// Lightweight protocol so `DigestStore` and `CompanionClient` can be tested
/// without touching the real keychain. The default conformance lives on
/// `KeychainStore`; tests inject an in-memory implementation.
///
/// Sendable: both conforming types serialize reads/writes internally
/// (SecItem* is thread-safe; `InMemoryCredentialStore` uses an `NSLock`).
/// We mark the protocol Sendable so `CompanionClient` (also Sendable) can
/// store a reference.
protocol CredentialStore: AnyObject, Sendable {
    func get(_ key: KeychainKey) -> String?
    func set(_ key: KeychainKey, value: String) throws
    func delete(_ key: KeychainKey) throws
    func clearAll() throws
}

/// Real keychain-backed implementation. SecItem* is thread-safe; the only
/// mutable state we'd have is the bundle-id `service`, which is set once at
/// init — so straight `Sendable` is correct.
final class KeychainStore: CredentialStore {

    /// `kSecAttrService` — the bundle id by default so a future sibling
    /// (share extension, intents extension) doesn't fight us for the slot.
    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.crowly.Crowly") {
        self.service = service
    }

    // MARK: - CredentialStore

    func get(_ key: KeychainKey) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    func set(_ key: KeychainKey, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.dataEncodingFailed
        }

        // Upsert: try update first, fall through to add. SecItemUpdate is the
        // canonical way to overwrite without first deleting (deleting between
        // a stale read and a write would race a second writer).
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] =
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    func delete(_ key: KeychainKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        // Missing slot is fine — we want delete to be idempotent.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func clearAll() throws {
        for key in [KeychainKey.companionURL, .pairingToken] {
            try delete(key)
        }
    }

    // MARK: - Internals

    private func baseQuery(for key: KeychainKey) -> [String: Any] {
        [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}

// MARK: - In-memory store (tests, previews)

/// Drop-in replacement that keeps credentials in a dictionary. Used by unit
/// tests so they don't have to touch the real keychain (which requires an
/// entitlement on macOS and would persist between test runs).
final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var storage: [KeychainKey: String] = [:]
    private let lock = NSLock()

    func get(_ key: KeychainKey) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func set(_ key: KeychainKey, value: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }

    func delete(_ key: KeychainKey) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }

    func clearAll() throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}

// MARK: - Convenience

extension CredentialStore {
    /// True when both slots are populated and the URL parses. The store
    /// reads this on launch to decide between demo mode and live pull.
    var isPaired: Bool {
        guard let urlString = get(.companionURL),
              let token = get(.pairingToken),
              !urlString.isEmpty,
              !token.isEmpty,
              URL(string: urlString) != nil else {
            return false
        }
        return true
    }
}
