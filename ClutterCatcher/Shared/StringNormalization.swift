import Foundation

/// The one definition of "clean text" for stored fields, shared by every
/// repository so entities can't drift apart in what counts as empty.
extension String {
    /// Whitespace-trimmed, for required fields (names).
    var normalizedName: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Optional<String> {
    /// Whitespace-trimmed with empty collapsed to nil, for optional
    /// free-text fields (notes).
    var normalizedNotes: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
