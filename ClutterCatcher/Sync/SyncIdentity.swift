import Foundation
import GRDB

/// Which CloudKit container environment this binary talks to. Compile-time
/// mirror of the `com.apple.developer.icloud-container-environment`
/// entitlement — both are defined in `project.yml` and MUST change in
/// lockstep (see the comments there). There is no runtime API for this, so
/// the build carries its own answer.
enum CloudKitEnvironment {
    #if CLOUDKIT_ENV_PRODUCTION
    static let current = "production"
    #else
    static let current = "development"
    #endif
}

/// The identity all sync bookkeeping is valid for (generalizes DL25): the
/// signed-in Apple ID *and* the container environment. Archived change tags
/// in `record_metadata` and serialized engine state refer to records that
/// exist only for one (account, environment) pair — a mismatch of either
/// component means they describe records the current server has never seen.
struct SyncIdentityFingerprint: Equatable, Sendable, Codable {
    var userRecordName: String
    var environment: String
}

enum SyncIdentityBookkeeping {
    /// Compares the stored fingerprint against `current`; on mismatch of
    /// either component, resets the sync bookkeeping — engine states and
    /// `record_metadata` (plus buffered orphans, which are fetched state).
    /// `pending_changes` and the catalog always survive: unsent local edits
    /// are still edits, and backfill re-queues everything else on the next
    /// engine start. Returns true if a reset happened.
    static func reconcile(_ db: Database, current: SyncIdentityFingerprint) throws -> Bool {
        let stored = try storedFingerprint(db)
        guard stored != current else { return false }

        // No stored fingerprint + no bookkeeping = genuinely fresh; just
        // adopt the identity. Bookkeeping without a fingerprint (or with a
        // mismatched one) can't be trusted and gets the reset.
        let hasBookkeeping = try RecordMetadata.fetchCount(db) > 0
            || SyncState.fetchOne(db, key: SyncState.privateEngineKey) != nil
            || SyncState.fetchOne(db, key: SyncState.sharedEngineKey) != nil
        if stored == nil && !hasBookkeeping {
            try store(current, db)
            return false
        }

        _ = try SyncState.deleteOne(db, key: SyncState.privateEngineKey)
        _ = try SyncState.deleteOne(db, key: SyncState.sharedEngineKey)
        try RecordMetadata.deleteAll(db)
        try OrphanedRecord.deleteAll(db)
        // pending_changes and the catalog survive by design.
        try SyncEvent.append(
            db, kind: .syncIdentityReset, recordType: nil, recordId: nil,
            summary: "The iCloud account or environment changed — sync records were rebuilt; your catalog re-uploads once.")
        try store(current, db)
        return true
    }

    private static func storedFingerprint(_ db: Database) throws -> SyncIdentityFingerprint? {
        if let stored = try SyncState.fetchOne(db, key: SyncState.identityKey) {
            return try? JSONDecoder().decode(SyncIdentityFingerprint.self, from: stored.data)
        }
        // M2 installs stored only the account component (DL25). Treat them as
        // Development-era bookkeeping — which every pre-M3 install was — so
        // the first Production-pinned launch resets exactly once.
        if let legacy = try SyncState.fetchOne(db, key: SyncState.legacyAccountUserKey),
           let name = String(data: legacy.data, encoding: .utf8) {
            return SyncIdentityFingerprint(userRecordName: name, environment: "development")
        }
        return nil
    }

    private static func store(_ fingerprint: SyncIdentityFingerprint, _ db: Database) throws {
        let data = try JSONEncoder().encode(fingerprint)
        try SyncState(key: SyncState.identityKey, data: data)
            .insert(db, onConflict: .replace)
        _ = try SyncState.deleteOne(db, key: SyncState.legacyAccountUserKey)
    }

    /// The stored account component, for "You" resolution in created_by
    /// display (M3-F) — nil until the first successful identity check.
    static func storedUserRecordName(_ db: Database) throws -> String? {
        guard let stored = try SyncState.fetchOne(db, key: SyncState.identityKey),
              let fingerprint = try? JSONDecoder()
                  .decode(SyncIdentityFingerprint.self, from: stored.data) else {
            return nil
        }
        return fingerprint.userRecordName
    }
}
