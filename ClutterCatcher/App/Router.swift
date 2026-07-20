import Foundation
import Observation
import SwiftUI

enum AppTab: Hashable {
    case rooms, scan, search, family, settings
}

/// App-wide navigation state: the selected tab and the catalog stack's path.
/// Deep links land here from `onOpenURL`; the scanner routes through
/// `navigate(to:)` after resolving a payload.
@MainActor
@Observable
final class Router {
    var selectedTab: AppTab = .rooms
    var catalogPath: [Route] = []

    /// A `cluttercatcher://` URL that didn't parse; RootView surfaces it.
    var rejectedDeepLink: URL?

    /// Handles an incoming URL. A recognized payload switches to the Rooms
    /// tab and shows the destination (an unknown UUID still navigates — the
    /// detail screen owns the friendly not-found state); the scan link
    /// selects the Scan tab and nothing else.
    func open(url: URL) {
        switch DeepLink(url: url) {
        case .catalog(let route):
            navigate(to: route)
        case .scan:
            // U10's prerequisite: exactly what tapping the Scan tab does —
            // the catalog stack stays as it was.
            selectedTab = .scan
        case nil:
            if url.scheme?.lowercased() == QRPayload.scheme {
                rejectedDeepLink = url
            }
        }
    }

    /// Jumps straight to a destination, replacing the current catalog stack —
    /// scanning a label always answers "what's in this bin" immediately.
    func navigate(to route: Route) {
        selectedTab = .rooms
        catalogPath = [route]
    }
}
