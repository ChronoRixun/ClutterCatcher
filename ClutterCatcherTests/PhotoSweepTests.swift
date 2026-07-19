import Foundation
import GRDB
import Testing
import UIKit
@testable import ClutterCatcher

/// M6.1 encoding (P15/P16/P17): imports encode HEIC behind the frozen
/// `.jpg`-named cache paths, falling back to JPEG. The decode round-trip is
/// the unconditional floor; the container-format assertion is gated on the
/// encoder actually existing (CI simulators can lack it).
@Suite struct PhotoEncodingTests {
    private func makeStore(preferredEncoding: PhotoStore.Encoding = .heic) -> PhotoStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoEncodingTests-\(AppDatabase.newID())", isDirectory: true)
        return PhotoStore(root: root, preferredEncoding: preferredEncoding)
    }

    private func solidImage(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: format)
        return renderer.image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// ISO-BMFF: box size (4 bytes), then "ftyp", then the major brand.
    private func isHEICContainer(_ data: Data) -> Bool {
        guard data.count >= 12,
              let boxType = String(data: data.subdata(in: 4..<8), encoding: .ascii),
              let brand = String(data: data.subdata(in: 8..<12), encoding: .ascii) else {
            return false
        }
        return boxType == "ftyp"
            && ["heic", "heix", "mif1", "msf1", "hevc"].contains(brand)
    }

    private func isJPEG(_ data: Data) -> Bool {
        data.prefix(2) == Data([0xFF, 0xD8])
    }

    @Test func importedFilesDecodeAndPreferHEIC() throws {
        let store = makeStore()
        let ref = try store.importImage(solidImage(width: 640, height: 480))

        let fullData = try Data(contentsOf: store.fileURL(for: ref))
        let thumbData = try Data(contentsOf: store.thumbnailURL(for: ref))
        #expect(UIImage(data: fullData) != nil, "decode round-trip is the floor (§4)")
        #expect(UIImage(data: thumbData) != nil, "thumbnails decode too (P17)")

        if PhotoStore.isHEICEncodingAvailable {
            #expect(isHEICContainer(fullData), "full image encodes HEIC (P15)")
            #expect(isHEICContainer(thumbData), "thumbnail encodes HEIC (P17)")
        }
    }

    @Test func jpegFallbackWritesDecodableJPEG() throws {
        let store = makeStore(preferredEncoding: .jpeg)
        let ref = try store.importImage(solidImage(width: 300, height: 200))

        let fullData = try Data(contentsOf: store.fileURL(for: ref))
        let thumbData = try Data(contentsOf: store.thumbnailURL(for: ref))
        #expect(isJPEG(fullData), "the fallback encoder writes real JPEG bytes")
        #expect(isJPEG(thumbData))
        #expect(UIImage(data: fullData) != nil)
    }

    @Test func fileNamesStayDotJpgRegardlessOfEncoding() throws {
        let store = makeStore()
        let ref = try store.importImage(solidImage(width: 100, height: 100))
        #expect(store.fileURL(for: ref).lastPathComponent == "\(ref).jpg",
                "the id→path contract is frozen (P16)")
        #expect(store.thumbnailURL(for: ref).lastPathComponent == "\(ref)_thumb.jpg")
    }
}

/// M6.1 GC sweep (P18/P19): pure filesystem work — delete exactly the file
/// pairs that are both unreferenced and older than the age guard, never
/// anything fresh, never anything the live set names, never non-photo files.
@Suite struct PhotoSweepTests {
    private let now = Date.now
    private var cutoff: Date { now.addingTimeInterval(-3600) }
    private var oldDate: Date { now.addingTimeInterval(-7200) }

    private func makeStore() -> PhotoStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSweepTests-\(AppDatabase.newID())", isDirectory: true)
        return PhotoStore(root: root)
    }

    /// Writes a full+thumb pair via the store's own inbound path, then stamps
    /// both files' modification dates.
    private func makePair(_ store: PhotoStore, ref: String, modifiedAt: Date) throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(AppDatabase.newID()).jpg")
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 80, height: 80), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        let bytes = try #require(image.jpegData(compressionQuality: 0.8))
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        try store.ensureLocalFile(for: ref, copyingFrom: source)
        try setModificationDate(store.fileURL(for: ref), to: modifiedAt)
        try setModificationDate(store.thumbnailURL(for: ref), to: modifiedAt)
    }

    private func setModificationDate(_ url: URL, to date: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: url.path)
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? Int64) ?? 0
    }

    @Test func deletesExactlyTheUnreferencedOldPair() throws {
        let store = makeStore()
        try makePair(store, ref: "LIVE-OLD", modifiedAt: oldDate)
        try makePair(store, ref: "DEAD-OLD", modifiedAt: oldDate)
        try makePair(store, ref: "DEAD-FRESH", modifiedAt: now)
        let expectedBytes = try fileSize(store.fileURL(for: "DEAD-OLD"))
            + fileSize(store.thumbnailURL(for: "DEAD-OLD"))

        let result = store.sweepUnusedPhotos(keeping: ["LIVE-OLD"], olderThan: cutoff)

        #expect(result.filesRemoved == 2, "the full and its thumb, nothing else")
        #expect(result.bytesFreed == expectedBytes)
        #expect(store.existingFileURL(for: "DEAD-OLD") == nil)
        #expect(store.existingThumbnailURL(for: "DEAD-OLD") == nil)
        #expect(store.existingFileURL(for: "LIVE-OLD") != nil, "referenced files survive")
        #expect(store.existingThumbnailURL(for: "LIVE-OLD") != nil)
        #expect(store.existingFileURL(for: "DEAD-FRESH") != nil, "the age guard holds (P19)")
        #expect(store.existingThumbnailURL(for: "DEAD-FRESH") != nil)

        let second = store.sweepUnusedPhotos(keeping: ["LIVE-OLD"], olderThan: cutoff)
        #expect(second == PhotoStore.SweepResult(), "a second sweep is a no-op")
    }

    @Test func mixedAgePairSurvivesWhole() throws {
        let store = makeStore()
        try makePair(store, ref: "MIXED", modifiedAt: oldDate)
        try setModificationDate(store.thumbnailURL(for: "MIXED"), to: now)

        let result = store.sweepUnusedPhotos(keeping: [], olderThan: cutoff)

        #expect(result == PhotoStore.SweepResult(),
                "one fresh file protects its whole pair — never tear a pair apart")
        #expect(store.existingFileURL(for: "MIXED") != nil)
        #expect(store.existingThumbnailURL(for: "MIXED") != nil)
    }

    @Test func strayThumbnailWithoutFullIsSwept() throws {
        let store = makeStore()
        try makePair(store, ref: "STRAY", modifiedAt: oldDate)
        try FileManager.default.removeItem(at: store.fileURL(for: "STRAY"))

        let result = store.sweepUnusedPhotos(keeping: [], olderThan: cutoff)

        #expect(result.filesRemoved == 1)
        #expect(store.existingThumbnailURL(for: "STRAY") == nil)
    }

    @Test func nonPhotoFilesAreUntouched() throws {
        let store = makeStore()
        try makePair(store, ref: "ANCHOR", modifiedAt: oldDate)
        let strangerURL = store.root.appendingPathComponent("notes.txt")
        try Data("not a photo".utf8).write(to: strangerURL)
        try setModificationDate(strangerURL, to: oldDate)

        let result = store.sweepUnusedPhotos(keeping: [], olderThan: cutoff)

        #expect(result.filesRemoved == 2, "only the photo pair goes")
        #expect(FileManager.default.fileExists(atPath: strangerURL.path),
                "only names parsing as <ref>[_thumb].jpg are ever deleted (P18)")
    }

    @Test func missingAndEmptyDirectoriesAreNoOps() throws {
        let store = makeStore()
        #expect(store.sweepUnusedPhotos(keeping: [], olderThan: cutoff)
                == PhotoStore.SweepResult(), "no Photos/ directory yet")

        try FileManager.default.createDirectory(
            at: store.root, withIntermediateDirectories: true)
        #expect(store.sweepUnusedPhotos(keeping: [], olderThan: cutoff)
                == PhotoStore.SweepResult(), "empty directory")
    }
}

/// M6.1 live-set assembly (P18): the sweep's `keeping:` set is every non-nil
/// `items.photo_asset_ref` plus the refs inside orphan-buffered Item rows —
/// read-only, so unlike `loadAll` it never prunes.
@Suite struct LivePhotoRefTests {
    private let stamp = Date(timeIntervalSinceReferenceDate: 810_000_000)

    private func makeFixture() async throws -> (AppDatabase, SettingsRepository, containerId: String) {
        let database = try AppDatabase.inMemory()
        let room = try await RoomRepository(database: database)
            .createRoom(name: "Garage", icon: nil)
        let container = try await ContainerRepository(database: database)
            .createContainer(roomID: room.id, name: "Bin", notes: nil)
        return (database, SettingsRepository(database: database), container.id)
    }

    private func orphanedItem(containerId: String, photoAssetRef: String?) -> ParsedServerRecord {
        ParsedServerRecord(
            row: .item(Item(
                id: AppDatabase.newID(), containerId: containerId, name: "Buffered",
                quantity: 1, notes: nil, categoryId: nil, photoAssetRef: photoAssetRef,
                createdAt: stamp, updatedAt: stamp, createdBy: nil)),
            systemFields: Data([1, 2, 3]))
    }

    @Test func itemsTableRefsAreCollectedDistinctAndNonNil() async throws {
        let (_, repository, containerId) = try await makeFixture()
        let database = repository.database
        let items = ItemRepository(database: database)
        _ = try await items.createItem(
            containerID: containerId, name: "A", quantity: 1, notes: nil,
            categoryID: nil, photoAssetRef: "REF-A")
        _ = try await items.createItem(
            containerID: containerId, name: "A twin", quantity: 1, notes: nil,
            categoryID: nil, photoAssetRef: "REF-A")
        _ = try await items.createItem(
            containerID: containerId, name: "B", quantity: 1, notes: nil,
            categoryID: nil, photoAssetRef: "REF-B")
        _ = try await items.createItem(
            containerID: containerId, name: "No photo", quantity: 1, notes: nil,
            categoryID: nil, photoAssetRef: nil)

        let live = try await repository.livePhotoRefs()
        #expect(live == ["REF-A", "REF-B"])
    }

    @Test func orphanBufferedItemRefsAreIncluded() async throws {
        let (_, repository, containerId) = try await makeFixture()
        let withPhoto = orphanedItem(containerId: "NOT-YET-ARRIVED", photoAssetRef: "REF-ORPHAN")
        let withoutPhoto = orphanedItem(containerId: "NOT-YET-ARRIVED", photoAssetRef: nil)
        try await repository.database.writer.write { [stamp] db in
            try OrphanedRecord.buffer(db, records: [withPhoto, withoutPhoto], at: stamp)
        }
        let items = ItemRepository(database: repository.database)
        _ = try await items.createItem(
            containerID: containerId, name: "Applied", quantity: 1, notes: nil,
            categoryID: nil, photoAssetRef: "REF-APPLIED")

        let live = try await repository.livePhotoRefs()
        #expect(live == ["REF-APPLIED", "REF-ORPHAN"],
                "a sweep that missed buffered refs would eat bytes the drain needs (P9/P18)")
    }

    @Test func nonItemOrphansContributeNothing() async throws {
        let (_, repository, _) = try await makeFixture()
        let container = ParsedServerRecord(
            row: .container(Container(
                id: AppDatabase.newID(), roomId: "NOT-YET-ARRIVED", name: "Buffered Bin",
                notes: nil, labelSlot: nil, coverItemId: nil,
                createdAt: stamp, updatedAt: stamp, createdBy: nil)),
            systemFields: Data([4]))
        try await repository.database.writer.write { [stamp] db in
            try OrphanedRecord.buffer(db, records: [container], at: stamp)
        }

        let live = try await repository.livePhotoRefs()
        #expect(live.isEmpty)
    }

    @Test func undecodableOrphanIsSkippedNotPruned() async throws {
        let (_, repository, _) = try await makeFixture()
        try await repository.database.writer.write { [stamp] db in
            try OrphanedRecord(
                recordId: "BROKEN", recordType: .item,
                payload: Data([0xBA, 0xD0]), systemFields: Data([9]),
                bufferedAt: stamp
            ).insert(db)
        }

        let live = try await repository.livePhotoRefs()
        #expect(live.isEmpty)

        let remaining = try await repository.database.writer.read { db in
            try OrphanedRecord.fetchCount(db)
        }
        #expect(remaining == 1, "the live-set read is read-only — it never prunes (DL20 untouched)")
    }
}
