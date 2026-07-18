import Foundation
import Observation

/// UI-facing sync state. Written by `SyncCoordinator`, read by Settings.
/// M2 keeps the surface to one row; the full status UI is M6.
@MainActor @Observable final class SyncStatusModel {
    enum Phase: Equatable {
        /// The coordinator hasn't reported yet (also what previews show).
        case starting
        /// Sync is off — the app works fully, changes stay on-device.
        case off(reason: String)
        case syncing
        case upToDate
        case error(message: String)
    }

    var phase: Phase = .starting

    var label: String {
        switch phase {
        case .starting: "Starting…"
        case .off(let reason): "Off (\(reason))"
        case .syncing: "iCloud — syncing…"
        case .upToDate: "iCloud — up to date"
        case .error(let message): "Error — \(message)"
        }
    }
}
