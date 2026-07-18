import UIKit

/// Renders a paginated label-sheet PDF: one QR label per grid cell, laid out
/// by a `LabelSheetSpec`, via `UIGraphicsPDFRenderer` (plan §3.4).
/// Rendering is pure and safe off the main actor.
struct LabelPDFRenderer: Sendable {
    struct Label: Sendable {
        let payload: QRPayload
        let title: String
        let subtitle: String?
    }

    let spec: LabelSheetSpec

    /// Labels fill cells sequentially, row-major, page by page — the same
    /// `position(forLabelIndex:)` mapping the layout tests exercise.
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
            var currentPage = -1
            for (index, label) in labels.enumerated() {
                let (page, cell) = spec.position(forLabelIndex: index)
                if page != currentPage {
                    context.beginPage()
                    currentPage = page
                }
                draw(label, in: spec.cellRect(at: cell), context: context.cgContext)
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
        // A long name must never bleed into the neighboring sticker: cap the
        // title at two lines, the subtitle at one, and hard-clip to the cell.
        let titleHeight = min(
            title.boundingRect(
                with: CGSize(width: textRect.width, height: textRect.height),
                options: [.usesLineFragmentOrigin],
                context: nil).height,
            ceil(titleFont.lineHeight * 2))

        var subtitle: NSAttributedString?
        var subtitleHeight: CGFloat = 0
        if let subtitleText = label.subtitle {
            let attributed = NSAttributedString(string: subtitleText, attributes: [
                .font: subtitleFont,
                .foregroundColor: UIColor.darkGray,
                .paragraphStyle: paragraph,
            ])
            subtitle = attributed
            subtitleHeight = ceil(subtitleFont.lineHeight)
        }

        context.saveGState()
        context.clip(to: cell)

        // Vertically center the text block beside the QR square.
        let blockHeight = titleHeight + (subtitle == nil ? 0 : 2 + subtitleHeight)
        var cursorY = textRect.minY + max(0, (textRect.height - blockHeight) / 2)

        title.draw(
            with: CGRect(x: textRect.minX, y: cursorY, width: textRect.width, height: titleHeight),
            options: [.usesLineFragmentOrigin],
            context: nil)
        cursorY += titleHeight + 2

        subtitle?.draw(
            with: CGRect(x: textRect.minX, y: cursorY, width: textRect.width, height: subtitleHeight),
            options: [.usesLineFragmentOrigin],
            context: nil)

        context.restoreGState()
    }
}
