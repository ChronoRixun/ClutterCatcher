import SwiftUI

/// How Fen renders (T9/§5): Arcade's full-sprite presence is the pixel
/// variant from `design/fen-geometry.md`; every other Fen-bearing theme is
/// the smooth figure.
enum FenStyle: Sendable {
    case smooth, pixel
}

extension Theme {
    var fenStyle: FenStyle { fenPresence == .fullSprite ? .pixel : .smooth }

    /// Arcade's sprite glow (fen-geometry.md: soft accent shadow, scaled to
    /// render size); nil for everyone else.
    var fenGlow: Color? { fenPresence == .fullSprite ? accent : nil }
}

/// Fen, the geometric marsh fox (T9) — drawn as plain SwiftUI shapes from
/// `design/fen-geometry.md`, recolored per theme, never an image asset.
/// The eyes are separate shapes precisely so the blink is one animation.
///
/// M4a shipped the open-eye base with the idle blink. M4b adds the wink
/// (`winkTrigger`), the ear perk (`earPerkTrigger`), and the Arcade pixel
/// variant (`style: .pixel`, with its accent glow). All of them are motion:
/// Reduce Motion pauses the blink and suppresses wink and perk entirely.
struct FenFigure: View {
    let colors: FenColors
    var style: FenStyle = .smooth
    /// Arcade's soft accent glow around the sprite; nil = none.
    var glow: Color? = nil
    /// Callers can pin the figure static (previews, reduced contexts);
    /// Reduce Motion pauses the blink regardless.
    var isAnimated = true
    /// Increment to make Fen wink once (right eye swaps for the arc).
    /// Smooth style only — the pixel sprite has no wink geometry.
    var winkTrigger = 0
    /// Increment to briefly perk the ears (~4° up, per the geometry doc).
    var earPerkTrigger = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var eyesClosed = false
    @State private var winking = false
    @State private var earsPerked = false

    private var blinkEnabled: Bool { isAnimated && !reduceMotion }

    var body: some View {
        face
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
            .task(id: winkTrigger) {
                guard winkTrigger > 0, blinkEnabled, style == .smooth else { return }
                withAnimation(.easeIn(duration: 0.08)) { winking = true }
                try? await Task.sleep(for: .milliseconds(380))
                withAnimation(.easeOut(duration: 0.12)) { winking = false }
            }
            .task(id: earPerkTrigger) {
                guard earPerkTrigger > 0, blinkEnabled else { return }
                withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) { earsPerked = true }
                try? await Task.sleep(for: .milliseconds(260))
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { earsPerked = false }
            }
    }

    @ViewBuilder private var face: some View {
        let face = FenFace(
            colors: colors, style: style, eyesClosed: eyesClosed,
            winking: winking, earsPerked: earsPerked)
        if let glow {
            GeometryReader { proxy in
                face
                    // Flatten first so the glow hugs the whole silhouette
                    // rather than each shape casting its own shadow.
                    .compositingGroup()
                    .shadow(color: glow.opacity(0.55), radius: proxy.size.height * 0.06)
            }
        } else {
            face
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
    let style: FenStyle
    let eyesClosed: Bool
    let winking: Bool
    let earsPerked: Bool

    var body: some View {
        ZStack {
            // Ears, then head over their bases. Each ear group (outer +
            // inner shadow) perks as one about its own base, tips outward.
            Group {
                FenPolygon(points: FenGeometry.leftEar).fill(Color(srgbHex: colors.body))
                FenPolygon(points: FenGeometry.leftInnerEar)
                    .fill(Color(srgbHex: colors.innerEar).opacity(colors.innerEarOpacity))
            }
            .rotationEffect(.degrees(earsPerked ? -4 : 0), anchor: FenGeometry.leftEarAnchor)
            Group {
                FenPolygon(points: FenGeometry.rightEar).fill(Color(srgbHex: colors.body))
                FenPolygon(points: FenGeometry.rightInnerEar)
                    .fill(Color(srgbHex: colors.innerEar).opacity(colors.innerEarOpacity))
            }
            .rotationEffect(.degrees(earsPerked ? 4 : 0), anchor: FenGeometry.rightEarAnchor)

            FenEllipse(center: FenGeometry.headCenter, rx: 26, ry: 26)
                .fill(Color(srgbHex: colors.body))
            FenEllipse(center: FenGeometry.muzzleCenter, rx: 15, ry: 12)
                .fill(Color(srgbHex: colors.muzzle))

            switch style {
            case .smooth: smoothFeatures
            case .pixel: pixelFeatures
            }
        }
    }

    /// Eyes squash toward closed about their own centers; the highlights
    /// fade out during the closed phase (§5). While winking, the right eye
    /// and its highlight swap for the geometry doc's stroked arc.
    @ViewBuilder private var smoothFeatures: some View {
        FenEllipse(center: FenGeometry.leftEyeCenter, rx: 3.2, ry: 3.2)
            .fill(Color(srgbHex: colors.eye))
            .scaleEffect(y: eyesClosed ? 0.1 : 1, anchor: FenGeometry.anchor(FenGeometry.leftEyeCenter))
        FenEllipse(center: FenGeometry.rightEyeCenter, rx: 3.2, ry: 3.2)
            .fill(Color(srgbHex: colors.eye))
            .scaleEffect(y: eyesClosed ? 0.1 : 1, anchor: FenGeometry.anchor(FenGeometry.rightEyeCenter))
            .opacity(winking ? 0 : 1)
        FenWinkArc()
            .fill(Color(srgbHex: colors.eye))
            .opacity(winking ? 1 : 0)

        FenEllipse(center: CGPoint(x: 34.2, y: 43.8), rx: 1, ry: 1)
            .fill(.white)
            .opacity(eyesClosed ? 0 : 1)
        FenEllipse(center: CGPoint(x: 52.2, y: 43.8), rx: 1, ry: 1)
            .fill(.white)
            .opacity((eyesClosed || winking) ? 0 : 1)

        FenEllipse(center: FenGeometry.noseCenter, rx: 3, ry: 2.4)
            .fill(Color(srgbHex: colors.nose))
    }

    /// The Night Sprite variant: square eyes and a rect nose, no highlights.
    /// The blink still works — the squares squash exactly like the circles.
    @ViewBuilder private var pixelFeatures: some View {
        FenRect(x: 29.5, y: 41.5, width: 6, height: 6)
            .fill(Color(srgbHex: colors.eye))
            .scaleEffect(y: eyesClosed ? 0.12 : 1, anchor: FenGeometry.anchor(CGPoint(x: 32.5, y: 44.5)))
        FenRect(x: 48.5, y: 41.5, width: 6, height: 6)
            .fill(Color(srgbHex: colors.eye))
            .scaleEffect(y: eyesClosed ? 0.12 : 1, anchor: FenGeometry.anchor(CGPoint(x: 51.5, y: 44.5)))
        FenRect(x: 39.5, y: 51, width: 5, height: 4.5)
            .fill(Color(srgbHex: colors.nose))
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

    /// Ear-perk pivots: the midpoint of each ear's base edge, so the tips
    /// swing up and outward.
    static var leftEarAnchor: UnitPoint { anchor(CGPoint(x: 30, y: 30)) }
    static var rightEarAnchor: UnitPoint { anchor(CGPoint(x: 54, y: 30)) }

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

private struct FenRect: Shape {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    func path(in rect: CGRect) -> Path {
        let topLeft = FenGeometry.map(CGPoint(x: x, y: y), in: rect)
        let bottomRight = FenGeometry.map(CGPoint(x: x + width, y: y + height), in: rect)
        return Path(CGRect(
            x: topLeft.x, y: topLeft.y,
            width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y))
    }
}

/// The wink (fen-geometry.md): the right eye's replacement — a stroked arc,
/// pre-stroked into a fillable path so the width scales with the figure.
private struct FenWinkArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: FenGeometry.map(CGPoint(x: 47.8, y: 45.5), in: rect))
        path.addCurve(
            to: FenGeometry.map(CGPoint(x: 54.2, y: 45.5), in: rect),
            control1: FenGeometry.map(CGPoint(x: 49.4, y: 43.5), in: rect),
            control2: FenGeometry.map(CGPoint(x: 52.6, y: 43.5), in: rect))
        let lineWidth = 2.6 / FenGeometry.size.width * rect.width
        return path.strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }
}
