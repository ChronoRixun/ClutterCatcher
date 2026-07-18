import CoreGraphics
import Foundation
import PDFKit
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

    // MARK: Start offset (reprint onto a partially-used sheet, OPEN_ITEMS Q5)

    @Test func startOffsetZeroLeavesMappingUnchanged() {
        let spec = LabelSheetSpec.avery5163
        #expect(spec.position(forLabelIndex: 0, startingAt: 0) == (0, 0))
        #expect(spec.position(forLabelIndex: 9, startingAt: 0) == (0, 9))
        #expect(spec.position(forLabelIndex: 12, startingAt: 0) == (1, 2))
        #expect(spec.pageCount(forLabelCount: 10, startingAt: 0) == 1)
    }

    @Test func startOffsetShiftsLabelsIntoLaterCells() {
        let spec = LabelSheetSpec.avery5163
        #expect(spec.position(forLabelIndex: 0, startingAt: 3) == (0, 3))
        #expect(spec.position(forLabelIndex: 6, startingAt: 3) == (0, 9))
        #expect(spec.position(forLabelIndex: 7, startingAt: 3) == (1, 0))
    }

    @Test func pageCountAccountsForStartOffset() {
        let spec = LabelSheetSpec.avery5163
        #expect(spec.pageCount(forLabelCount: 7, startingAt: 3) == 1)
        #expect(spec.pageCount(forLabelCount: 8, startingAt: 3) == 2)
        #expect(spec.pageCount(forLabelCount: 0, startingAt: 5) == 0)
        #expect(spec.pageCount(forLabelCount: 1, startingAt: 9) == 1)
        #expect(spec.pageCount(forLabelCount: 2, startingAt: 9) == 2)
        #expect(spec.pageCount(forLabelCount: 21, startingAt: 9) == 3)
    }

    @Test func renderedPDFHonorsStartOffsetPagination() {
        let spec = LabelSheetSpec.avery5163
        let labels = (0..<8).map {
            LabelPDFRenderer.Label(
                payload: .container(UUID()),
                title: "Bin \($0)",
                subtitle: nil)
        }
        let renderer = LabelPDFRenderer(spec: spec)
        let flush = PDFDocument(data: renderer.renderPDF(labels: labels))
        let offset = PDFDocument(data: renderer.renderPDF(labels: labels, startOffset: 3))
        #expect(flush?.pageCount == 1)
        #expect(offset?.pageCount == 2)
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
