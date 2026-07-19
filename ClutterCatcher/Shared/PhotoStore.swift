import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

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

    /// Which encoder `encode(_:)` tries first. `.heic` is the shipping value
    /// (P15); `.jpeg` skips straight to the fallback encoder — the injection
    /// seam the §4 fallback test uses.
    let preferredEncoding: Encoding

    enum Encoding: Sendable {
        case heic
        case jpeg
    }

    /// Longest edge, in pixels, of the stored full-size image (P12).
    static let maxFullEdge: CGFloat = 2048
    /// Longest edge, in pixels, of the cached list thumbnail. Ample for a
    /// ~44 pt row at 3× (≈132 px) with headroom for larger Dynamic Type.
    static let maxThumbEdge: CGFloat = 320
    /// Lossy compression quality for both full and thumbnail, whichever
    /// encoder ends up writing the bytes (P12/P15 ≈ 0.8).
    static let encodingQuality: CGFloat = 0.8

    enum PhotoStoreError: Error {
        case couldNotEncodeImage
        case couldNotDecodeImage(URL)
    }

    // MARK: Construction

    init(root: URL, preferredEncoding: Encoding = .heic) {
        self.root = root
        self.preferredEncoding = preferredEncoding
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

    /// `.jpg` here means "image file", not JPEG (P16): locally captured
    /// photos encode HEIC since M6.1 (JPEG before, and as fallback), and
    /// inbound peer assets are opaque bytes copied verbatim — every reader
    /// decodes by content (`UIImage` sniffs bytes, not names), so the frozen
    /// id→path contract outlives any encoding change.
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
    /// downscale to ≤ `maxFullEdge`, encode HEIC-or-JPEG ≈ `encodingQuality`),
    /// writes the full image and its thumbnail, and returns a fresh
    /// `photo_asset_ref`. A new id every call means replacing a photo changes
    /// the ref, which is exactly what makes LWW see an edit (P6).
    @discardableResult
    func importImage(_ image: UIImage) throws -> String {
        let ref = AppDatabase.newID()
        try createDirectoryIfNeeded()

        let full = Self.normalizedDownscaled(image, maxEdge: Self.maxFullEdge)
        try encode(full).write(to: fileURL(for: ref), options: .atomic)

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

    // MARK: Cleanup sweep (P18/P19)

    /// How long a photo file must sit unmodified before the sweep may touch
    /// it (P19). Editor-staged captures are DB-invisible until Save (DL43),
    /// and the coordinator materializes inbound bytes *before* the row lands
    /// (DL40) — both write files that a concurrent live-set read can't see,
    /// and both are always younger than this guard when it matters.
    static let sweepAgeGuard: TimeInterval = 60 * 60

    struct SweepResult: Equatable, Sendable {
        var filesRemoved = 0
        var bytesFreed: Int64 = 0
    }

    /// Deletes every photo file pair whose ref is not in `live` and whose
    /// files were all last modified before `cutoff` — pure filesystem work;
    /// where the live set comes from is the caller's business (P18).
    ///
    /// - Every `*.jpg` in `Photos/` parses as `<ref>.jpg` / `<ref>_thumb.jpg`
    ///   (the directory is wholly this store's); anything else is untouched.
    /// - A pair is skipped whole when *any* of its files is newer than
    ///   `cutoff` (or its date is unreadable) — deleting a full image out from
    ///   under a fresh thumbnail (or vice versa) would tear a pair the age
    ///   guard exists to protect.
    /// - Per-file failures are logged and skipped, never thrown (P20): a
    ///   leftover file is the status quo, not a fault.
    func sweepUnusedPhotos(keeping live: Set<String>, olderThan cutoff: Date) -> SweepResult {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: Array(keys)) else {
            return SweepResult() // No Photos/ directory yet — nothing to clean.
        }

        var filesByRef: [String: [URL]] = [:]
        for url in contents where url.pathExtension == "jpg" {
            var name = url.deletingPathExtension().lastPathComponent
            if name.hasSuffix("_thumb") { name = String(name.dropLast("_thumb".count)) }
            guard !name.isEmpty else { continue }
            filesByRef[name, default: []].append(url)
        }

        var result = SweepResult()
        for (ref, urls) in filesByRef where !live.contains(ref) {
            let allOld = urls.allSatisfy { url in
                guard let modified = try? url.resourceValues(forKeys: keys)
                    .contentModificationDate else { return false }
                return modified < cutoff
            }
            guard allOld else { continue }
            for url in urls {
                let size = (try? url.resourceValues(forKeys: keys).fileSize) ?? 0
                do {
                    try FileManager.default.removeItem(at: url)
                    result.filesRemoved += 1
                    result.bytesFreed += Int64(size)
                } catch {
                    Log.data.error("Photo sweep couldn't remove \(url.lastPathComponent): \(String(describing: error))")
                }
            }
        }
        return result
    }

    // MARK: Internals

    private func createDirectoryIfNeeded() throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
    }

    private func writeThumbnail(from image: UIImage, ref: String) throws {
        let thumb = Self.normalizedDownscaled(image, maxEdge: Self.maxThumbEdge)
        try encode(thumb).write(to: thumbnailURL(for: ref), options: .atomic)
    }

    /// The one encoding seam (P15/P17): HEIC via `CGImageDestination` with an
    /// explicit lossy quality — `UIImage.heicData()` has no quality knob —
    /// falling back to JPEG when HEIC fails or `preferredEncoding` skips it.
    /// The fleet is all iOS 26 hardware with HEVC encoders, so the fallback is
    /// paranoia (plus tiny images some encoders reject), but it keeps P12's
    /// original "HEIC preferred / JPEG fallback" promise.
    private func encode(_ image: UIImage) throws -> Data {
        if preferredEncoding == .heic, let heic = Self.heicData(image) {
            return heic
        }
        guard let jpeg = image.jpegData(compressionQuality: Self.encodingQuality) else {
            throw PhotoStoreError.couldNotEncodeImage
        }
        return jpeg
    }

    static func heicData(_ image: UIImage) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.heic.identifier as CFString, 1, nil) else {
            return nil
        }
        let options = [
            kCGImageDestinationLossyCompressionQuality: encodingQuality
        ] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Whether this device can produce HEIC at all — the §4 encode test gates
    /// its container-format assertion on this (CI simulators can lack the
    /// encoder; the decode round-trip is the unconditional floor).
    static var isHEICEncodingAvailable: Bool {
        let identifiers = CGImageDestinationCopyTypeIdentifiers() as NSArray
        return identifiers.contains(UTType.heic.identifier)
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
