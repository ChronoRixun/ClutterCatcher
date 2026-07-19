import Foundation
import UIKit

/// Owns the on-device photo cache for M6 item photos (`Photos/` under
/// Application Support). Pure file + image work — it has **no CloudKit
/// knowledge**: CloudKit is the source of truth (P7), these files are a
/// regenerable local mirror. Files are keyed by an item's `photo_asset_ref`
/// (P6 — a device-independent uppercase-UUID photo id, minted per photo), not
/// by the item id and not by a device path:
///
/// - `Photos/<ref>.jpg`        — full-size image (rides to CloudKit as the
///                               Item record's `photo` CKAsset)
/// - `Photos/<ref>_thumb.jpg`  — list thumbnail, generated on-device and
///                               never synced (P12)
///
/// `Sendable` and concurrency-clean: it stores only a root `URL`, so it is
/// safe to hand to the coordinator actor's inbound apply path (P8/P9) and to
/// call from a background task during import.
struct PhotoStore: Sendable {
    /// The `Photos/` directory. Created lazily on first write so merely
    /// constructing a store (previews, the coordinator on a device with no
    /// photos yet) touches nothing.
    let root: URL

    /// Longest edge, in pixels, of the stored full-size image (P12).
    static let maxFullEdge: CGFloat = 2048
    /// Longest edge, in pixels, of the cached list thumbnail. Ample for a
    /// ~44 pt row at 3× (≈132 px) with headroom for larger Dynamic Type.
    static let maxThumbEdge: CGFloat = 320
    /// JPEG quality for both full and thumbnail (P12 ≈ 0.8).
    static let jpegQuality: CGFloat = 0.8

    enum PhotoStoreError: Error {
        case couldNotEncodeImage
        case couldNotDecodeImage(URL)
    }

    // MARK: Construction

    init(root: URL) {
        self.root = root
    }

    /// The real device store: `Application Support/Photos`.
    static func onDisk() throws -> PhotoStore {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return PhotoStore(root: appSupport.appending(path: "Photos", directoryHint: .isDirectory))
    }

    /// A throwaway store rooted in the caches directory, for previews and any
    /// out-of-tree view that shouldn't touch the real cache.
    static func preview() -> PhotoStore {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return PhotoStore(root: base.appending(path: "PreviewPhotos", directoryHint: .isDirectory))
    }

    // MARK: URLs

    func fileURL(for ref: String) -> URL {
        root.appending(path: "\(ref).jpg")
    }

    func thumbnailURL(for ref: String) -> URL {
        root.appending(path: "\(ref)_thumb.jpg")
    }

    /// The full-size URL only when the file is actually on disk — used both to
    /// gate the outbound CKAsset attach (never attach bytes we don't have) and
    /// to drive the P13 missing-asset placeholder.
    func existingFileURL(for ref: String) -> URL? {
        let url = fileURL(for: ref)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func existingThumbnailURL(for ref: String) -> URL? {
        let url = thumbnailURL(for: ref)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func hasLocalFile(for ref: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: ref).path)
    }

    // MARK: Import (local capture)

    /// Processes a freshly captured/picked image per P12 (fix orientation,
    /// downscale to ≤ `maxFullEdge`, JPEG ≈ `jpegQuality`), writes the full
    /// image and its thumbnail, and returns a fresh `photo_asset_ref`. A new
    /// id every call means replacing a photo changes the ref, which is exactly
    /// what makes LWW see an edit (P6).
    @discardableResult
    func importImage(_ image: UIImage) throws -> String {
        let ref = AppDatabase.newID()
        try createDirectoryIfNeeded()

        let full = Self.normalizedDownscaled(image, maxEdge: Self.maxFullEdge)
        guard let fullData = full.jpegData(compressionQuality: Self.jpegQuality) else {
            throw PhotoStoreError.couldNotEncodeImage
        }
        try fullData.write(to: fileURL(for: ref), options: .atomic)

        try writeThumbnail(from: full, ref: ref)
        return ref
    }

    // MARK: Inbound materialization (P8/P9)

    /// Copies asset bytes into the cache **only when the full file is missing**
    /// — a no-op otherwise. Called from the coordinator when an item record
    /// arrives carrying a `photo` CKAsset (the temp `fileURL` is valid only for
    /// the duration of that delegate callback, so the copy happens then). The
    /// thumbnail is (re)generated from the copied bytes so the list has one
    /// without a second synced asset.
    func ensureLocalFile(for ref: String, copyingFrom source: URL) throws {
        try createDirectoryIfNeeded()
        let destination = fileURL(for: ref)
        if !FileManager.default.fileExists(atPath: destination.path) {
            // Copy the asset bytes verbatim — CloudKit is the source of truth
            // and re-encoding would drift the household's canonical image.
            try FileManager.default.copyItem(at: source, to: destination)
        }
        try regenerateThumbnailIfNeeded(for: ref)
    }

    /// Rebuilds the thumbnail from the stored full image when it's missing
    /// (thumbs are never synced and are always regenerable — P12).
    func regenerateThumbnailIfNeeded(for ref: String) throws {
        guard existingThumbnailURL(for: ref) == nil,
              FileManager.default.fileExists(atPath: fileURL(for: ref).path) else { return }
        guard let full = UIImage(contentsOfFile: fileURL(for: ref).path) else {
            throw PhotoStoreError.couldNotDecodeImage(fileURL(for: ref))
        }
        try writeThumbnail(from: full, ref: ref)
    }

    // MARK: Delete (replace / remove / item delete)

    /// Removes the full image and its thumbnail for a ref. Idempotent — a
    /// missing file is not an error (the ref may never have had a local file).
    func delete(id ref: String) throws {
        for url in [fileURL(for: ref), thumbnailURL(for: ref)] {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: Internals

    private func createDirectoryIfNeeded() throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
    }

    private func writeThumbnail(from image: UIImage, ref: String) throws {
        let thumb = Self.normalizedDownscaled(image, maxEdge: Self.maxThumbEdge)
        guard let data = thumb.jpegData(compressionQuality: Self.jpegQuality) else {
            throw PhotoStoreError.couldNotEncodeImage
        }
        try data.write(to: thumbnailURL(for: ref), options: .atomic)
    }

    /// Returns an orientation-normalized copy scaled so its longest edge is at
    /// most `maxEdge` pixels (never upscaled). Drawing through a 1× renderer
    /// bakes in the orientation and yields a `UIImage` whose `size` equals its
    /// pixel dimensions — which is what makes the ≤ `maxEdge` assertion in the
    /// tests meaningful.
    static func normalizedDownscaled(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let pixelSize = CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale)
        let longest = max(pixelSize.width, pixelSize.height)
        let scale = longest > maxEdge ? maxEdge / longest : 1
        let target = CGSize(
            width: max(1, (pixelSize.width * scale).rounded()),
            height: max(1, (pixelSize.height * scale).rounded()))

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1          // 1 point == 1 pixel, so `size` == pixels
        format.opaque = true      // JPEG has no alpha; opaque avoids a needless channel
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
