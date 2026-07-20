import SwiftUI

/// The §4 "Found it!" card, now with its M4b per-theme personality (§6).
/// The card's semantics are DL57's and unchanged: "Open It Up" navigates,
/// the quiet "Scan Again" is the not-that-bin escape. What varies by theme
/// is only the reward moment:
///
/// - Pop!: one-shot confetti-dot burst + Fen peeks over the card edge,
///   winking as the flourish settles.
/// - Arcade: accent glow breathing on the card + score-tick count-up.
/// - Fresh: a small leaf draws itself in beside the container line.
/// - Cozy: the soft entrance settle is the whole moment — no burst.
/// - Classic / Dusk Redux: the standard card.
///
/// Reduce Motion collapses every style to the standard card (the entrance
/// fade lives in ScanView); Fen still peeks — presence is identity, not
/// motion — but arrives with the fade, already settled, and never winks.
struct ScanSuccessCard: View {
    let name: String
    let roomName: String
    let itemCount: Int
    /// Fresh identity per card presentation; re-scans mint a new one. The
    /// one-shot confetti guard keys off it.
    let presentationID: UUID
    /// Owned by ScanView so the guard outlives this view — a recycled or
    /// re-attached card must not re-fire for a presentation it already saw.
    @Binding var confettiGuard: ConfettiGuard
    /// Also ScanView-owned: List rows get torn down and recreated around
    /// the keyboard-collapse/section-swap moment (observed in-sim), and a
    /// card-local burst state dies with the first instance right after it
    /// consumed the guard — leaving the recreated card with no confetti.
    @Binding var confettiBurstID: UUID?
    let onOpen: () -> Void
    let onScanAgain: () -> Void

    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var shownCount: Int
    @State private var glowStrength: Double = 0
    @State private var leafProgress: Double = 0
    @State private var fenPeeked = false
    @State private var fenWinkTrigger = 0

    init(
        name: String, roomName: String, itemCount: Int, presentationID: UUID,
        confettiGuard: Binding<ConfettiGuard>, confettiBurstID: Binding<UUID?>,
        onOpen: @escaping () -> Void, onScanAgain: @escaping () -> Void
    ) {
        self.name = name
        self.roomName = roomName
        self.itemCount = itemCount
        self.presentationID = presentationID
        _confettiGuard = confettiGuard
        _confettiBurstID = confettiBurstID
        self.onOpen = onOpen
        self.onScanAgain = onScanAgain
        _shownCount = State(initialValue: itemCount)
    }

    var body: some View {
        let theme = themeStore.theme
        let reward = theme.motion.scanReward(reduceMotion: reduceMotion)
        ZStack(alignment: .top) {
            // Pop!'s medium presence (§5): Fen rises from behind the card's
            // top edge. Declared first so the card hides everything but the
            // peek; opacity rides along so nothing ghosts through the
            // card's material while hidden.
            if theme.fenPresence == .medium, let fenColors = theme.fenColors {
                FenFigure(colors: fenColors, winkTrigger: fenWinkTrigger)
                    .frame(height: 56)
                    .offset(y: fenPeeked ? -40 : 8)
                    .opacity(fenPeeked ? 1 : 0)
            }
            card(theme: theme, reward: reward)
                // The burst rides the card as an overlay so the Canvas is
                // proposed the card's concrete size — as a ZStack sibling in
                // a list row it collapses to no height and draws nothing.
                .overlay {
                    // Only this presentation's burst — a stale id from an
                    // earlier card must not decorate a fresh one.
                    if confettiBurstID == presentationID {
                        ConfettiBurst(colors: theme.accentCycle)
                            .id(presentationID)
                            .padding(-80) // room to fly past the card's edges
                            .allowsHitTesting(false)
                    }
                }
        }
        .task(id: presentationID) {
            await runRewardMoment(reward: reward, theme: theme)
        }
    }

    private func card(theme: Theme, reward: MotionPersonality.ScanReward) -> some View {
        VStack(spacing: Tokens.spacingM) {
            Text("Found it!")
                .font(.title2.bold())
            HStack(spacing: 6) {
                if reward == .leafUnfurl {
                    LeafShape()
                        .trim(from: 0, to: leafProgress)
                        .stroke(
                            theme.success,
                            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .frame(width: 13, height: 16)
                        .accessibilityHidden(true)
                }
                Text("\(name) · \(roomName) · ^[\(shownCount) item](inflect: true)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.numericText(value: Double(shownCount)))
            }
            Button("Open It Up", action: onOpen)
                .buttonStyle(.borderedProminent)
            Button("Scan Again", action: onScanAgain)
                .font(.subheadline)
        }
        .padding(Tokens.spacingL)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Tokens.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.cornerRadius)
                .strokeBorder(theme.accent.opacity(glowStrength * 0.7), lineWidth: 1.5)
        }
        .compositingGroup()
        .shadow(color: theme.accent.opacity(glowStrength * 0.55), radius: 18)
    }

    /// One pass per presentation (`task(id:)`): haptic, then the theme's
    /// moment. Sleeps are cancelled cleanly when the card leaves.
    private func runRewardMoment(reward: MotionPersonality.ScanReward, theme: Theme) async {
        // Scan-found success haptic — every theme (T10).
        Haptics.scanSuccess()

        // Reset for this presentation (a re-scan re-runs this task). The
        // burst id is cleared only when it belongs to an older card — this
        // task also re-runs when a recreated row re-appears mid-moment, and
        // that must not kill a burst already earned.
        if confettiBurstID != presentationID { confettiBurstID = nil }
        leafProgress = 0
        glowStrength = 0
        fenPeeked = false
        shownCount = itemCount

        guard !reduceMotion else {
            // Degraded: Fen is simply already peeking as the card fades in.
            fenPeeked = true
            return
        }

        switch reward {
        case .standard, .softSettle:
            // Cozy's soft settle IS the entrance spring; nothing bursts.
            break

        case .confettiBurst:
            withAnimation(theme.motion.animation(.settle, reduceMotion: false).delay(0.15)) {
                fenPeeked = true
            }
            // Let the entrance land before the toss. The beat reads better,
            // and it keeps the burst's wall-clock life from racing a slow
            // first frame — this task can start ahead of the visible
            // entrance when the render loop is behind (seen in-sim under
            // recording load).
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            // Fire once per presentation; `== presentationID` keeps a burst
            // alive across a row recreation after the guard was consumed.
            if confettiGuard.shouldFire(for: presentationID) || confettiBurstID == presentationID {
                confettiBurstID = presentationID
            }
            // The wink is the post-reward flourish, after the dots' peak.
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            fenWinkTrigger += 1

        case .leafUnfurl:
            withAnimation(.easeOut(duration: 0.8).delay(0.15)) {
                leafProgress = 1
            }

        case .glowPulse:
            // Score-tick count-up on the item count…
            shownCount = 0
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.7)) { shownCount = itemCount }
            // …while the glow breathes twice and settles low.
            for strength in [1.0, 0.35, 0.8] {
                withAnimation(.easeInOut(duration: 0.45)) { glowStrength = strength }
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
            }
            withAnimation(.easeInOut(duration: 0.6)) { glowStrength = 0.2 }
        }
    }
}

// MARK: - Confetti (Pop!)

/// A one-shot confetti-dot burst: a modest toss of accent-trio dots with
/// gravity and fade — a wink, not a fireworks show ("sherbet, not candy
/// aisle"). Plain shape views driven per-dot by KeyframeAnimator — the
/// kickoff's Canvas/TimelineView approach silently draws nothing inside a
/// List row on the pinned iOS 26.5 sim runtime (verified: the view appears,
/// the canvas never renders), while ordinary view animation is the same
/// machinery the rest of the reward moment already relies on.
private struct ConfettiBurst: View {
    let colors: [Color]

    private struct Dot: Identifiable {
        let id: Int
        let origin: CGPoint // unit space
        let velocity: CGVector // pt/s, negative dy = up
        let size: CGFloat
        let colorIndex: Int
        let life: Double
    }

    @State private var dots: [Dot] = []
    @State private var tossed = false

    private static let gravity: CGFloat = 640

    var body: some View {
        GeometryReader { proxy in
            ForEach(dots) { dot in
                Circle()
                    .fill(colors[dot.colorIndex % max(colors.count, 1)])
                    .frame(width: dot.size, height: dot.size)
                    .keyframeAnimator(initialValue: 0.0, trigger: tossed) { content, t in
                        content
                            .offset(
                                x: dot.origin.x * proxy.size.width + dot.velocity.dx * t,
                                y: dot.origin.y * proxy.size.height + dot.velocity.dy * t
                                    + 0.5 * Self.gravity * t * t)
                            // Hold near-full alpha through the toss, fade on
                            // the way down — a burst, not a dissolve.
                            .opacity(max(0, min(1, (dot.life - t) / (dot.life * 0.6))))
                    } keyframes: { _ in
                        // t advances linearly 0 → life; the closure above
                        // turns it into the parabolic flight.
                        LinearKeyframe(dot.life, duration: dot.life)
                    }
            }
        }
        .onAppear {
            guard dots.isEmpty else { return }
            dots = (0..<22).map { index in
                Dot(
                    id: index,
                    origin: CGPoint(
                        x: CGFloat.random(in: 0.42...0.58),
                        y: CGFloat.random(in: 0.28...0.36)),
                    velocity: CGVector(
                        dx: CGFloat.random(in: -150...150),
                        dy: CGFloat.random(in: -430 ... -180)),
                    size: CGFloat.random(in: 4...7),
                    colorIndex: Int.random(in: 0..<max(colors.count, 1)),
                    life: Double.random(in: 0.9...1.4))
            }
            // Flip the trigger on the next tick — the dots must exist with
            // their untriggered value first, or the change never animates.
            Task { @MainActor in
                tossed = true
            }
        }
    }
}

// MARK: - Leaf (Fresh)

/// One small leaf: stem, then the blade drawn up the left side to the tip
/// and back down the right — `trim` makes it draw itself in.
private struct LeafShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 0.5 * w, y: rect.minY + h))
        path.addLine(to: CGPoint(x: rect.minX + 0.5 * w, y: rect.minY + 0.72 * h))
        path.addCurve(
            to: CGPoint(x: rect.minX + 0.5 * w, y: rect.minY),
            control1: CGPoint(x: rect.minX + 0.02 * w, y: rect.minY + 0.62 * h),
            control2: CGPoint(x: rect.minX + 0.18 * w, y: rect.minY + 0.12 * h))
        path.addCurve(
            to: CGPoint(x: rect.minX + 0.5 * w, y: rect.minY + 0.72 * h),
            control1: CGPoint(x: rect.minX + 0.82 * w, y: rect.minY + 0.12 * h),
            control2: CGPoint(x: rect.minX + 0.98 * w, y: rect.minY + 0.62 * h))
        return path
    }
}
