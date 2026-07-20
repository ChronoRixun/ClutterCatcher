import SwiftUI

/// M6.2 (iPad): size-class-driven layout adaptation. The decisions are pure
/// functions here so they're unit-testable; views apply them through the
/// modifiers below. Compact width is always the untouched iPhone layout —
/// every helper is a structural no-op there, the same discipline as
/// Classic's theming no-op (DL54).
enum AdaptiveLayout {
    /// Width cap for text-heavy content (forms, lists, detail screens) in
    /// regular width — the readable-content ballpark at standard type sizes.
    static let readableMaxWidth: CGFloat = 672

    /// nil = no constraint (compact width keeps the iPhone layout).
    static func contentMaxWidth(isRegularWidth: Bool) -> CGFloat? {
        isRegularWidth ? readableMaxWidth : nil
    }

    /// Rooms-home grid (the T11 tiles' regular-width home): 2–4 columns
    /// targeting ~300–400 pt tiles. Compact keeps the list, so 2 is the
    /// floor — a one-column grid would just be a padded list.
    static func roomGridColumnCount(forWidth width: CGFloat) -> Int {
        max(2, min(4, Int(width / 300)))
    }
}

extension View {
    /// Constrains a grouped List/Form screen to a readable width in regular
    /// horizontal size class, filling the released side space with the
    /// screen's own background so themed surfaces stay edge to edge at any
    /// window size (Split View, Slide Over, Stage Manager).
    func readableContentWidth() -> some View {
        modifier(ReadableWidthModifier())
    }
}

private struct ReadableWidthModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(ThemeStore.self) private var themeStore

    @ViewBuilder
    func body(content: Content) -> some View {
        if let maxWidth = AdaptiveLayout.contentMaxWidth(
            isRegularWidth: horizontalSizeClass == .regular) {
            content
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
                .background(backdrop)
        } else {
            content
        }
    }

    /// What shows beside the constrained content: the theme's screen
    /// background, or — for Classic — the grouped background the List/Form
    /// paints inside its own frame, so the sides match seamlessly.
    private var backdrop: Color {
        let theme = themeStore.theme
        return theme.isClassic ? Color(.systemGroupedBackground) : theme.bg
    }
}
