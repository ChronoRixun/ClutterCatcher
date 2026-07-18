import SwiftUI

/// Placeholder design tokens for the Liquid Glass era (D16).
///
/// ⚠️ PLACEHOLDER — replace with the token sheet from the chosen Claude Design
/// direction once `design/tokens.*` lands in the repo (plan §6). Until then:
/// system materials, one warm accent, Dynamic Type throughout, standard chrome
/// with color reserved for content.
enum Tokens {
    // MARK: Color

    /// Warm accent, mirrored by Assets.xcassets/AccentColor (light `#E09140`,
    /// dark `#F0A055`). Use `Color.accentColor` in views; this constant exists
    /// for non-view contexts (PDF rendering).
    static let accent = Color(red: 0xE0 / 255, green: 0x91 / 255, blue: 0x40 / 255)

    /// Colors for category tokens (`categories.color_token`). Muted system
    /// palette for now; the design pass may replace these with custom values.
    static func categoryColor(for token: String) -> Color {
        switch token {
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "mint": .mint
        case "teal": .teal
        case "cyan": .cyan
        case "blue": .blue
        case "indigo": .indigo
        case "purple": .purple
        case "pink": .pink
        case "brown": .brown
        default: .gray
        }
    }

    /// Every color token a category may use, in picker order.
    static let categoryColorTokens: [String] = [
        "red", "orange", "yellow", "green", "mint", "teal",
        "cyan", "blue", "indigo", "purple", "pink", "brown", "gray",
    ]

    // MARK: Metrics

    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 12
    static let spacingL: CGFloat = 20
    static let cornerRadius: CGFloat = 12

    // MARK: Iconography

    /// SF Symbols offered by the room icon picker. All available since iOS 15.
    static let roomIcons: [String] = [
        "fork.knife", "sofa", "bed.double", "lamp.desk", "car",
        "archivebox", "shippingbox", "stairs", "washer", "books.vertical",
        "gamecontroller", "tshirt", "wrench.and.screwdriver", "leaf", "house",
    ]

    static let defaultRoomIcon = "archivebox"
}
