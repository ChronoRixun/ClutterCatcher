import AppIntents
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Feeds Core Spotlight from the catalog (M7b, U8). One `ValueObservation`
/// over the searchable snapshot covers both write paths' commit points —
/// LocalMutation and ServerApply both end in a commit, and a commit is all
/// the observation needs. Everything here is read-only against the database
/// and failure-tolerant against CoreSpotlight: an index error is logged and
/// retried on the next change, and can never fail (or even touch) a catalog
/// write.
///
/// Launch behavior: the first snapshot after start does a full clear +
/// rebuild, so the index converges with the database no matter what an
/// earlier run, install, or wipe left behind — the reset/join/degrade
/// transitions (DL33/DL34) then stay converged through the same observation
/// that tracks any other change.
actor SpotlightIndexer {
    static let batchSize = 200

    private let database: AppDatabase
    private let photoStore: PhotoStore?
    private var observationTask: Task<Void, Never>?
    /// What the live index holds, by identifier — the diff baseline.
    private var lastIndexed: [String: SpotlightEntry] = [:]
    private var hasRebuiltThisLaunch = false

    init(database: AppDatabase, photoStore: PhotoStore?) {
        self.database = database
        self.photoStore = photoStore
    }

    deinit {
        observationTask?.cancel()
    }

    func start() {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self, database] in
            do {
                let observation = database.observe { db in
                    try SpotlightCatalog.entries(db)
                }
                for try await entries in observation {
                    await self?.reconcile(entries)
                }
            } catch {
                Log.app.error("Spotlight observation ended: \(String(describing: error))")
            }
        }
    }

    func reconcile(_ entries: [SpotlightEntry]) async {
        let index = CSSearchableIndex.default()
        if !hasRebuiltThisLaunch {
            do {
                try await index.deleteAllSearchableItems()
            } catch {
                Log.app.error("Spotlight clear failed: \(String(describing: error))")
            }
            hasRebuiltThisLaunch = true
            lastIndexed = [:]
        }
        let changes = SpotlightDiff.changes(from: lastIndexed, to: entries)
        guard !changes.isEmpty else { return }

        var allSucceeded = true
        for chunk in Self.chunked(changes.deletedIdentifiers, size: Self.batchSize) {
            do {
                try await index.deleteSearchableItems(withIdentifiers: chunk)
            } catch {
                allSucceeded = false
                Log.app.error("Spotlight prune failed: \(String(describing: error))")
            }
        }
        for chunk in Self.chunked(changes.upserts, size: Self.batchSize) {
            do {
                try await index.indexSearchableItems(chunk.map(searchableItem(for:)))
            } catch {
                allSucceeded = false
                Log.app.error("Spotlight index write failed: \(String(describing: error))")
            }
        }
        // Only a fully applied batch advances the baseline — after a failure
        // the next emission re-diffs against the old state and retries
        // (re-indexing an already-indexed entry is idempotent).
        if allSucceeded {
            lastIndexed = Dictionary(
                uniqueKeysWithValues: entries.map { ($0.identifier, $0) })
        }

        // U9: item names are App Shortcut parameters ("where are the
        // Christmas lights") — re-donate them whenever the catalog changes.
        if changes.upserts.contains(where: { $0.domain == .item })
            || !changes.deletedIdentifiers.isEmpty {
            ClutterCatcherShortcuts.updateAppShortcutParameters()
        }
    }

    private func searchableItem(for entry: SpotlightEntry) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.title = entry.title
        attributes.contentDescription = entry.contentDescription
        attributes.keywords = entry.keywords
        attributes.thumbnailURL = Self.thumbnailURL(for: entry, photoStore: photoStore)
        let item = CSSearchableItem(
            uniqueIdentifier: entry.identifier,
            domainIdentifier: entry.domain.rawValue,
            attributeSet: attributes)
        // The observation keeps the index truthful; time-based expiry would
        // only ever delete entries that are still real.
        item.expirationDate = .distantFuture
        return item
    }

    /// The entry's thumbnail file, when its bytes are actually cached —
    /// P13's missing-file case just means a text-only result until the
    /// photo lands and the next reconcile re-indexes.
    static func thumbnailURL(for entry: SpotlightEntry, photoStore: PhotoStore?) -> URL? {
        guard let ref = entry.thumbnailRef else { return nil }
        return photoStore?.existingThumbnailURL(for: ref)
    }

    private static func chunked<T>(_ values: [T], size: Int) -> [[T]] {
        guard !values.isEmpty else { return [] }
        return stride(from: 0, to: values.count, by: size).map {
            Array(values[$0..<min($0 + size, values.count)])
        }
    }
}
