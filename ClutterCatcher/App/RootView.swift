import SwiftUI

struct RootView: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
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
