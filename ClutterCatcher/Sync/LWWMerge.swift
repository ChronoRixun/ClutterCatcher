import Foundation

/// The last-write-wins conflict policy (D10, plan §3.2), as a pure function
/// so the whole decision table is unit-testable — see LWWMergeTests for the
/// pinned semantics.
enum LWWMerge {
    enum Resolution: Equatable, Sendable {
        /// Apply the server values locally; drop any pending local change.
        case acceptServer
        /// Keep the local row (or local delete) and (re)send it.
        case keepLocal
    }

    /// - Parameters:
    ///   - localUpdatedAt: the local row's `updated_at`; nil if no row exists.
    ///   - pending: the outbound change queued for this record, if any.
    ///   - serverUpdatedAt: the server record's `updated_at` field.
    static func resolve(
        localUpdatedAt: Date?,
        pending: (kind: PendingChange.Kind, queuedAt: Date)?,
        serverUpdatedAt: Date?
    ) -> Resolution {
        guard let pending else {
            // No local edit since the last server ack — the server copy is
            // newer by causality, whatever the wall clocks claim.
            return .acceptServer
        }
        let serverTime = serverUpdatedAt ?? .distantPast
        let localTime: Date
        switch pending.kind {
        case .save:
            localTime = localUpdatedAt ?? pending.queuedAt
        case .delete:
            // Deletes leave no row to carry `updated_at`; the queue stamp was
            // written by the same clock in the same transaction.
            localTime = pending.queuedAt
        }
        // Ties keep local: both devices re-sending converges on whichever
        // upload lands last, and the loser then has no pending change left
        // and accepts the fetched result.
        return localTime >= serverTime ? .keepLocal : .acceptServer
    }
}
