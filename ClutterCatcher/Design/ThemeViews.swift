import SwiftUI

// Theme application helpers (T5): themes tint *content* — screen
// backgrounds, list-row surfaces, chips — while system bars, sheets, and
// materials keep their native treatment. Classic short-circuits to a no-op
// everywhere so the default look stays pixel-equivalent to the pre-M4 app.

extension View {
    /// Themed screen background for a List/Form/ScrollView-rooted screen.
    func themedScreen() -> some View {
        modifier(ThemedScreenModifier())
    }

    /// Themed list-row surface. Apply to section content, like
    /// `.listRowBackground` (which it wraps).
    func themedRow() -> some View {
        modifier(ThemedRowModifier())
    }
}

private struct ThemedScreenModifier: ViewModifier {
    @Environment(ThemeStore.self) private var themeStore

    @ViewBuilder
    func body(content: Content) -> some View {
        let theme = themeStore.theme
        if theme.isClassic {
            content
        } else {
            content
                .scrollContentBackground(.hidden)
                .background(theme.bg.ignoresSafeArea())
        }
    }
}

private struct ThemedRowModifier: ViewModifier {
    @Environment(ThemeStore.self) private var themeStore

    func body(content: Content) -> some View {
        let theme = themeStore.theme
        return content.listRowBackground(theme.isClassic ? nil : theme.surface)
    }
}

// MARK: - Drop-in (Pop!'s save reward, §6 M4b)

/// Pop!'s "drop-in" squash-settle: the inserted row lands slightly wide and
/// compressed, then un-squashes — the overshoot comes from the theme's
/// bouncy settle spring, not from this modifier.
private struct SquashModifier: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: active ? 1.03 : 1, y: active ? 0.6 : 1, anchor: .top)
            .opacity(active ? 0 : 1)
    }
}

extension AnyTransition {
    // Computed, not stored: AnyTransition isn't Sendable, so a static
    // stored property trips strict concurrency.
    static var dropInSquash: AnyTransition {
        .modifier(
            active: SquashModifier(active: true),
            identity: SquashModifier(active: false))
    }
}

// MARK: - Chips (T12)

/// A capsule chip whose tint is *derived*: the base color at ~13% opacity
/// for the fill, full-strength for the text — so category and room chips
/// work in all twelve palettes with no per-theme values (T12). `filled`
/// flips to a solid base with contrasting text (the item editor's selected
/// state, §4).
struct ThemedChip: View {
    let text: String
    let base: Color
    var filled = false
    /// Smaller type and padding, for chips inside list rows.
    var compact = false

    var body: some View {
        Text(text)
            .font((compact ? Font.caption : .subheadline).weight(.medium))
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 3 : 5)
            .foregroundStyle(filled ? Color.white : base)
            .background(filled ? base : base.opacity(0.13), in: Capsule())
    }
}

// MARK: - Flow layout

/// Minimal leading-aligned wrapping layout for chip rows (§4's item-editor
/// category picker). Rows break when the next subview would overflow the
/// proposed width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = layoutRows(width: proposal.width ?? .infinity, subviews: subviews)
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        let height = rows.last.map { $0.minY + $0.height } ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = layoutRows(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.range {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: bounds.minY + row.minY),
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var range: Range<Int>
        var minY: CGFloat
        var height: CGFloat
        var width: CGFloat
    }

    private func layoutRows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var start = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if index > start, x + size.width > width {
                rows.append(Row(range: start..<index, minY: y, height: rowHeight, width: x - spacing))
                start = index
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        if start < subviews.count {
            rows.append(Row(range: start..<subviews.count, minY: y, height: rowHeight, width: x - spacing))
        }
        return rows
    }
}
