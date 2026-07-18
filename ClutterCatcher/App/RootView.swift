import SwiftUI

struct RootView: View {
    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var appModel
    @Environment(SyncStatusModel.self) private var syncStatus
    // A stable reference to the singleton; @Observable tracking makes its
    // phase changes re-render this view.
    @State private var acceptance = ShareAcceptanceModel.shared

    var body: some View {
        Group {
            switch appModel.bootstrapState {
            case .needsOnboarding:
                OnboardingView()
            case .joinPending:
                JoinWaitingView()
            case .ready:
                catalogTabs
            }
        }
        .confirmationDialog(
            "Join this household?",
            isPresented: Binding(
                get: { acceptance.phase == .confirming },
                set: { if !$0 { acceptance.cancelJoin() } }),
            titleVisibility: .visible
        ) {
            Button("Join and Replace Catalog", role: .destructive) {
                acceptance.confirmJoin()
            }
            Button("Cancel", role: .cancel) {
                acceptance.cancelJoin()
            }
        } message: {
            Text("Joining replaces this device's catalog with the household's.")
        }
        .alert(
            "Couldn't Join",
            isPresented: Binding(
                get: {
                    if case .failed = acceptance.phase { return true }
                    return false
                },
                set: { if !$0 { acceptance.dismissFailure() } })
        ) {
            Button("OK", role: .cancel) { acceptance.dismissFailure() }
        } message: {
            if case .failed(let message) = acceptance.phase {
                Text(message)
            }
        }
        .overlay {
            if acceptance.phase == .joining {
                JoiningOverlay()
            }
        }
    }

    private var catalogTabs: some View {
        @Bindable var router = router
        return TabView(selection: $router.selectedTab) {
            Tab("Rooms", systemImage: "square.grid.2x2", value: AppTab.rooms) {
                RoomsHomeView()
            }
            Tab("Scan", systemImage: "qrcode.viewfinder", value: AppTab.scan) {
                ScanView()
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                SearchView()
            }
            Tab("Family", systemImage: "person.3", value: AppTab.family) {
                FamilyView()
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // Persistent participant-degradation banner (M3-E): sync is off,
            // the catalog is safe locally, Family has the way back in.
            if syncStatus.phase == .disconnected {
                DisconnectedBanner()
            }
        }
        .alert(
            "Unrecognized Link",
            isPresented: Binding(
                get: { router.rejectedDeepLink != nil },
                set: { if !$0 { router.rejectedDeepLink = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That ClutterCatcher link doesn't look like one of our QR labels.")
        }
    }
}

private struct DisconnectedBanner: View {
    var body: some View {
        HStack(spacing: Tokens.spacingS) {
            Image(systemName: "icloud.slash")
            Text("No longer connected to the household")
                .font(.footnote.weight(.medium))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.spacingS)
        .background(.red.opacity(0.85), in: Rectangle())
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

private struct JoiningOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: Tokens.spacingM) {
                ProgressView()
                Text("Joining household…")
                    .font(.headline)
                Text("Fetching the shared catalog from iCloud.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(Tokens.spacingL)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// The shared destination table for catalog routes. Every `NavigationStack`
/// that can show rooms/containers applies this once.
extension View {
    func catalogDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .room(let id):
                RoomDetailView(roomID: id)
            case .container(let id):
                ContainerDetailView(containerID: id)
            }
        }
    }
}
