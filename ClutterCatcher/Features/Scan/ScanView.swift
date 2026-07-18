import SwiftUI
import VisionKit

/// Scan a printed label to jump to its container. Accepts the
/// `cluttercatcher://c/<uuid>` payload or a bare UUID (plan §3.4). On
/// simulators (no camera scanning) a manual-entry field stands in.
struct ScanView: View {
    @Environment(\.appDatabase) private var appDatabase
    @Environment(Router.self) private var router

    /// A scan that resolved to nothing — drives the not-found overlay.
    @State private var unknownScan: String?
    @State private var manualEntry = ""

    private var scannerAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            Group {
                if scannerAvailable {
                    scannerBody
                } else {
                    manualEntryBody
                }
            }
            .navigationTitle("Scan")
        }
    }

    // MARK: Camera path (hardware)

    private var scannerBody: some View {
        ZStack {
            DataScannerRepresentable(isActive: unknownScan == nil) { payload in
                handle(scanned: payload)
            }
            .ignoresSafeArea()

            VStack {
                Spacer()
                if let unknownScan {
                    notFoundCard(scanned: unknownScan)
                } else {
                    Text("Point at a ClutterCatcher label")
                        .font(.callout)
                        .padding(.horizontal, Tokens.spacingL)
                        .padding(.vertical, Tokens.spacingS)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, Tokens.spacingL)
                }
            }
        }
    }

    // MARK: Manual path (simulator, or camera unavailable)

    private var manualEntryBody: some View {
        Form {
            Section {
                ContentUnavailableView {
                    Label("Camera Scanning Unavailable", systemImage: "qrcode.viewfinder")
                } description: {
                    Text("Live scanning needs a device camera. Paste a label code below instead — either the cluttercatcher:// link or the bare UUID.")
                }
            }
            Section("Label code") {
                TextField("cluttercatcher://c/… or UUID", text: $manualEntry)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Button("Look Up") {
                    handle(scanned: manualEntry)
                }
                .disabled(manualEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let unknownScan {
                Section {
                    notFoundCard(scanned: unknownScan)
                        .listRowBackground(Color.clear)
                }
            }
        }
    }

    // MARK: Resolution

    private func handle(scanned payload: String) {
        guard let parsed = QRPayload.parse(scanned: payload) else {
            unknownScan = payload
            return
        }
        let database = appDatabase
        Task {
            do {
                let route: Route? = try await database.writer.read { db in
                    switch parsed {
                    case .container(let uuid):
                        let id = uuid.uuidString
                        return try Container.exists(db, key: id) ? .container(id: id) : nil
                    case .room(let uuid):
                        let id = uuid.uuidString
                        return try Room.exists(db, key: id) ? .room(id: id) : nil
                    }
                }
                if let route {
                    unknownScan = nil
                    manualEntry = ""
                    router.navigate(to: route)
                } else {
                    unknownScan = payload
                }
            } catch {
                Log.data.error("Scan lookup failed: \(error)")
            }
        }
    }

    private func notFoundCard(scanned: String) -> some View {
        VStack(spacing: Tokens.spacingM) {
            Label("Not in Your Catalog", systemImage: "questionmark.square.dashed")
                .font(.headline)
            Text("This code isn't linked to anything in your catalog. It may have been deleted, or it isn't a ClutterCatcher label.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(scanned)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Button("Scan Again") {
                unknownScan = nil
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(Tokens.spacingL)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Tokens.cornerRadius))
        .padding(Tokens.spacingL)
    }
}
