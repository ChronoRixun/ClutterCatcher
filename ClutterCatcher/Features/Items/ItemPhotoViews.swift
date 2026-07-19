import SwiftUI
import UIKit

// Reusable M6 photo UI: a thumbnail that degrades to the missing-asset
// placeholder (P13), a zoomable full-screen viewer that nudges a refetch when
// the file is absent, and a camera capture wrapper. Display reads from the
// injected `PhotoStore`; nothing here knows about CloudKit.

/// Loads a local image file. The file *read* (the slow part) is offloaded to a
/// detached task returning `Data` (which is `Sendable`); decoding happens back
/// on the main actor, so no `UIImage` ever crosses an isolation boundary — the
/// loader stays valid regardless of whether the SDK marks `UIImage` `Sendable`.
@MainActor
enum ItemPhotoLoader {
    static func load(_ url: URL?) async -> UIImage? {
        guard let path = url?.path else { return nil }
        let data = await Task.detached(priority: .userInitiated) {
            FileManager.default.contents(atPath: path)
        }.value
        guard let data else { return nil }
        return UIImage(data: data)
    }
}

/// A rounded thumbnail for a photo id. Shows the cached thumbnail when present,
/// and a subtle placeholder when the ref is set but the file hasn't arrived
/// yet (P13). Callers only render this when a ref exists.
struct PhotoThumbnailView: View {
    let ref: String
    var size: CGFloat = 44

    @Environment(\.photoStore) private var photoStore
    @State private var image: UIImage?
    @State private var loaded = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary)
                if loaded {
                    // Loaded, but no file — the referenced photo is still
                    // downloading or was wiped (P13).
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                        .font(.system(size: size * 0.4))
                        .accessibilityLabel("Photo not downloaded yet")
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: ref) {
            image = nil
            loaded = false
            let url = photoStore.existingThumbnailURL(for: ref)
                ?? photoStore.existingFileURL(for: ref)
            image = await ItemPhotoLoader.load(url)
            loaded = true
        }
    }
}

/// Full-screen, pinch-zoomable view of a photo. If the file is missing it
/// shows a placeholder and asks the coordinator to fetch (P13).
struct FullScreenPhotoView: View {
    let ref: String

    @Environment(\.photoStore) private var photoStore
    @Environment(\.syncCoordinator) private var coordinator
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var loaded = false
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .gesture(zoom)
                        .onTapGesture(count: 2) {
                            withAnimation(.snappy) {
                                scale = scale > 1 ? 1 : 2.5
                                committedScale = scale
                            }
                        }
                        .accessibilityLabel("Item photo")
                } else if loaded {
                    missingState
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: ref) {
            loaded = false
            image = await ItemPhotoLoader.load(photoStore.existingFileURL(for: ref))
            loaded = true
            if image == nil {
                // P13: the metadata says there's a photo but the bytes aren't
                // here — pull. Best-effort; never blocks.
                await coordinator?.requestPhotoRefetch()
            }
        }
    }

    private var zoom: some Gesture {
        MagnificationGesture()
            .onChanged { value in scale = min(max(committedScale * value, 1), 6) }
            .onEnded { _ in committedScale = scale }
    }

    private var missingState: some View {
        ContentUnavailableView {
            Label("Photo Not Downloaded", systemImage: "photo.badge.arrow.down")
        } description: {
            Text("This photo hasn't reached this device yet. It'll appear once iCloud finishes syncing.")
        }
        .foregroundStyle(.white)
    }
}

/// Camera capture (P2) via `UIImagePickerController` — no SwiftUI-native camera
/// exists on iOS 26. Library capture uses `PhotosPicker` directly in the
/// editor (no wrapper needed). `NSCameraUsageDescription` already ships for the
/// scanner, so there's no Info.plist change (§5). Mirrors the proven
/// `DataScannerRepresentable` shape: a `@MainActor` coordinator holding plain
/// closures, so no non-`Sendable` state crosses an isolation boundary.
struct CameraPicker: UIViewControllerRepresentable {
    /// Called on the main actor with the captured image.
    var onImage: (UIImage) -> Void
    /// Called on the main actor when capture finishes or is cancelled — the
    /// editor uses it to dismiss the presenting sheet.
    var onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage, onFinish: onFinish) }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage) -> Void
        let onFinish: () -> Void

        init(onImage: @escaping (UIImage) -> Void, onFinish: @escaping () -> Void) {
            self.onImage = onImage
            self.onFinish = onFinish
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            }
            onFinish()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish()
        }
    }
}
