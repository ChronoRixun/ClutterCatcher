import Foundation

/// U3: the one-shot "Print a label for this bin?" offer after creating a
/// container. Pure in-memory state, deliberately unpersisted — the offer
/// exists only in the moment of creation, is dismissible, and never nags
/// again (T7's offer-never-auto-act pattern).
struct LabelNudgeState: Equatable {
    struct Offer: Equatable, Identifiable {
        let containerID: String
        let containerName: String

        /// `sheet(item:)` identity for the print flow.
        var id: String { containerID }
    }

    private(set) var offer: Offer?

    /// Every editor save reports through here; only a creation offers —
    /// never an edit (U3). A newer creation replaces any earlier offer.
    mutating func containerSaved(id: String, name: String, created: Bool) {
        guard created else { return }
        offer = Offer(containerID: id, containerName: name)
    }

    mutating func dismiss() {
        offer = nil
    }
}
