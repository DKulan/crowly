// PairCompanionView — manual companion pairing entry.
//
// Per docs/ux.md § Onboarding: the camera scanner reads a QR encoding
// `{companion_url, pairing_token}` (M1 stub — camera isn't headless-testable),
// with a "Enter URL and token instead" fallback that is the path verified
// in M1 (manual entry is the must-have; QR scan is post-M1).
//
// What this view owns:
//   - Two text fields (URL + token)
//   - A "Validate" tap that:
//       1. Normalizes the URL (CompanionClient.normalize)
//       2. Writes a candidate URL + token into a *throwaway* keychain wrapper
//       3. Calls `/health` and `/list` to prove the combo really is a Crowly
//          companion with this token
//       4. On success, writes them to the real keychain and calls
//          `store.didPair()` so the inbox swaps from demo to live
//   - Surfaces typed errors (unreachable / unauthorized / decode) as inline
//     copy beneath the form rather than alerts — the user is going to retry
//     and the inline path is easier to read.
//
// Style: matches the existing design system (Tokens, .crowlySurface, .glass
// buttons). iOS 26 / Liquid Glass.

import SwiftUI

struct PairCompanionView: View {
    @Environment(DigestStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var urlField: String = ""
    @State private var tokenField: String = ""
    @State private var status: PairStatus = .idle

    /// Hidden in M1 but wired for a follow-up. The QR path needs camera
    /// permissions and on-device interaction; we structure the entry point
    /// here so adding `AVFoundation` later doesn't require rearranging the
    /// view tree.
    @State private var showQRScanner: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    explainer
                } header: {
                    EmptyView()
                }
                .listRowBackground(Color.clear)

                Section("Companion URL") {
                    TextField("https://harmony.example.com", text: $urlField)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .submitLabel(.next)
                }

                Section("Pairing token") {
                    SecureField("pairing_token from your companion", text: $tokenField)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                }

                if let message = status.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                            .listRowBackground(Color.crowlySurfaceElevated)
                    }
                }

                if status.isSuccess {
                    Section {
                        Label("Paired. Pulling your inbox…", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                            .listRowBackground(Color.crowlySurfaceElevated)
                    }
                }

                Section {
                    Button {
                        Task { await validateAndPair() }
                    } label: {
                        HStack(spacing: Space.s) {
                            if status.isValidating {
                                ProgressView().controlSize(.small)
                            }
                            Text(status.isValidating ? "Validating…" : "Connect")
                                .font(.body.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)             // [iOS 26]
                    .disabled(!canSubmit)
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Connect inbox")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Color.crowlyBackground)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    // QR scan entry is intentionally non-functional in M1 —
                    // the manual path is the verified one. Surfacing the
                    // button keeps the affordance discoverable.
                    Button {
                        showQRScanner = true
                    } label: {
                        Label("Scan QR", systemImage: "qrcode.viewfinder")
                    }
                    .disabled(true)
                    .accessibilityHint("Camera-based pairing arrives in M2.")
                }
            }
            .sheet(isPresented: $showQRScanner) {
                // Stubbed for M2. ContentUnavailableView keeps the UI honest.
                ContentUnavailableView(
                    "QR pairing coming soon",
                    systemImage: "qrcode",
                    description: Text("For now, enter your companion URL and token by hand.")
                )
                .presentationDetents([.medium])
            }
        }
    }

    // MARK: - Subviews

    private var explainer: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Point Crowly at your companion.")
                .font(.headline)
            Text("After `docker compose up`, your companion prints a pairing payload — paste its URL and token here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Space.xs)
    }

    private var canSubmit: Bool {
        !urlField.trimmingCharacters(in: .whitespaces).isEmpty
            && !tokenField.trimmingCharacters(in: .whitespaces).isEmpty
            && !status.isValidating
    }

    // MARK: - Pair flow

    /// Validate the URL+token combo end-to-end before persisting. Strategy:
    /// stash the candidate credentials in a *throwaway* in-memory store,
    /// build a client off that, hit `/health` (proves the server is a Crowly
    /// companion) then `/list` (proves the bearer token is the right one),
    /// and only on both successes write to the real keychain. This way a
    /// failed pair never leaves stale creds in the keychain to confuse a
    /// retry — and the user keeps demo mode until the validation passes.
    @MainActor
    private func validateAndPair() async {
        guard let normalized = CompanionClient.normalize(url: urlField) else {
            status = .failed("That doesn't look like a valid URL.")
            return
        }
        let token = tokenField.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else {
            status = .failed("Enter your pairing token.")
            return
        }

        status = .validating

        // Throwaway probe — same logic as the real client, but reads from a
        // local store so we don't touch the keychain until we know it works.
        let probe = InMemoryCredentialStore()
        try? probe.set(.companionURL, value: normalized)
        try? probe.set(.pairingToken, value: token)
        let probeClient = CompanionClient(credentials: probe)

        do {
            _ = try await probeClient.health()
            // Authed call proves the bearer is right. We toss the result —
            // the real refresh happens after `didPair()`.
            _ = try await probeClient.list()
        } catch let error as CompanionError {
            status = .failed(error.userFacingMessage)
            return
        } catch {
            status = .failed("Couldn't reach the companion: \(error.localizedDescription)")
            return
        }

        // Validation passed — commit to the keychain and tell the store.
        // We pull the credential store off the existing client path through
        // DigestStore.didPair (it owns its KeychainStore); to keep things
        // simple here we write through a fresh KeychainStore (same keychain
        // service, same slots).
        let keychain = KeychainStore()
        do {
            try keychain.set(.companionURL, value: normalized)
            try keychain.set(.pairingToken, value: token)
        } catch {
            status = .failed("Couldn't save credentials to Keychain: \(error.localizedDescription)")
            return
        }

        status = .succeeded
        await store.didPair()
        dismiss()
    }
}

// MARK: - Status

/// State machine for the pair view. Drives the spinner / inline message.
private enum PairStatus: Equatable {
    case idle
    case validating
    case succeeded
    case failed(String)

    var isValidating: Bool { if case .validating = self { true } else { false } }
    var isSuccess: Bool { if case .succeeded = self { true } else { false } }
    var errorMessage: String? { if case .failed(let m) = self { m } else { nil } }
}

// MARK: - CompanionError → user copy

private extension CompanionError {
    /// Inline copy for the pair form. Short, actionable, no jargon.
    var userFacingMessage: String {
        switch self {
        case .unreachable(let underlying):
            return "Couldn't reach the companion: \(underlying)"
        case .unauthorized:
            return "That token didn't match. Double-check the pairing payload from your companion."
        case .clientError(let code, let message):
            if let message { return "Server rejected the request (\(code)): \(message)" }
            return "Server rejected the request (\(code))."
        case .serverError(let code):
            return "The companion returned a \(code). Try again in a moment."
        case .invalidResponse:
            return "The URL responded, but not with what a Crowly companion sends."
        case .decodingFailed:
            return "The response didn't look like a Crowly companion. Check the URL."
        case .notConfigured:
            return "Enter both a URL and a pairing token."
        }
    }
}

#Preview {
    PairCompanionView()
        .environment(DigestStore(credentials: InMemoryCredentialStore()))
}
