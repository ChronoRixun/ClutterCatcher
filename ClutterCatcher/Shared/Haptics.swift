import UIKit

/// T10 haptics — they ship for every theme, Classic included. Deliberately
/// not gated on Reduce Motion: haptics aren't motion, and the system offers
/// its own vibration controls. No sounds anywhere (T10 — deferred until
/// someone misses one).
@MainActor
enum Haptics {
    /// Scan-found: the "Found it!" card just presented.
    static func scanSuccess() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// A save committed (any editor).
    static func saveSoftImpact() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }
}
