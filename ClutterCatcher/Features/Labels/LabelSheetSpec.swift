import CoreGraphics
import Foundation

/// The geometry of an Avery-style label sheet: a rows × columns grid of
/// identical cells on a page, positioned by margins and pitch (the distance
/// between neighboring cell origins — pitch ≥ cell size, the difference being
/// the gutter). Pure math so the layout is unit-testable; dimensions in
/// PDF points (1″ = 72 pt).
///
/// ⚠️ Preset margins approximate the Avery templates. Before a real printing
/// session, calibrate against one sacrificial sheet (device-only step).
struct LabelSheetSpec: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let pageSize: CGSize
    let leftMargin: CGFloat
    let topMargin: CGFloat
    let columns: Int
    let rows: Int
    let cellSize: CGSize
    let horizontalPitch: CGFloat
    let verticalPitch: CGFloat

    var cellsPerPage: Int { columns * rows }

    /// The rect for a cell by its on-page index (0-based, row-major).
    func cellRect(at index: Int) -> CGRect {
        precondition((0..<cellsPerPage).contains(index), "cell index out of range")
        let row = index / columns
        let column = index % columns
        return CGRect(
            x: leftMargin + CGFloat(column) * horizontalPitch,
            y: topMargin + CGFloat(row) * verticalPitch,
            width: cellSize.width,
            height: cellSize.height)
    }

    /// `offset` leading cells on page one stay blank — reprinting onto a
    /// partially-used sheet skips its used stickers.
    func pageCount(forLabelCount count: Int, startingAt offset: Int = 0) -> Int {
        guard count > 0 else { return 0 }
        return (offset + count + cellsPerPage - 1) / cellsPerPage
    }

    /// Splits a 0-based label position into (page, cell-on-page), after
    /// skipping `offset` cells at the start of page one.
    func position(forLabelIndex index: Int, startingAt offset: Int = 0) -> (page: Int, cell: Int) {
        ((index + offset) / cellsPerPage, (index + offset) % cellsPerPage)
    }

    // MARK: Presets (US Letter, 612 × 792 pt)

    /// Avery 5163-style: 2 × 5 grid of 4″ × 2″ shipping labels. Roomy —
    /// the default for bins on shelves.
    static let avery5163 = LabelSheetSpec(
        id: "avery5163",
        name: "Large — 4″ × 2″ (10/sheet)",
        pageSize: CGSize(width: 612, height: 792),
        leftMargin: 18,
        topMargin: 36,
        columns: 2,
        rows: 5,
        cellSize: CGSize(width: 288, height: 144),
        horizontalPitch: 288,
        verticalPitch: 144)

    /// Avery 5160-style: 3 × 10 grid of 2.625″ × 1″ address labels. Dense —
    /// for drawers and small boxes.
    static let avery5160 = LabelSheetSpec(
        id: "avery5160",
        name: "Small — 2⅝″ × 1″ (30/sheet)",
        pageSize: CGSize(width: 612, height: 792),
        leftMargin: 13.5,
        topMargin: 36,
        columns: 3,
        rows: 10,
        cellSize: CGSize(width: 189, height: 72),
        horizontalPitch: 198,
        verticalPitch: 72)

    static let presets: [LabelSheetSpec] = [.avery5163, .avery5160]

    static func preset(id: String) -> LabelSheetSpec? {
        presets.first { $0.id == id }
    }
}
