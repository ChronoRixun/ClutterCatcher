import Foundation

/// A navigation destination inside the catalog. Pushed onto the Rooms tab's
/// `NavigationStack`, either by tapping through the hierarchy or by a QR
/// deep link / scan.
enum Route: Hashable, Sendable {
    case room(id: String)
    case container(id: String)

    /// Maps an incoming URL (system Camera scanning a printed label, a tapped
    /// `cluttercatcher://` link) to a destination. Returns nil for URLs that
    /// aren't ours.
    init?(deepLink url: URL) {
        switch QRPayload.parse(url: url) {
        case .container(let uuid): self = .container(id: uuid.uuidString)
        case .room(let uuid): self = .room(id: uuid.uuidString)
        case nil: return nil
        }
    }
}

/// Everything the app answers a URL with: a catalog destination (the QR
/// payload vocabulary) or `cluttercatcher://scan` (M7a — U10's prerequisite),
/// which selects the Scan tab exactly as a tap would.
enum DeepLink: Hashable, Sendable {
    case catalog(Route)
    case scan

    static let scanHost = "scan"

    init?(url: URL) {
        if let route = Route(deepLink: url) {
            self = .catalog(route)
        } else if url.scheme?.lowercased() == QRPayload.scheme,
                  url.host?.lowercased() == Self.scanHost,
                  url.path.isEmpty || url.path == "/" {
            self = .scan
        } else {
            return nil
        }
    }
}
