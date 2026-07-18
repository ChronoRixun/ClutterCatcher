import CoreGraphics
import Foundation
import Testing
@testable import ClutterCatcher

@Suite struct LabelLayoutTests {
    @Test func presetGridCounts() {
        #expect(LabelSheetSpec.avery5163.cellsPerPage == 10)
        #expect(LabelSheetSpec.avery5160.cellsPerPage == 30)
    }

    @Test func pageCountPaginatesCorrectly() {
        let spec = LabelSheetSpec.avery5163
        #expect(spec.pageCount(forLabelCount: 0) == 0)
        #expect(spec.pageCount(forLabelCount: 1) == 1)
        #expect(spec.pageCount(forLabelCount: 10) == 1)
        #expect(spec.pageCount(forLabelCount: 11) == 2)
        #expect(spec.pageCount(forLabelCount: 25) == 3)
    }

    @Test func labelIndexMapsToPageAndCell() {
        let spec = LabelSheetSpec.avery5163
        #expect(spec.position(forLabelIndex: 0) == (0, 0))
        #expect(spec.position(forLabelIndex: 9) == (0, 9))
        #expect(spec.position(forLabelIndex: 12) == (1, 2))
    }

    @Test func allCellsStayWithinPageBounds() {
        for spec in LabelSheetSpec.presets {
            let page = CGRect(origin: .zero, size: spec.pageSize)
            for index in 0..<spec.cellsPerPage {
                let cell = spec.cellRect(at: index)
                #expect(page.contains(cell), "\(spec.id) cell \(index) escapes the page")
            }
        }
    }

    @Test func cellsNeverOverlap() {
        for spec in LabelSheetSpec.presets {
            // Pitch at least cell size means neighbors can touch, not overlap.
            #expect(spec.horizontalPitch >= spec.cellSize.width)
            #expect(spec.verticalPitch >= spec.cellSize.height)

            let rects = (0..<spec.cellsPerPage).map { spec.cellRect(at: $0) }
            for i in rects.indices {
                for j in rects.indices where i < j {
                    let overlap = rects[i].intersection(rects[j])
                    #expect(
                        overlap.isNull || overlap.width == 0 || overlap.height == 0,
                        "\(spec.id) cells \(i) and \(j) overlap")
                }
            }
        }
    }

    @Test func cellRowMajorOrdering() {
        let spec = LabelSheetSpec.avery5163
        let first = spec.cellRect(at: 0)
        let second = spec.cellRect(at: 1)
        let third = spec.cellRect(at: 2)
        #expect(second.minX > first.minX)
        #expect(second.minY == first.minY)
        #expect(third.minX == first.minX)
        #expect(third.minY > first.minY)
    }
}
