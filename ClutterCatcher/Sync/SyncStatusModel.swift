import Foundation
import Observation

/// UI-facing sync state. Written by `SyncCoordinator`, read by Settings, the
/// Family screen, and the root banner. The full status UI is M6.
@MainActor @Observable final class SyncStatusModel {
    enum Phase: Equatable {
        /// The coordinator hasn't reported yet (also what previews show).
        case starting
        /// Sync is off — the app works fully, changes stay on-device.
        case off(reason: String)
        case syncing
        case upToDate
        /// Participant lost household access (M3-E): catalog kept locally,
        /// persistent banner, Family offers the way back in.
        case disconnected
        case error(message: String)
    }

    var phase: Phase = .starting

    /// This device's household role, as the coordinator last resolved it.
    /// nil until onboarding decides (or while sync state is unreadable).
    var role: SyncRole?

    var label: String {
        switch phase {
        case .starting: "Starting…"
        case .off(let reason): "Off (\(reason))"
        case .syncing: "iCloud — syncing…"
        case .upToDate: "iCloud — up to date"
        case .disconnected: "Off (no longer connected to the household)"
        case .error(let message): "Error — \(message)"
        }
    }
}
