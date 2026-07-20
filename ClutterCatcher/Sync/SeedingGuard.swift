import Foundation

/// The Run 10 rider (Owen's ruling, 2026-07-20): "Set Up This Home
/// (Instead)" runs ONE shared-zone discovery check — bounded by a short
/// timeout — before `becomeOwner` seeds. A `Household` zone in this
/// account's shared database means the Apple ID is already a household
/// participant, and seeding would fork a second household (DL82's one
/// dangerous edge). The check interposes "join it instead?"; it never
/// blocks the road: timeout, offline, or any discovery error proceeds to
/// owner setup exactly as today — **the guard must never strand a genuine
/// first owner without a network.**
enum SeedingGuard {
    /// What one discovery attempt produced. Timeout, offline, and every
    /// error collapse into `unavailable` on purpose: they all mean "we
    /// couldn't prove a household exists", and only proof interposes.
    enum DiscoveryResult: Sendable {
        case zoneFound(DiscoveredHouseholdZone)
        case noZone
        case unavailable
    }

    enum Decision: Equatable, Sendable {
        /// Seed and own — the pre-rider behavior.
        case proceedToOwner
        /// Interpose "This Apple ID is already in a household — join it
        /// instead?" before anything seeds.
        case offerJoin(DiscoveredHouseholdZone)
    }

    /// How long the one check may hold up "Set Up This Home": generous for
    /// a warm CloudKit round-trip, short enough that an offline first owner
    /// barely notices (logged as a DL).
    static let timeout: Duration = .seconds(4)

    /// Pure decision seam (tested without CloudKit): only a found zone
    /// interposes.
    static func decision(_ result: DiscoveryResult) -> Decision {
        switch result {
        case .zoneFound(let zone): .offerJoin(zone)
        case .noZone, .unavailable: .proceedToOwner
        }
    }

    /// Races one discovery attempt against the timeout. The discovery is a
    /// closure so tests drive found/not-found/error/never-returns without
    /// CloudKit; production passes `SharedZoneDiscovery.discoverHouseholdZone`.
    static func discoveryResult(
        timeout: Duration = timeout,
        discover: @escaping @Sendable () async throws -> DiscoveredHouseholdZone?
    ) async -> DiscoveryResult {
        await withTaskGroup(of: DiscoveryResult?.self) { group in
            group.addTask {
                do {
                    if let zone = try await discover() {
                        return .zoneFound(zone)
                    }
                    return .noZone
                } catch {
                    return .unavailable
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil // the timeout marker
            }
            // First child to finish decides; the straggler is cancelled
            // (CloudKit's async calls honor cancellation).
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .unavailable
        }
    }
}
