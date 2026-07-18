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
    /// detail screen owns the friendly not-found state).
    func open(url: URL) {
        guard let route = Route(deepLink: url) else {
            if url.scheme?.lowercased() == QRPayload.scheme {
                rejectedDeepLink = url
            }
            return
        }
        navigate(to: route)
    }

    /// Jumps straight to a destination, replacing the current catalog stack —
    /// scanning a label always answers "what's in this bin" immediately.
    func navigate(to route: Route) {
        selectedTab = .rooms
        catalogPath = [route]
    }
}
