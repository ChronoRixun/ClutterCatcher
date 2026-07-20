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

    /// A resolved container scan, driving the §4 "Found it!" card
    /// (ScanSuccessCard owns the per-theme personality). Room payloads still
    /// navigate immediately (rooms have no card in the design), as do
    /// Camera-app deep links, which never pass through this screen.
    private struct ScanSuccess {
        let containerID: String
        let name: String
        let roomName: String
        let itemCount: Int
        /// Fresh per presentation — the entrance animation and the confetti
        /// one-shot guard key off it, so a re-scan is a new moment.
        let presentationID = UUID()
    }

    @Environment(\.appDatabase) private var appDatabase
    @Environment(Router.self) private var router
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.scenePhase) private var scenePhase

    @State private var scanProblem: ScanProblem?
    @State private var scanSuccess: ScanSuccess?
    @State private var confettiGuard = ConfettiGuard()
    /// Which presentation's confetti is in flight — owned here, like the
    /// guard, so it survives the card row being recreated mid-moment.
    @State private var confettiBurstID: UUID?
    @State private var manualEntry = ""
    @State private var cameraAccess: CameraAccess = .undetermined
    /// U1: dark-garage flashlight. The model is the testable logic; the
    /// hardware call lives in `Torch` and is applied only at this seam.
    @State private var torch = TorchModel(isAvailable: Torch.deviceHasTorch)

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
            #if DEBUG
            // M4b capture harness: auto-fire a scan on the sim, where
            // typing/pasting into the manual field is unreliable (DL27).
            // DEBUG-only and env-gated — inert everywhere else.
            if let code = ProcessInfo.processInfo.environment["CC_AUTOSCAN_CODE"] {
                let delay = Double(
                    ProcessInfo.processInfo.environment["CC_AUTOSCAN_DELAY"] ?? "") ?? 2
                try? await Task.sleep(for: .seconds(delay))
                handle(scanned: code)
            }
            #endif
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

    /// Pause while a problem or success card is up, and stop the capture
    /// session entirely when another tab is selected ("Open It Up" switches
    /// tabs — the camera must not stay live behind it).
    private var scannerIsActive: Bool {
        router.selectedTab == .scan && scanProblem == nil && scanSuccess == nil
    }

    private var scannerBody: some View {
        ZStack {
            DataScannerRepresentable(isActive: scannerIsActive) { payload in
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
                    VStack(spacing: Tokens.spacingS) {
                        // §5: Arcade's full presence puts the pixel sprite in
                        // Scan itself, keeping the viewfinder company.
                        if themeStore.theme.fenPresence == .fullSprite,
                           let fenColors = themeStore.theme.fenColors {
                            FenFigure(
                                colors: fenColors,
                                style: themeStore.theme.fenStyle,
                                glow: themeStore.theme.fenGlow)
                                .frame(height: 44)
                        }
                        Text("Point at a ClutterCatcher label")
                            .font(.callout)
                            .padding(.horizontal, Tokens.spacingL)
                            .padding(.vertical, Tokens.spacingS)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .padding(.bottom, Tokens.spacingL)
                }
            }
            .animation(cardEntranceAnimation, value: scanSuccess?.presentationID)
        }
        // U1: shown only on devices with a torch; themed like the hint pill.
        .overlay(alignment: .topTrailing) {
            if torch.buttonVisible {
                Button {
                    torch.toggle()
                    Torch.apply(on: torch.isOn)
                } label: {
                    Image(systemName: torch.isOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.title3)
                        .foregroundStyle(torch.isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .padding(Tokens.spacingM)
                        .background(.thinMaterial, in: Circle())
                }
                .padding(Tokens.spacingL)
                .accessibilityLabel(torch.isOn ? "Turn flashlight off" : "Turn flashlight on")
            }
        }
        // DL11 discipline, extended: the torch never outlives the scanner —
        // card up, tab away, or app backgrounded all turn it off.
        .onChange(of: scannerIsActive) { _, active in
            if !active { turnTorchOff() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { turnTorchOff() }
        }
    }

    private func turnTorchOff() {
        guard torch.isOn else { return }
        torch.scannerStopped()
        Torch.apply(on: false)
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
                        // §5: Arcade's pixel sprite keeps its Scan presence
                        // in the fallback too, same pattern as the empty
                        // states.
                        if themeStore.theme.fenPresence == .fullSprite,
                           let fenColors = themeStore.theme.fenColors {
                            VStack(spacing: Tokens.spacingM) {
                                FenFigure(
                                    colors: fenColors,
                                    style: themeStore.theme.fenStyle,
                                    glow: themeStore.theme.fenGlow)
                                    .frame(height: 72)
                                Text("Camera Scanning Unavailable")
                            }
                        } else {
                            Label("Camera Scanning Unavailable", systemImage: "qrcode.viewfinder")
                        }
                    } description: {
                        Text("\(reason) Paste a label code below instead — either the cluttercatcher:// link or the bare UUID.")
                    }
                }
            }
            Section("Label code") {
                // U5: household English — the parser still takes the full
                // cluttercatcher:// form or a bare UUID, unchanged.
                TextField("Type the code from the label", text: $manualEntry)
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
        .animation(cardEntranceAnimation, value: scanSuccess?.presentationID)
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

    // MARK: Card entrance (§6 M4b)

    /// nil for Classic and Dusk Redux — their "standard transition" is the
    /// card presenting exactly as it did in M4a, and nil also disables any
    /// inherited animation (motion's structural no-op).
    private var cardEntranceAnimation: Animation? {
        guard themeStore.theme.motion.cardEntrance != nil else { return nil }
        return themeStore.theme.motion.animation(.cardEntrance, reduceMotion: reduceMotion)
    }

    /// §4: the full-card scan-success state. ScanSuccessCard carries the
    /// per-theme reward personality; "Scan Again" remains the not-that-bin
    /// escape (DL57 — semantics unchanged).
    @ViewBuilder
    private func successCard(for success: ScanSuccess) -> some View {
        let card = ScanSuccessCard(
            name: success.name,
            roomName: success.roomName,
            itemCount: success.itemCount,
            presentationID: success.presentationID,
            confettiGuard: $confettiGuard,
            confettiBurstID: $confettiBurstID,
            onOpen: {
                scanSuccess = nil
                router.navigate(to: .container(id: success.containerID))
            },
            onScanAgain: {
                scanSuccess = nil
            })
            .padding(Tokens.spacingL)
        if cardEntranceAnimation == nil {
            card
        } else if reduceMotion {
            card.transition(.opacity)
        } else {
            card.transition(.scale(scale: 0.85).combined(with: .opacity))
        }
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
