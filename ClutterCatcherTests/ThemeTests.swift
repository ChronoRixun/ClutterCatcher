import Foundation
import GRDB
import Testing
import UIKit
@testable import ClutterCatcher

/// M4a ThemeKit (plan §7): palette completeness, persistence round-trip,
/// the zero-sync guarantee (T2), accent-cycle stability (T11), and the
/// theme → app-icon mapping (T7).
@Suite struct ThemeTests {
    // MARK: Palette completeness (T1/T3)

    @Test func sixThemesInPickerOrder() {
        #expect(Theme.all.map(\.id) == [.classic, .cozyHome, .pop, .fresh, .arcade, .duskRedux])
        #expect(Theme.all.first?.isClassic == true)
    }

    @Test func everyRoleResolvesInEveryThemeAndAppearance() {
        for theme in Theme.all {
            for palette in [theme.light, theme.dark] {
                for role in Palette.Role.allCases {
                    // Resolution must never trap and must land on a real
                    // token: the resolved hex is one of the palette's values.
                    let resolved = palette.hex(for: role)
                    let members = [
                        palette.bg, palette.surface, palette.accent, palette.text,
                        palette.accent2, palette.accent3, palette.success,
                    ].compactMap { $0 }
                    #expect(members.contains(resolved), "\(theme.id) \(role)")
                }
            }
        }
    }

    @Test func sheetSpotChecks() {
        // Pop!'s success is the sheet's explicit "→ accent2" (teal).
        #expect(Theme.pop.light.hex(for: .success) == Theme.pop.light.accent2)
        #expect(Theme.pop.dark.hex(for: .success) == Theme.pop.dark.accent2)
        // Fresh's success is the sheet's explicit "→ accent".
        #expect(Theme.fresh.light.hex(for: .success) == Theme.fresh.light.accent)
        // Arcade is dark-first: the indigo night set is the dark palette.
        #expect(Theme.arcade.dark.bg == 0x17133A)
        #expect(Theme.arcade.light.bg == 0xEDEBFA)
        // Dusk keeps the current amber as its counterpoint accent.
        #expect(Theme.duskRedux.light.accent2 == 0xE09140)
        // Classic's accent is today's AccentColor asset values.
        #expect(Theme.classic.light.accent == 0xE09140)
        #expect(Theme.classic.dark.accent == 0xF0A055)
        // A theme with no accent3 falls back through accent2.
        #expect(Theme.cozyHome.light.hex(for: .accent3) == Theme.cozyHome.light.accent2)
    }

    @Test func fenPresenceMatchesTheDial() {
        // §5: Cozy light touch, Pop! medium, Arcade full; the rest none.
        // M4a only draws Fen where colors exist, so colors ⟺ presence.
        for theme in Theme.all {
            #expect((theme.fenColors != nil) == (theme.fenPresence != .none), "\(theme.id)")
        }
        #expect(Theme.cozyHome.fenPresence == .lightTouch)
        #expect(Theme.pop.fenPresence == .medium)
        #expect(Theme.arcade.fenPresence == .fullSprite)
        #expect(Theme.fresh.fenPresence == .none)
        #expect(Theme.duskRedux.fenPresence == .none)
        #expect(Theme.classic.fenPresence == .none)
    }

    // MARK: Persistence round-trip (T2)

    @Test @MainActor func themeSelectionRoundTripsThroughSettings() async throws {
        let database = try AppDatabase.inMemory()
        let store = ThemeStore.loaded(database: database)
        #expect(store.theme.id == .classic) // empty settings → the default

        await store.select(.pop)
        #expect(store.theme.id == .pop)
        let stored = try await SettingsRepository(database: database)
            .value(forKey: Setting.themeIDKey)
        #expect(stored == ThemeID.pop.rawValue)

        // A fresh store (relaunch) resolves the persisted choice.
        let relaunched = ThemeStore.loaded(database: database)
        #expect(relaunched.theme.id == .pop)
    }

    @Test func unknownOrMissingStoredValueFallsBackToClassic() {
        #expect(Theme.theme(forStoredValue: nil).id == .classic)
        #expect(Theme.theme(forStoredValue: "sparkle-pony").id == .classic)
        for id in ThemeID.allCases {
            #expect(Theme.theme(forStoredValue: id.rawValue).id == id)
        }
    }

    // MARK: Zero sync surface (T2 — the required test)

    @Test @MainActor func themingProducesZeroPendingChanges() async throws {
        let database = try AppDatabase.inMemory()
        let store = ThemeStore(database: database)

        // Exercise every theme selection plus every icon-name mapping —
        // the complete set of theming operations that touch app state.
        for id in ThemeID.allCases {
            await store.select(id)
            _ = Theme.theme(for: id).iconName
            _ = AppIcons.entry(forIconName: Theme.theme(for: id).iconName)
        }

        let (pendingCount, syncEventCount, settingKeys) = try await database.writer.read { db in
            (try PendingChange.fetchCount(db),
             try SyncEvent.fetchCount(db),
             try String.fetchAll(db, sql: "SELECT key FROM settings"))
        }
        #expect(pendingCount == 0)
        #expect(syncEventCount == 0)
        // The only footprint is the local-only theme key itself.
        #expect(settingKeys == [Setting.themeIDKey])
    }

    // MARK: Accent cycle (T11)

    @Test func popCyclesTrioEveryoneElseCyclesOne() {
        #expect(Theme.pop.accentCycleRoles == [.accent, .accent2, .accent3])
        for theme in Theme.all where theme.id != .pop {
            #expect(theme.accentCycleRoles == [.accent], "\(theme.id)")
        }
        // Index math: wraps, and never traps on odd input.
        #expect(Theme.pop.accentCycleIndex(forSortOrder: 0) == 0)
        #expect(Theme.pop.accentCycleIndex(forSortOrder: 4) == 1)
        #expect(Theme.pop.accentCycleIndex(forSortOrder: -1) == 2)
        #expect(Theme.classic.accentCycleIndex(forSortOrder: 41) == 0)
    }

    @Test func accentCycleStableUnderReorderAndInsert() async throws {
        let database = try AppDatabase.inMemory()
        let repository = RoomRepository(database: database)
        let a = try await repository.createRoom(name: "A", icon: nil)
        let b = try await repository.createRoom(name: "B", icon: nil)
        let c = try await repository.createRoom(name: "C", icon: nil)
        let d = try await repository.createRoom(name: "D", icon: nil)

        func cycleIndices() async throws -> [String: Int] {
            let rooms = try await repository.allRooms()
            return Dictionary(uniqueKeysWithValues: rooms.map {
                ($0.name, Theme.pop.accentCycleIndex(forSortOrder: $0.sortOrder))
            })
        }

        let before = try await cycleIndices()

        // Swap the last two: A and B are untouched rows and must keep
        // their colors; adding a room at the end must shuffle nobody.
        try await repository.reorderRooms(orderedIDs: [a.id, b.id, d.id, c.id])
        _ = try await repository.createRoom(name: "E", icon: nil)
        let after = try await cycleIndices()

        #expect(after["A"] == before["A"])
        #expect(after["B"] == before["B"])
        #expect(after["D"] == Theme.pop.accentCycleIndex(forSortOrder: 2))
        #expect(after["C"] == Theme.pop.accentCycleIndex(forSortOrder: 3))
        #expect(after["E"] == Theme.pop.accentCycleIndex(forSortOrder: 4))
    }

    // MARK: Icon mapping (T7)

    @Test func iconNamesMapPerTheme() {
        #expect(Theme.classic.iconName == nil) // primary icon, not an alternate
        #expect(Theme.cozyHome.iconName == "AppIcon-Hearth")
        #expect(Theme.pop.iconName == "AppIcon-FenWink")
        #expect(Theme.fresh.iconName == "AppIcon-Sprout")
        #expect(Theme.arcade.iconName == "AppIcon-NightSprite")
        #expect(Theme.duskRedux.iconName == "AppIcon-Dusk")
        // One distinct icon per theme.
        let names = Theme.all.map { $0.iconName ?? "primary" }
        #expect(Set(names).count == Theme.all.count)
    }

    @Test func iconCatalogCoversEveryThemeWithAPreviewAsset() {
        #expect(AppIcons.all.count == Theme.all.count)
        #expect(AppIcons.entry(forIconName: nil)?.displayName == "Classic")
        #expect(AppIcons.entry(forIconName: "AppIcon-Hearth")?.subtitle == "Cozy Home")
        for entry in AppIcons.all {
            // The picker's preview imagesets really are in the bundle.
            #expect(UIImage(named: entry.previewName) != nil, "\(entry.previewName)")
        }
    }

    /// `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_NAMES` must register every
    /// alternate in the built Info.plist — that registration is what makes
    /// `setAlternateIconName` work at all. Runs against the host app bundle.
    @Test func alternateIconsRegisteredInHostAppBundle() throws {
        let icons = try #require(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        let alternates = try #require(icons["CFBundleAlternateIcons"] as? [String: Any])
        for theme in Theme.all {
            guard let iconName = theme.iconName else { continue }
            #expect(alternates[iconName] != nil, "missing \(iconName)")
        }
    }
}
