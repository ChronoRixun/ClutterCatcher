import Foundation
import Testing
import UIKit
@testable import ClutterCatcher

/// M6 PhotoStore: pure file/image work — mint a fresh id per import, write
/// full + thumbnail, downscale ≤ 2048 px (P12), delete both files, and copy
/// inbound bytes only when missing (P8/P9). No CloudKit here.
@Suite struct PhotoStoreTests {
    /// A fresh temp root per store so tests never collide.
    private func makeStore() -> PhotoStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoStoreTests-\(AppDatabase.newID())", isDirectory: true)
        return PhotoStore(root: root)
    }

    private func solidImage(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1 // 1 pt == 1 px, so the produced UIImage.size is in pixels
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: format)
        return renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func pixelLongestEdge(_ image: UIImage) -> CGFloat {
        max(image.size.width * image.scale, image.size.height * image.scale)
    }

    @Test func importWritesFullAndThumbnailWithFreshIds() throws {
        let store = makeStore()
        let image = solidImage(width: 120, height: 120)
        let refA = try store.importImage(image)
        let refB = try store.importImage(image)

        #expect(refA != refB, "a fresh photo id per import (P6)")
        #expect(store.existingFileURL(for: refA) != nil)
        #expect(store.existingThumbnailURL(for: refA) != nil)
        #expect(store.existingFileURL(for: refB) != nil)
        #expect(store.existingThumbnailURL(for: refB) != nil)
    }

    @Test func importDownscalesToMaxEdgePreservingAspect() throws {
        let store = makeStore()
        let ref = try store.importImage(solidImage(width: 4000, height: 3000))
        let url = try #require(store.existingFileURL(for: ref))
        let loaded = try #require(UIImage(contentsOfFile: url.path))

        #expect(pixelLongestEdge(loaded) <= PhotoStore.maxFullEdge,
                "full image downscaled to ≤ 2048 px (P12)")
        let aspect = loaded.size.width / loaded.size.height
        #expect(abs(aspect - 4.0 / 3.0) < 0.05, "aspect ratio preserved")
    }

    @Test func importDoesNotUpscaleSmallImages() throws {
        let store = makeStore()
        let ref = try store.importImage(solidImage(width: 200, height: 150))
        let url = try #require(store.existingFileURL(for: ref))
        let loaded = try #require(UIImage(contentsOfFile: url.path))
        #expect(pixelLongestEdge(loaded) <= 201, "already-small images aren't upscaled")
    }

    @Test func deleteRemovesBothFilesAndIsIdempotent() throws {
        let store = makeStore()
        let ref = try store.importImage(solidImage(width: 100, height: 100))
        #expect(store.existingFileURL(for: ref) != nil)

        try store.delete(id: ref)
        #expect(store.existingFileURL(for: ref) == nil)
        #expect(store.existingThumbnailURL(for: ref) == nil)

        // Deleting a ref with no files must not throw.
        try store.delete(id: ref)
    }

    @Test func ensureLocalFileCopiesWhenMissingThenNoOps() throws {
        let store = makeStore()
        let ref = "INBOUND-REF"

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(AppDatabase.newID()).jpg")
        let sourceBytes = try #require(
            solidImage(width: 300, height: 300).jpegData(compressionQuality: 0.8))
        try sourceBytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        #expect(store.existingFileURL(for: ref) == nil)
        try store.ensureLocalFile(for: ref, copyingFrom: source)

        let dest = try #require(store.existingFileURL(for: ref))
        #expect(store.existingThumbnailURL(for: ref) != nil,
                "a thumbnail is generated from the copied bytes")
        let firstCopy = try Data(contentsOf: dest)
        #expect(firstCopy == sourceBytes,
                "bytes copied verbatim — CloudKit is the source of truth")

        // A second call with different bytes must NOT overwrite (missing-only).
        let source2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(AppDatabase.newID()).jpg")
        let otherBytes = try #require(
            solidImage(width: 500, height: 200).jpegData(compressionQuality: 0.8))
        try otherBytes.write(to: source2)
        defer { try? FileManager.default.removeItem(at: source2) }

        try store.ensureLocalFile(for: ref, copyingFrom: source2)
        let afterSecond = try Data(contentsOf: dest)
        #expect(afterSecond == firstCopy,
                "ensureLocalFile is a no-op when the file already exists")
    }
}
