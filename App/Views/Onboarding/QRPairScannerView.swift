// QRPairScannerView — camera QR scanning for pairing.
//
// The companion prints a pairing QR encoding the same JSON its `/pair` endpoint
// returns: `{"companion_url": "...", "pairing_token": "..."}`. This view wraps
// VisionKit's DataScannerViewController, recognizes a QR, parses that payload,
// and hands the two fields back so PairCompanionView can fill the form and
// validate — the secret still flows scan → form → validate → Keychain, never
// off the device.
//
// Graceful degradation is the rule: DataScanner needs a real camera + a
// supported device. On the Simulator (and headless cloud devices) it isn't
// available — this view shows an unavailable state pointing back at manual
// entry, which stays the always-works path. Camera permission is requested via
// NSCameraUsageDescription (declared in project.yml).

import SwiftUI
import VisionKit

struct QRPairScannerView: View {
    /// Delivered on a successful scan+parse. PairCompanionView writes these
    /// into its URL/token fields and kicks off validation.
    let onScan: (_ companionURL: String, _ token: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var parseError: String?

    private var scannerAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            Group {
                if scannerAvailable {
                    scanner
                } else {
                    unavailable
                }
            }
            .navigationTitle("Scan pairing QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var scanner: some View {
        ZStack(alignment: .bottom) {
            DataScannerRepresentable { payload in
                handle(payload)
            }
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: Space.s) {
                if let parseError {
                    Label(parseError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(Space.m)
                        .background(Capsule().fill(.black.opacity(0.6)))
                } else {
                    Text("Point at the QR your companion printed.")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(Space.m)
                        .background(Capsule().fill(.black.opacity(0.5)))
                }
            }
            .padding(.bottom, Space.xxl)
        }
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label("Camera unavailable", systemImage: "qrcode.viewfinder")
        } description: {
            Text("This device can't scan a QR here. Enter your companion's URL and token by hand instead.")
        } actions: {
            Button("Enter manually") { dismiss() }
                .buttonStyle(.crowlyPrimary)       // flat orange brand pill
        }
    }

    /// Parse the QR text as the companion pairing payload. Tolerant of extra
    /// fields; requires both `companion_url` and `pairing_token`.
    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = obj["companion_url"] as? String, !url.isEmpty,
              let token = obj["pairing_token"] as? String, !token.isEmpty
        else {
            parseError = "That QR isn't a Crowly pairing code."
            return
        }
        parseError = nil
        onScan(url, token)
        dismiss()
    }
}

// MARK: - VisionKit bridge

/// UIViewControllerRepresentable wrapper around DataScannerViewController,
/// filtering to QR codes and reporting the first payload string.
private struct DataScannerRepresentable: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        try? scanner.startScanning()
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (String) -> Void
        /// Fire once — a QR sits in frame for many delegate callbacks.
        private var fired = false

        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !fired else { return }
            for item in addedItems {
                if case let .barcode(barcode) = item, let payload = barcode.payloadStringValue {
                    fired = true
                    onFound(payload)
                    return
                }
            }
        }
    }
}
