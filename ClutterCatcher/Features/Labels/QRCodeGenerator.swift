import CoreImage.CIFilterBuiltins
import UIKit

/// Renders QR codes for label payloads via CoreImage, error correction
/// level Q (plan §3.4) — sturdy enough for small print with a finger-smudge
/// margin.
enum QRCodeGenerator {
    // CIContext is documented thread-safe ("CIContext objects are immutable,
    // so they can be shared safely between threads"), it just predates
    // Sendable annotations — hence the unsafe opt-out.
    private nonisolated(unsafe) static let context = CIContext()

    /// The QR code as a CGImage, `moduleScale` pixels per module. Nil only if
    /// CoreImage fails outright (never in practice for our short payloads).
    static func cgImage(for payload: QRPayload, moduleScale: CGFloat = 12) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.absoluteString.utf8)
        filter.correctionLevel = "Q"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(
            by: CGAffineTransform(scaleX: moduleScale, y: moduleScale))
        return context.createCGImage(scaled, from: scaled.extent)
    }

    static func image(for payload: QRPayload, moduleScale: CGFloat = 12) -> UIImage? {
        cgImage(for: payload, moduleScale: moduleScale).map { UIImage(cgImage: $0) }
    }
}
