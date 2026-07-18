import CloudKit
import SwiftUI
import UIKit

/// `UICloudSharingController` wrapped for SwiftUI (plan §3.3): invites,
/// participant management, and stop-sharing for the zone-wide household
/// share. Owner-only — participants manage their membership from the Family
/// screen ("Leave Household"), not from here.
struct CloudSharingView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    /// Fired after the controller saves changes to the share (invites sent,
    /// participants removed) — the caller refreshes its roster copy.
    let onShareSaved: () -> Void
    /// Fired after the owner stops sharing entirely.
    let onStopSharing: () -> Void
    let onError: (Error) -> Void

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.delegate = context.coordinator
        // Read-write for the family (D8); no public access.
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        private let parent: CloudSharingView

        init(_ parent: CloudSharingView) {
            self.parent = parent
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            HouseholdShare.title
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            parent.onShareSaved()
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            parent.onStopSharing()
        }

        func cloudSharingController(
            _ csc: UICloudSharingController, failedToSaveShareWithError error: Error
        ) {
            Log.sync.error("Share save failed: \(String(describing: error))")
            parent.onError(error)
        }
    }
}
