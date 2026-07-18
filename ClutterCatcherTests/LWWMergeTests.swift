import Foundation
import Testing
@testable import ClutterCatcher

/// The last-write-wins decision table (D10, plan §3.2). This pure function is
/// the household's data integrity — every branch is pinned here.
///
/// Semantics:
/// - No pending outbound change → the local row is untouched since the last
///   server ack, so the server value always wins.
/// - Pending save → newest `updated_at` wins; ties keep local (both sides
///   keeping local converges: the last successful upload becomes the record,
///   and the other device then has no pending change and accepts it).
/// - Pending delete → the delete's queue time is the local edit time.
/// - A server record missing `updated_at` never beats a real local edit.
@Suite struct LWWMergeTests {
    private let t1 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let t2 = Date(timeIntervalSinceReferenceDate: 800_000_100)
    private let t3 = Date(timeIntervalSinceReferenceDate: 800_000_200)

    // MARK: No local edit in flight

    @Test func noPendingAcceptsServerEvenWhenLocalLooksNewer() {
        let resolution = LWWMerge.resolve(
            localUpdatedAt: t3, pending: nil, serverUpdatedAt: t1)
        #expect(resolution == .acceptServer)
    }

    @Test func noPendingAcceptsServerWhenLocalRowMissing() {
        let resolution = LWWMerge.resolve(
            localUpdatedAt: nil, pending: nil, serverUpdatedAt: t1)
        #expect(resolution == .acceptServer)
    }

    // MARK: Pending save

    @Test func newerLocalSaveWins() {
        let resolution = LWWMerge.resolve(
            localUpdatedAt: t3, pending: (.save, t3), serverUpdatedAt: t2)
        #expect(resolution == .keepLocal)
    }

    @Test func olderLocalSaveLoses() {
        let resolution = LWWMerge.resolve(
            localUpdatedAt: t1, pending: (.save, t1), serverUpdatedAt: t2)
        #expect(resolution == .acceptServer)
    }

    @Test func timestampTieKeepsLocal() {
        let resolution = LWWMerge.resolve(
            localUpdatedAt: t2, pending: (.save, t2), serverUpdatedAt: t2)
        #expect(resolution == .keepLocal)
    }

    @Test func pendingSaveBeatsServerRecordWithoutTimestamp() {
        let resolution = LWWMerge.resolve(
            localUpdatedAt: t1, pending: (.save, t1), serverUpdatedAt: nil)
        #expect(resolution == .keepLocal)
    }

    @Test func pendingSaveWithMissingRowFallsBackToQueueTimeNewer() {
        let resolution = LWWMerge.resolve(
            localUpdatedAt: nil, pending: (.save, t3), serverUpdatedAt: t2)
        #expect(resolution == .keepLocal)
    }

    @Test func pendingSaveWithMissingRowFallsBackToQueueTimeOlder() {
        let resolution = LWWMerge.resolve(
            localUpdatedAt: nil, pending: (.save, t1), serverUpdatedAt: t2)
        #expect(resolution == .acceptServer)
    }

    // MARK: Pending delete

    @Test func newerLocalDeleteWins() {
        let resolution = LWWMerge.resolve(
            localUpdatedAt: nil, pending: (.delete, t3), serverUpdatedAt: t2)
        #expect(resolution == .keepLocal)
    }

    @Test func olderLocalDeleteLosesToServerEdit() {
        let resolution = LWWMerge.resolve(
            localUpdatedAt: nil, pending: (.delete, t1), serverUpdatedAt: t2)
        #expect(resolution == .acceptServer)
    }

    @Test func deleteTieKeepsLocalDelete() {
        let resolution = LWWMerge.resolve(
            localUpdatedAt: nil, pending: (.delete, t2), serverUpdatedAt: t2)
        #expect(resolution == .keepLocal)
    }

    @Test func pendingDeleteBeatsServerRecordWithoutTimestamp() {
        let resolution = LWWMerge.resolve(
            localUpdatedAt: nil, pending: (.delete, t1), serverUpdatedAt: nil)
        #expect(resolution == .keepLocal)
    }
}
