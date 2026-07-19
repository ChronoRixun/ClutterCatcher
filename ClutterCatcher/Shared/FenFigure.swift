import SwiftUI

/// Fen, the geometric marsh fox (T9) — drawn as plain SwiftUI shapes from
/// `design/fen-geometry.md`, recolored per theme, never an image asset.
/// The eyes are separate shapes precisely so the blink is one animation.
///
/// M4a ships the open-eye base with the idle blink; ear-perk, the wink, and
/// the Arcade pixel sprite are M4b.
struct FenFigure: View {
    let colors: FenColors
    /// Callers can pin the figure static (previews, reduced contexts);
    /// Reduce Motion pauses the blink regardless.
    var isAnimated = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var eyesClosed = false

    private var blinkEnabled: Bool { isAnimated && !reduceMotion }

    var body: some View {
        FenFace(colors: colors, eyesClosed: eyesClosed)
            .aspectRatio(FenGeometry.size.width / FenGeometry.size.height, contentMode: .fit)
            // Purely decorative — the empty state's text carries the meaning.
            .accessibilityHidden(true)
            .task(id: blinkEnabled) {
                guard blinkEnabled else {
                    eyesClosed = false
                    return
                }
                // Idle cadence ~4–7 s, occasional double blink (§5). The task
                // is cancelled whenever the figure leaves the screen, which is
                // what keeps the timer paused off-screen.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Double.random(in: 4...7)))
                    guard !Task.isCancelled else { break }
                    await blink()
                    if Bool.random(), Bool.random() { // ~25%: double blink
                        try? await Task.sleep(for: .milliseconds(160))
                        guard !Task.isCancelled else { break }
                        await blink()
                    }
                }
            }
    }

    private func blink() async {
        withAnimation(.easeIn(duration: 0.07)) { eyesClosed = true }
        try? await Task.sleep(for: .milliseconds(110))
        withAnimation(.easeOut(duration: 0.1)) { eyesClosed = false }
    }
}

// MARK: - Face

private struct FenFace: View {
    let colors: FenColors
    let eyesClosed: Bool

    var body: some View {
        ZStack {
            // Ears, then head over their bases.
            FenPolygon(points: FenGeometry.leftEar).fill(Color(srgbHex: colors.body))
            FenPolygon(points: FenGeometry.rightEar).fill(Color(srgbHex: colors.body))
            FenPolygon(points: FenGeometry.leftInnerEar)
                .fill(Color(srgbHex: colors.innerEar).opacity(colors.innerEarOpacity))
            FenPolygon(points: FenGeometry.rightInnerEar)
                .fill(Color(srgbHex: colors.innerEar).opacity(colors.innerEarOpacity))
            FenEllipse(center: FenGeometry.headCenter, rx: 26, ry: 26)
                .fill(Color(srgbHex: colors.body))
            FenEllipse(center: FenGeometry.muzzleCenter, rx: 15, ry: 12)
                .fill(Color(srgbHex: colors.muzzle))

            // Eyes squash toward closed about their own centers; the
            // highlights fade out during the closed phase (§5).
            FenEllipse(center: FenGeometry.leftEyeCenter, rx: 3.2, ry: 3.2)
                .fill(Color(srgbHex: colors.eye))
                .scaleEffect(y: eyesClosed ? 0.1 : 1, anchor: FenGeometry.anchor(FenGeometry.leftEyeCenter))
            FenEllipse(center: FenGeometry.rightEyeCenter, rx: 3.2, ry: 3.2)
                .fill(Color(srgbHex: colors.eye))
                .scaleEffect(y: eyesClosed ? 0.1 : 1, anchor: FenGeometry.anchor(FenGeometry.rightEyeCenter))
            Group {
                FenEllipse(center: CGPoint(x: 34.2, y: 43.8), rx: 1, ry: 1)
                    .fill(.white)
                FenEllipse(center: CGPoint(x: 52.2, y: 43.8), rx: 1, ry: 1)
                    .fill(.white)
            }
            .opacity(eyesClosed ? 0 : 1)

            FenEllipse(center: FenGeometry.noseCenter, rx: 3, ry: 2.4)
                .fill(Color(srgbHex: colors.nose))
        }
    }
}

// MARK: - Geometry (design/fen-geometry.md)

/// Fen's design space: the source viewBox is `7 3 70 74`, so raw coordinates
/// carry that origin and every mapping subtracts it.
private enum FenGeometry {
    static let origin = CGPoint(x: 7, y: 3)
    static let size = CGSize(width: 70, height: 74)

    static let leftEar = [CGPoint(x: 18, y: 34), CGPoint(x: 24, y: 8), CGPoint(x: 42, y: 26)]
    static let rightEar = [CGPoint(x: 66, y: 34), CGPoint(x: 60, y: 8), CGPoint(x: 42, y: 26)]
    static let leftInnerEar = [CGPoint(x: 21.5, y: 30), CGPoint(x: 25.5, y: 14), CGPoint(x: 36, y: 25)]
    static let rightInnerEar = [CGPoint(x: 62.5, y: 30), CGPoint(x: 58.5, y: 14), CGPoint(x: 48, y: 25)]
    static let headCenter = CGPoint(x: 42, y: 48)
    static let muzzleCenter = CGPoint(x: 42, y: 58)
    static let leftEyeCenter = CGPoint(x: 33, y: 45)
    static let rightEyeCenter = CGPoint(x: 51, y: 45)
    static let noseCenter = CGPoint(x: 42, y: 53)

    static func map(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + (point.x - origin.x) / size.width * rect.width,
            y: rect.minY + (point.y - origin.y) / size.height * rect.height)
    }

    /// The design-space point as a scale anchor within the figure's frame.
    static func anchor(_ point: CGPoint) -> UnitPoint {
        UnitPoint(x: (point.x - origin.x) / size.width, y: (point.y - origin.y) / size.height)
    }
}

private struct FenPolygon: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: FenGeometry.map(first, in: rect))
        for point in points.dropFirst() {
            path.addLine(to: FenGeometry.map(point, in: rect))
        }
        path.closeSubpath()
        return path
    }
}

private struct FenEllipse: Shape {
    let center: CGPoint
    let rx: CGFloat
    let ry: CGFloat

    func path(in rect: CGRect) -> Path {
        let topLeft = FenGeometry.map(
            CGPoint(x: center.x - rx, y: center.y - ry), in: rect)
        let bottomRight = FenGeometry.map(
            CGPoint(x: center.x + rx, y: center.y + ry), in: rect)
        return Path(ellipseIn: CGRect(
            x: topLeft.x, y: topLeft.y,
            width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y))
    }
}
