import AppIntents
import Foundation

// M7b (U9): App Intents + Siri. "Find Item" answers the app's own core
// question — "where are the Christmas lights" — from outside the app, then
// opens the container with the match emphasized (U14). "Open Scanner" is the
// M7a `cluttercatcher://scan` route as an intent. Both are read-only against
// the database; both open the app through the URL vocabulary, so navigation
// behavior is exactly the tested deep-link path (DL5/DL73).

/// An item as Siri sees it. The subtitle disambiguates same-named items by
/// where they live ("Batteries — Junk Drawer in the Kitchen — 12 items").
struct FindableItemEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Item")
    static let defaultQuery = FindableItemQuery()

    var id: String
    var name: String
    var locationPhrase: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(locationPhrase)")
    }

    init(match: IntentItemMatch) {
        id = match.id
        name = match.name
        locationPhrase = match.locationPhrase
    }
}

struct FindableItemQuery: EntityStringQuery {
    @Dependency private var database: AppDatabase

    func entities(for identifiers: [String]) async throws -> [FindableItemEntity] {
        try await database.writer.read { db in
            try ItemIntentResolution.entities(db, identifiers: identifiers)
                .map(FindableItemEntity.init(match:))
        }
    }

    func entities(matching string: String) async throws -> [FindableItemEntity] {
        try await database.writer.read { db in
            try ItemIntentResolution.matches(db, query: string)
                .map(FindableItemEntity.init(match:))
        }
    }

    func suggestedEntities() async throws -> [FindableItemEntity] {
        try await database.writer.read { db in
            try ItemIntentResolution.all(db)
                .map(FindableItemEntity.init(match:))
        }
    }
}

struct FindItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Item"
    static let description = IntentDescription(
        "Tells you which bin something lives in, and opens it.")

    @Parameter(title: "Item")
    var item: FindableItemEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Find \(\.$item)")
    }

    @Dependency private var database: AppDatabase

    func perform() async throws -> some IntentResult & ProvidesDialog & OpensIntent {
        // Re-resolve by id at perform time — a Shortcuts-saved entity may be
        // stale (renamed, moved, or gone since it was picked).
        let match = try await database.writer.read { [id = item.id] db in
            try ItemIntentResolution.entities(db, identifiers: [id]).first
        }
        guard let match else {
            throw FindItemError.itemNoLongerExists
        }
        let url = URL(string: SpotlightCatalog.itemIdentifier(
            containerID: match.containerID, itemID: match.id))!
        // The answer IS the location phrase (plan §2 U9); the open lands on
        // the container scrolled to the match.
        return .result(opensIntent: OpenURLIntent(url), dialog: "\(match.locationPhrase)")
    }

    enum FindItemError: Error, CustomLocalizedStringResourceConvertible {
        case itemNoLongerExists

        var localizedStringResource: LocalizedStringResource {
            "That item isn't in the catalog anymore."
        }
    }
}

struct OpenScannerIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Scanner"
    static let description = IntentDescription(
        "Opens ClutterCatcher ready to scan a bin's label.")

    func perform() async throws -> some IntentResult & OpensIntent {
        // The M7a scan route: selects the Scan tab exactly as a tap would
        // (DL73), catalog stack untouched.
        .result(opensIntent: OpenURLIntent(
            URL(string: "\(QRPayload.scheme)://\(DeepLink.scanHost)")!))
    }
}

/// The two App Shortcuts, with household-English Siri phrases. Item names
/// ride the parameterized phrases; `SpotlightIndexer` re-donates them
/// whenever the catalog changes.
struct ClutterCatcherShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: FindItemIntent(),
            phrases: [
                "Where are \(\.$item) in \(.applicationName)",
                "Where is \(\.$item) in \(.applicationName)",
                "Where are my \(\.$item) in \(.applicationName)",
                "Find \(\.$item) in \(.applicationName)",
                "Ask \(.applicationName) to find \(\.$item)",
            ],
            shortTitle: "Find Item",
            systemImageName: "magnifyingglass")
        AppShortcut(
            intent: OpenScannerIntent(),
            phrases: [
                "Open the scanner in \(.applicationName)",
                "Scan a bin with \(.applicationName)",
                "Scan a label with \(.applicationName)",
                "Start scanning in \(.applicationName)",
            ],
            shortTitle: "Open Scanner",
            systemImageName: "qrcode.viewfinder")
    }
}
