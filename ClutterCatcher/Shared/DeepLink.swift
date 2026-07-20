import Foundation

/// A navigation destination inside the catalog. Pushed onto the Rooms tab's
/// `NavigationStack`, either by tapping through the hierarchy or by a QR
/// deep link / scan.
enum Route: Hashable, Sendable {
    case room(id: String)
    /// M7b (U14): the optional highlight id scrolls the container's list to
    /// the matched item and briefly emphasizes it — search results, Spotlight
    /// taps, and the Find intent all ride this one route.
    case container(id: String, highlightItemID: String?)
    /// M7b (U13): the category browse view — everything carrying a category,
    /// grouped room → container. In-app vocabulary only; the printed QR/URL
    /// contract stays containers-and-rooms.
    case category(id: String)

    /// The common no-highlight container destination, so plain call sites
    /// read exactly as they did before U14 (enum cases can't default their
    /// associated values).
    static func container(id: String) -> Route {
        .container(id: id, highlightItemID: nil)
    }

    /// Maps an incoming URL (system Camera scanning a printed label, a tapped
    /// `cluttercatcher://` link) to a destination. Returns nil for URLs that
    /// aren't ours. Container links may carry `?item=<uuid>` (U14) — written
    /// by Spotlight identifiers and the Find intent, never by printed labels;
    /// the id is case-normalized like every UUID we parse (DL1).
    init?(deepLink url: URL) {
        switch QRPayload.parse(url: url) {
        case .container(let uuid):
            self = .container(
                id: uuid.uuidString,
                highlightItemID: Self.highlightItemID(in: url))
        case .room(let uuid):
            self = .room(id: uuid.uuidString)
        case nil:
            return nil
        }
    }

    static let highlightQueryName = "item"

    private static func highlightItemID(in url: URL) -> String? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name.lowercased() == highlightQueryName })?.value,
              let uuid = UUID(uuidString: raw) else {
            return nil
        }
        return uuid.uuidString
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
