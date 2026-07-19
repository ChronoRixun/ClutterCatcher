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

    /// A scan that couldn't resolve — drives the overlay card. Two flavors:
    /// the code genuinely isn't in the catalog, or the lookup itself threw
    /// (the scanner must never die silently on a DB error).
    private enum ScanProblem {
        case notFound(scanned: String)
        case lookupFailed
    }

    /// A resolved container scan, driving the §4 "Found it!" card. The card
    /// is the static M4a version; its pop/confetti/Fen-peek personality is
    /// M4b. Room payloads still navigate immediately (rooms have no card in
    /// the design), as do Camera-app deep links, which never pass through
    /// this screen.
    private struct ScanSuccess {
        let containerID: String
        let name: String
        let roomName: String
        let itemCount: Int
    }

    @Environment(\.appDatabase) private var appDatabase
    @Environment(Router.self) private var router
    @Environment(ThemeStore.self) private var themeStore

    @State private var scanProblem: ScanProblem?
    @State private var scanSuccess: ScanSuccess?
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
            // Pause while a problem or success card is up, and stop the
            // capture session entirely when another tab is selected ("Open
            // It Up" switches tabs — the camera must not stay live behind
            // it).
            DataScannerRepresentable(
                isActive: router.selectedTab == .scan && scanProblem == nil && scanSuccess == nil
            ) { payload in
                handle(scanned: payload)
            }
            .ignoresSafeArea()

            VStack {
                Spacer()
                if let scanSuccess {
                    successCard(for: scanSuccess)
                } else if let scanProblem {
                    problemCard(for: scanProblem)
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
            // The result card takes the notice's slot — once a lookup has
            // resolved, the "camera unavailable" explanation is noise, and
            // at the bottom the card would hide behind the tab bar.
            if let scanSuccess {
                Section {
                    successCard(for: scanSuccess)
                        .listRowBackground(Color.clear)
                }
            } else if let scanProblem {
                Section {
                    problemCard(for: scanProblem)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ContentUnavailableView {
                        Label("Camera Scanning Unavailable", systemImage: "qrcode.viewfinder")
                    } description: {
                        Text("\(reason) Paste a label code below instead — either the cluttercatcher:// link or the bare UUID.")
                    }
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
            .themedRow()
        }
        .themedScreen()
    }

    // MARK: Resolution

    private func handle(scanned payload: String) {
        guard let parsed = QRPayload.parse(scanned: payload) else {
            scanProblem = .notFound(scanned: payload)
            return
        }
        let database = appDatabase
        Task {
            do {
                switch parsed {
                case .container(let uuid):
                    let id = uuid.uuidString
                    let success: ScanSuccess? = try await database.writer.read { db in
                        guard let container = try Container.fetchOne(db, key: id) else {
                            return nil
                        }
                        let roomName = try String.fetchOne(
                            db, sql: "SELECT name FROM rooms WHERE id = ?",
                            arguments: [container.roomId]) ?? ""
                        let itemCount = try Int.fetchOne(
                            db, sql: "SELECT COUNT(*) FROM items WHERE container_id = ?",
                            arguments: [id]) ?? 0
                        return ScanSuccess(
                            containerID: id, name: container.name,
                            roomName: roomName, itemCount: itemCount)
                    }
                    if let success {
                        scanProblem = nil
                        manualEntry = ""
                        scanSuccess = success
                    } else {
                        scanProblem = .notFound(scanned: payload)
                    }
                case .room(let uuid):
                    let id = uuid.uuidString
                    let exists = try await database.writer.read { db in
                        try Room.exists(db, key: id)
                    }
                    if exists {
                        scanProblem = nil
                        manualEntry = ""
                        router.navigate(to: .room(id: id))
                    } else {
                        scanProblem = .notFound(scanned: payload)
                    }
                }
            } catch {
                Log.data.error("Scan lookup failed: \(String(describing: error))")
                scanProblem = .lookupFailed
            }
        }
    }

    /// §4: the full-card scan-success state — static in M4a, personality in
    /// M4b. "Scan Again" is the not-that-bin escape; without it the paused
    /// scanner would have no way back.
    private func successCard(for success: ScanSuccess) -> some View {
        VStack(spacing: Tokens.spacingM) {
            Text("Found it!")
                .font(.title2.bold())
            Text("\(success.name) · \(success.roomName) · ^[\(success.itemCount) item](inflect: true)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open It Up") {
                scanSuccess = nil
                router.navigate(to: .container(id: success.containerID))
            }
            .buttonStyle(.borderedProminent)
            Button("Scan Again") {
                scanSuccess = nil
            }
            .font(.subheadline)
        }
        .padding(Tokens.spacingL)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Tokens.cornerRadius))
        .padding(Tokens.spacingL)
    }

    private func problemCard(for problem: ScanProblem) -> some View {
        VStack(spacing: Tokens.spacingM) {
            switch problem {
            case .notFound(let scanned):
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
            case .lookupFailed:
                Label("Couldn't Look That Up", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text("Something went wrong reading your catalog — try again.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Scan Again") {
                scanProblem = nil
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(Tokens.spacingL)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Tokens.cornerRadius))
        .padding(Tokens.spacingL)
    }
}
