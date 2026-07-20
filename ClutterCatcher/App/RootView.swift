import CoreSpotlight
import SwiftUI

struct RootView: View {
    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var appModel
    @Environment(SyncStatusModel.self) private var syncStatus
    @Environment(ThemeStore.self) private var themeStore
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
        // T6: SF Pro Rounded everywhere, all themes including Classic. T5/T1:
        // the tint is the only global color hook — Classic's is nil, leaving
        // the asset-catalog AccentColor in charge exactly as before M4.
        .fontDesign(.rounded)
        .tint(themeStore.theme.tint)
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
        // U8: a tapped Spotlight result. Its identifier IS its deep link, so
        // this is the same DL5 stack-replacing path a QR scan takes (with
        // U14's highlight riding the item results' query string).
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  let url = URL(string: identifier) else {
                return
            }
            router.open(url: url)
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
        // M6.2: iPad gets the native sidebar/top-bar tab treatment; iPhone
        // renders exactly the bottom tab bar it always had.
        .tabViewStyle(.sidebarAdaptable)
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
    // NOTE (M7b): a DL5 stack-replace can swap one route for another at the
    // same stack position, which KEEPS the destination view's structural
    // identity — plain `.task {}` observations and @State silently survive
    // into the new route and the screen keeps showing the old destination.
    // (Found in the M7b walkthrough: two successive item deep links; latent
    // on main for Camera-scan-while-on-a-container.) The destination views
    // therefore key their observation tasks to their entity id
    // (`.task(id:)`) and reset their loaded state when it changes. An
    // `.id(route)` here would be the cleaner fix, but it segfaults the
    // iOS 26.5 sim runtime's metadata instantiation (the DL62 family).
    func catalogDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .room(let id):
                RoomDetailView(roomID: id)
            case .container(let id, let highlightItemID):
                ContainerDetailView(containerID: id, highlightItemID: highlightItemID)
            case .category(let id):
                CategoryBrowseView(categoryID: id)
            }
        }
    }
}
