import Foundation

/// The QR payload / deep-link vocabulary (plan §3.4).
///
/// Canonical form: `cluttercatcher://c/<uuid>` for containers; `r/<uuid>` is
/// reserved for rooms. The in-app scanner additionally accepts a bare UUID.
enum QRPayload: Equatable, Sendable {
    case container(UUID)
    case room(UUID)

    static let scheme = "cluttercatcher"
    static let containerHost = "c"
    static let roomHost = "r"

    /// The string encoded into a printed QR label.
    var absoluteString: String {
        switch self {
        case .container(let id): "\(Self.scheme)://\(Self.containerHost)/\(id.uuidString)"
        case .room(let id): "\(Self.scheme)://\(Self.roomHost)/\(id.uuidString)"
        }
    }

    var url: URL {
        // The canonical form is always a valid URL; a failure here is a
        // programmer error, not a runtime condition.
        URL(string: absoluteString)!
    }

    /// Parses a scanned string: the URL form (either kind) or a bare UUID
    /// (treated as a container, the only entity we print labels for).
    static func parse(scanned string: String) -> QRPayload? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = UUID(uuidString: trimmed) {
            return .container(uuid)
        }
        guard let url = URL(string: trimmed) else { return nil }
        return parse(url: url)
    }

    /// Parses the URL form. Accepts `cluttercatcher://c/<uuid>` where `c` is
    /// the host and the UUID is the single path component; case-insensitive.
    static func parse(url: URL) -> QRPayload? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let uuid = UUID(uuidString: path) else { return nil }
        switch host {
        case containerHost: return .container(uuid)
        case roomHost: return .room(uuid)
        default: return nil
        }
    }
}
