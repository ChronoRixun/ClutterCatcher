import SwiftUI

// M4b motion personality (T10, plan §6): a per-theme token set, hung off
// Theme exactly like the palettes — values, not configuration. Views resolve
// every animation through these tokens with the Reduce Motion flag threaded
// in as a parameter; `@Environment(\.accessibilityReduceMotion)` is the
// production source, the parameter is the test seam. Under Reduce Motion
// every overshoot, stagger, confetti, glow, count-up, and Fen animation
// degrades to the plain fade below (the blink pauses entirely — FenFigure).

/// One spring preset as plain data — testable, Equatable, no view
/// dependency. `animation` is the SwiftUI bridge.
struct SpringSpec: Equatable, Sendable {
    let response: Double
    let dampingFraction: Double

    var animation: Animation {
        .spring(response: response, dampingFraction: dampingFraction)
    }
}

/// A theme's motion character (§6 table): its springs plus its
/// reward-moment styles.
struct MotionPersonality: Equatable, Sendable {
    /// The scan-success "Found it!" moment. One case per table row shape.
    enum ScanReward: Equatable, Sendable {
        case standard      // Classic, Dusk Redux
        case softSettle    // Cozy Home — no burst
        case confettiBurst // Pop! — one-shot dots + Fen peek
        case leafUnfurl    // Fresh — a leaf draws itself in
        case glowPulse     // Arcade — card glow + score-tick count-up
    }

    /// The save moment. Only Pop! has the drop-in squash-settle.
    enum SaveReward: Equatable, Sendable {
        case standard, squashSettle
    }

    /// What a call site is animating; keeps resolution one function.
    enum Role: Sendable {
        /// The workhorse: list settles, staggers, tile bounces, row drop-ins.
        case settle
        /// The scan-success card entrance.
        case cardEntrance
    }

    /// nil = system default animation (Classic's "no theme" reading).
    let settle: SpringSpec?
    /// nil = the standard card transition (Classic, Dusk Redux).
    let cardEntrance: SpringSpec?
    let scanReward: ScanReward
    let saveReward: SaveReward

    /// The single degraded form: everything under Reduce Motion is this fade.
    static let reducedFade = Animation.easeInOut(duration: 0.18)

    func animation(_ role: Role, reduceMotion: Bool) -> Animation {
        guard !reduceMotion else { return Self.reducedFade }
        let spec: SpringSpec? = switch role {
        case .settle: settle
        case .cardEntrance: cardEntrance
        }
        return spec?.animation ?? .default
    }

    /// The effective reward after Reduce Motion: styles collapse to
    /// `.standard` (whose entrance resolves to the fade above), so a single
    /// switch at the call site covers both variants.
    func scanReward(reduceMotion: Bool) -> ScanReward {
        reduceMotion ? .standard : scanReward
    }

    func saveReward(reduceMotion: Bool) -> SaveReward {
        reduceMotion ? .standard : saveReward
    }

    // MARK: Rooms first-load stagger (§6 cross-cutting)

    /// ~30 ms per row, capped so a big catalog never turns into a slideshow;
    /// zero under Reduce Motion (no stagger, plain appearance).
    static func staggerDelay(forIndex index: Int, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return 0 }
        return Double(min(max(index, 0), 15)) * 0.03
    }
}

// MARK: - Confetti one-shot guard

/// Fires exactly once per card presentation (§2): re-renders of the same
/// card never re-fire; a fresh presentation (re-scan → new card identity)
/// always does. Pure logic so the guarantee is unit-tested.
struct ConfettiGuard: Equatable, Sendable {
    private var lastFired: UUID?

    mutating func shouldFire(for presentation: UUID) -> Bool {
        guard lastFired != presentation else { return false }
        lastFired = presentation
        return true
    }
}

// MARK: - The six personalities (§6 table)

extension MotionPersonality {
    /// Classic: system defaults, standard transitions — motion's structural
    /// no-op, matching Classic's theming no-op.
    static let classic = MotionPersonality(
        settle: nil, cardEntrance: nil, scanReward: .standard, saveReward: .standard)

    /// Slow-honey: higher response, high damping, gentle settles.
    static let cozyHome = MotionPersonality(
        settle: SpringSpec(response: 0.65, dampingFraction: 0.95),
        cardEntrance: SpringSpec(response: 0.65, dampingFraction: 0.95),
        scanReward: .softSettle, saveReward: .standard)

    /// Bouncy overshoot; the card entrance is the plan's literal scan pop.
    static let pop = MotionPersonality(
        settle: SpringSpec(response: 0.4, dampingFraction: 0.65),
        cardEntrance: SpringSpec(response: 0.35, dampingFraction: 0.6),
        scanReward: .confettiBurst, saveReward: .squashSettle)

    /// Quiet, fully damped — nothing ever overshoots.
    static let fresh = MotionPersonality(
        settle: SpringSpec(response: 0.45, dampingFraction: 1.0),
        cardEntrance: SpringSpec(response: 0.45, dampingFraction: 1.0),
        scanReward: .leafUnfurl, saveReward: .standard)

    /// Snappy pops — quick, with just a hint of bounce.
    static let arcade = MotionPersonality(
        settle: SpringSpec(response: 0.3, dampingFraction: 0.75),
        cardEntrance: SpringSpec(response: 0.3, dampingFraction: 0.78),
        scanReward: .glowPulse, saveReward: .standard)

    /// System defaults slightly softened; the card rides the standard
    /// transition like Classic.
    static let duskRedux = MotionPersonality(
        settle: SpringSpec(response: 0.55, dampingFraction: 0.9),
        cardEntrance: nil, scanReward: .standard, saveReward: .standard)
}

extension Theme {
    /// The theme's motion personality (T10) — resolved from identity so all
    /// motion lives in this file, next to its presets.
    var motion: MotionPersonality {
        switch id {
        case .classic: .classic
        case .cozyHome: .cozyHome
        case .pop: .pop
        case .fresh: .fresh
        case .arcade: .arcade
        case .duskRedux: .duskRedux
        }
    }
}
