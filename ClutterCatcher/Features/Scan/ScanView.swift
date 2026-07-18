import AVFoundation
import SwiftUI
import VisionKit

/// Scan a printed label to jump to its container. Accepts the
/// `cluttercatcher://c/<uuid>` payload or a bare UUID (plan §3.4). Falls back
/// to manual code entry when live scanning can't run (simulator, or camera
/// access denied).
struct ScanView: View {
    private enum CameraAccess {
        case undetermined, granted, denied
    }

    @Environment(\.appDatabase) private var appDatabase
    @Environment(Router.self) private var router

    /// A scan that resolved to nothing — drives the not-found overlay.
    @State private var unknownScan: String?
    @State private var manualEntry = ""
    @State private var cameraAccess: CameraAccess = .undetermined

    var body: some View {
        NavigationStack {
            Group {
                if !DataScannerViewController.isSupported {
                    manualEntryBody(
                        reason: "Live scanning needs a device camera.")
                } else {
                    switch cameraAccess {
                    case .undetermined:
                        ProgressView()
                    case .granted:
                        scannerBody
                    case .denied:
                        manualEntryBody(
                            reason: "Camera access is off for ClutterCatcher — enable it in Settings to scan labels.")
                    }
                }
            }
            .navigationTitle("Scan")
        }
        .task {
            await requestCameraAccessIfNeeded()
        }
    }

    private func requestCameraAccessIfNeeded() async {
        guard DataScannerViewController.isSupported else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraAccess = .granted
        case .notDetermined:
            cameraAccess = await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        default:
            cameraAccess = .denied
        }
    }

    // MARK: Camera path (hardware)

    private var scannerBody: some View {
        ZStack {
            // Pause while a not-found overlay is up, and stop the capture
            // session entirely when another tab is selected (a successful
            // scan switches tabs — the camera must not stay live behind it).
            DataScannerRepresentable(
                isActive: router.selectedTab == .scan && unknownScan == nil
            ) { payload in
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

    // MARK: Manual path

    private func manualEntryBody(reason: String) -> some View {
        Form {
            Section {
                ContentUnavailableView {
                    Label("Camera Scanning Unavailable", systemImage: "qrcode.viewfinder")
                } description: {
                    Text("\(reason) Paste a label code below instead — either the cluttercatcher:// link or the bare UUID.")
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
                Log.data.error("Scan lookup failed: \(String(describing: error))")
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
