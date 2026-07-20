import SwiftUI
import Testing
@testable import ClutterCatcher

/// M4b motion personality (plan §6, T10): per-theme token resolution in both
/// the animated and Reduce-Motion variants, the Reduce Motion seam itself,
/// the confetti one-shot guard, and the rooms-stagger math.
@Suite struct MotionTests {
    // MARK: Token resolution per theme (§6 table)

    @Test func everyThemeResolvesEveryRoleInBothVariants() {
        // The §7 floor: all six themes, both variants, no traps. The reduced
        // variant is always the plain fade; the animated variant never is
        // (system defaults included — .default is not a fade).
        for theme in Theme.all {
            for role in [MotionPersonality.Role.settle, .cardEntrance] {
                let animated = theme.motion.animation(role, reduceMotion: false)
                let reduced = theme.motion.animation(role, reduceMotion: true)
                #expect(reduced == MotionPersonality.reducedFade, "\(theme.id) \(role)")
                #expect(animated != reduced, "\(theme.id) \(role)")
            }
        }
    }

    @Test func rewardStylesMatchTheTable() {
        #expect(Theme.classic.motion.scanReward == .standard)
        #expect(Theme.cozyHome.motion.scanReward == .softSettle)
        #expect(Theme.pop.motion.scanReward == .confettiBurst)
        #expect(Theme.fresh.motion.scanReward == .leafUnfurl)
        #expect(Theme.arcade.motion.scanReward == .glowPulse)
        #expect(Theme.duskRedux.motion.scanReward == .standard)

        // Save column: only Pop! has the drop-in squash-settle.
        for theme in Theme.all {
            #expect(
                theme.motion.saveReward == (theme.id == .pop ? .squashSettle : .standard),
                "\(theme.id)")
        }
    }

    @Test func popScanPopUsesThePlansExactNumbers() {
        // §6 names these literally: "scan pop `response .35, damping .6`".
        #expect(Theme.pop.motion.cardEntrance == SpringSpec(response: 0.35, dampingFraction: 0.6))
    }

    @Test func springCharactersMatchTheTable() throws {
        // Classic and Dusk Redux ride the standard card transition (no
        // custom entrance spring); everyone else brings their own.
        #expect(Theme.classic.motion.cardEntrance == nil)
        #expect(Theme.duskRedux.motion.cardEntrance == nil)
        #expect(Theme.classic.motion.settle == nil) // system defaults

        let cozy = try #require(Theme.cozyHome.motion.settle)
        let pop = try #require(Theme.pop.motion.settle)
        let fresh = try #require(Theme.fresh.motion.settle)
        let arcade = try #require(Theme.arcade.motion.settle)

        // Slow-honey vs snappy: Cozy is the slowest, Arcade the fastest.
        #expect(cozy.response > pop.response)
        #expect(pop.response > arcade.response)
        // High damping = no overshoot for Cozy/Fresh; Pop! must overshoot.
        #expect(cozy.dampingFraction >= 0.9)
        #expect(fresh.dampingFraction >= 0.9)
        #expect(pop.dampingFraction < 0.7)
    }

    // MARK: The Reduce Motion seam (§7 — flag flips the implementation)

    @Test func reduceMotionCollapsesRewardsToStandard() {
        for theme in Theme.all {
            #expect(theme.motion.scanReward(reduceMotion: true) == .standard, "\(theme.id)")
            #expect(theme.motion.saveReward(reduceMotion: true) == .standard, "\(theme.id)")
            // The animated variant is the theme's own style, untouched.
            #expect(theme.motion.scanReward(reduceMotion: false) == theme.motion.scanReward)
            #expect(theme.motion.saveReward(reduceMotion: false) == theme.motion.saveReward)
        }
        // The flip is observable where it matters most: Pop!'s confetti and
        // squash-settle both vanish under the flag.
        #expect(Theme.pop.motion.scanReward(reduceMotion: false) == .confettiBurst)
        #expect(Theme.pop.motion.scanReward(reduceMotion: true) == .standard)
        #expect(Theme.pop.motion.saveReward(reduceMotion: false) == .squashSettle)
        #expect(Theme.pop.motion.saveReward(reduceMotion: true) == .standard)
    }

    // MARK: Confetti one-shot guard (§2 — once per card presentation)

    @Test func confettiFiresOncePerPresentation() {
        var guardState = ConfettiGuard()
        let first = UUID()
        #expect(guardState.shouldFire(for: first) == true)
        // Re-renders of the same card must not re-fire.
        #expect(guardState.shouldFire(for: first) == false)
        #expect(guardState.shouldFire(for: first) == false)
        // A fresh card presentation (re-scan) fires again.
        let second = UUID()
        #expect(guardState.shouldFire(for: second) == true)
        #expect(guardState.shouldFire(for: second) == false)
    }

    // MARK: Rooms first-load stagger (§6 cross-cutting)

    @Test func staggerDelayIsThirtyMillisecondsPerRowCapped() {
        #expect(MotionPersonality.staggerDelay(forIndex: 0, reduceMotion: false) == 0)
        #expect(abs(MotionPersonality.staggerDelay(forIndex: 1, reduceMotion: false) - 0.03) < 0.0001)
        #expect(abs(MotionPersonality.staggerDelay(forIndex: 5, reduceMotion: false) - 0.15) < 0.0001)
        // A giant catalog must not turn the load-in into a slideshow.
        let capped = MotionPersonality.staggerDelay(forIndex: 200, reduceMotion: false)
        #expect(capped == MotionPersonality.staggerDelay(forIndex: 15, reduceMotion: false))
        // Reduce Motion: no stagger at all.
        #expect(MotionPersonality.staggerDelay(forIndex: 5, reduceMotion: true) == 0)
    }
}
