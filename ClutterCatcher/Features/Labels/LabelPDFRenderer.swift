import UIKit

/// Renders a paginated label-sheet PDF: one QR label per grid cell, laid out
/// by a `LabelSheetSpec`, via `UIGraphicsPDFRenderer` (plan §3.4).
struct LabelPDFRenderer {
    struct Label {
        let payload: QRPayload
        let title: String
        let subtitle: String?
    }

    let spec: LabelSheetSpec

    /// Labels fill cells sequentially, row-major, page by page.
    func renderPDF(labels: [Label]) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "ClutterCatcher Labels",
            kCGPDFContextCreator as String: "ClutterCatcher",
        ]
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: spec.pageSize),
            format: format)

        return renderer.pdfData { context in
            for pageIndex in 0..<spec.pageCount(forLabelCount: labels.count) {
                context.beginPage()
                let pageStart = pageIndex * spec.cellsPerPage
                let pageLabels = labels[pageStart..<min(pageStart + spec.cellsPerPage, labels.count)]
                for (offset, label) in pageLabels.enumerated() {
                    draw(label, in: spec.cellRect(at: offset), context: context.cgContext)
                }
            }
        }
    }

    /// One cell: QR square on the left, title/subtitle to its right. The QR
    /// side length is the cell height minus padding; text gets the remainder.
    private func draw(_ label: Label, in cell: CGRect, context: CGContext) {
        let padding = min(8, cell.height * 0.08)
        let content = cell.insetBy(dx: padding, dy: padding)

        let qrSide = content.height
        let qrRect = CGRect(x: content.minX, y: content.minY, width: qrSide, height: qrSide)
        if let qr = QRCodeGenerator.cgImage(for: label.payload) {
            // Draw pixel-exact modules — interpolation would blur the code.
            context.saveGState()
            context.interpolationQuality = .none
            // CGContext draws images flipped relative to UIKit's coordinates.
            context.translateBy(x: qrRect.minX, y: qrRect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(qr, in: CGRect(origin: .zero, size: qrRect.size))
            context.restoreGState()
        }

        let textX = qrRect.maxX + padding
        let textRect = CGRect(
            x: textX,
            y: content.minY,
            width: max(0, content.maxX - textX),
            height: content.height)
        guard textRect.width > 20 else { return }

        let titleFont = UIFont.systemFont(
            ofSize: max(9, min(16, cell.height * 0.14)), weight: .semibold)
        let subtitleFont = UIFont.systemFont(
            ofSize: max(7, min(12, cell.height * 0.10)), weight: .regular)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        let title = NSAttributedString(string: label.title, attributes: [
            .font: titleFont,
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph,
        ])
        let titleBounds = title.boundingRect(
            with: CGSize(width: textRect.width, height: textRect.height),
            options: [.usesLineFragmentOrigin],
            context: nil)

        var subtitle: NSAttributedString?
        var subtitleHeight: CGFloat = 0
        if let subtitleText = label.subtitle {
            let attributed = NSAttributedString(string: subtitleText, attributes: [
                .font: subtitleFont,
                .foregroundColor: UIColor.darkGray,
                .paragraphStyle: paragraph,
            ])
            subtitle = attributed
            subtitleHeight = attributed.boundingRect(
                with: CGSize(width: textRect.width, height: textRect.height),
                options: [.usesLineFragmentOrigin],
                context: nil).height
        }

        // Vertically center the text block beside the QR square.
        let blockHeight = titleBounds.height + (subtitle == nil ? 0 : 2 + subtitleHeight)
        var cursorY = textRect.minY + max(0, (textRect.height - blockHeight) / 2)

        title.draw(
            with: CGRect(x: textRect.minX, y: cursorY, width: textRect.width, height: titleBounds.height),
            options: [.usesLineFragmentOrigin],
            context: nil)
        cursorY += titleBounds.height + 2

        subtitle?.draw(
            with: CGRect(x: textRect.minX, y: cursorY, width: textRect.width, height: subtitleHeight),
            options: [.usesLineFragmentOrigin],
            context: nil)
    }
}
