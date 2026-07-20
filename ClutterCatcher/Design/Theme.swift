import SwiftUI
import UIKit

// M4 "Make It Yours" (planning/m4-themes-plan.md): one skeleton, five outfits.
// Every theme fills the same token roles over the untouched Liquid Glass
// substrate (T5); layout and behavior never change between themes. Classic is
// "no theme" — its application is a structural no-op so it stays
// pixel-equivalent to the pre-M4 app (apart from rounded type and the §4
// layout refresh, which ship for all themes).

/// Stable identity for the six built-in themes. The raw value is what
/// persists in the local-only `settings` table (T2) — never rename a case's
/// raw value once shipped.
enum ThemeID: String, CaseIterable, Sendable {
    case classic
    case cozyHome = "cozy-home"
    case pop
    case fresh
    case arcade
    case duskRedux = "dusk-redux"
}

/// One appearance's worth of token values (plan §3), stored as sRGB hex so
/// palettes are plain data — testable, Equatable, no view dependency.
/// Optional roles resolve through `hex(for:)`'s fallback chain (T3); themes
/// whose sheet names an explicit fallback (Pop!'s success → accent2, Fresh's
/// success → accent) bake the resolved value in directly.
struct Palette: Equatable, Sendable {
    let bg: UInt32
    let surface: UInt32
    let accent: UInt32
    let text: UInt32
    var accent2: UInt32?
    var accent3: UInt32?
    var success: UInt32?

    /// The normalized token roles (T3). Every role resolves in every palette.
    enum Role: CaseIterable, Sendable {
        case bg, surface, accent, accent2, accent3, text, success
    }

    func hex(for role: Role) -> UInt32 {
        switch role {
        case .bg: bg
        case .surface: surface
        case .accent: accent
        case .text: text
        case .accent2: accent2 ?? accent
        case .accent3: accent3 ?? accent2 ?? accent
        case .success: success ?? accent
        }
    }
}

/// How much Fen a theme gets (T9/T14 — the per-theme presence dial).
/// M4a uses this only to decide whether empty states show the figure;
/// M4b adds the presence-specific behaviors (peeks, pixel sprite).
enum FenPresence: Sendable {
    case none, lightTouch, medium, fullSprite
}

/// Fen's colors for one theme (design/fen-geometry.md). Fixed per theme —
/// the figure reads well on both of its theme's backgrounds by design.
struct FenColors: Equatable, Sendable {
    let body: UInt32
    let muzzle: UInt32
    let eye: UInt32
    let nose: UInt32
    let innerEar: UInt32
    let innerEarOpacity: Double
}

/// A theme: identity plus both palettes (T1). Values, not configuration —
/// the six built-ins are the only instances.
struct Theme: Identifiable, Equatable, Sendable {
    let id: ThemeID
    let displayName: String
    /// One-line personality description, shown in the theme picker.
    let tagline: String
    /// Alternate app-icon set name (T7); nil means the primary `AppIcon`.
    let iconName: String?
    /// Human name for the matching icon, for picker labels and the
    /// "offer the matching icon" prompt.
    let iconDisplayName: String
    let fenPresence: FenPresence
    /// Fen's colors, present exactly when `fenPresence != .none`.
    let fenColors: FenColors?
    let light: Palette
    let dark: Palette

    /// Classic is "no theme": background/surface application is a structural
    /// no-op so the default look stays pixel-equivalent to the pre-M4 app.
    var isClassic: Bool { id == .classic }

    func palette(for scheme: ColorScheme) -> Palette {
        scheme == .dark ? dark : light
    }

    // MARK: Dynamic colors

    /// A color that follows the system light/dark setting (T4 — appearance is
    /// respected, never forced; no `preferredColorScheme` anywhere).
    func color(_ role: Palette.Role) -> Color {
        Color(uiColor(role))
    }

    /// The dynamic UIColor behind `color(_:)`, for UIKit-backed surfaces
    /// (the label preview's PDFView background).
    func uiColor(_ role: Palette.Role) -> UIColor {
        let lightHex = light.hex(for: role)
        let darkHex = dark.hex(for: role)
        return UIColor { traits in
            UIColor(srgbHex: traits.userInterfaceStyle == .dark ? darkHex : lightHex)
        }
    }

    var bg: Color { color(.bg) }
    var surface: Color { color(.surface) }
    var accent: Color { color(.accent) }
    var accent2: Color { color(.accent2) }
    var accent3: Color { color(.accent3) }
    var success: Color { color(.success) }

    /// The tint applied at the root. Classic returns nil — the asset-catalog
    /// AccentColor keeps ruling, exactly as before M4.
    var tint: Color? { isClassic ? nil : accent }

    // MARK: Accent cycle (T11)

    /// The roles rotated across room icon tiles. Pop! rotates its trio;
    /// every other theme cycles a single accent.
    var accentCycleRoles: [Palette.Role] {
        id == .pop ? [.accent, .accent2, .accent3] : [.accent]
    }

    var accentCycle: [Color] { accentCycleRoles.map(color) }

    /// Index into `accentCycle` for a room. Keyed off the room's persisted
    /// `sort_order` — reordering rewrites only the rooms whose position
    /// changed and deleting renumbers nothing, so untouched rooms keep their
    /// color (T11's stability requirement, test-asserted).
    func accentCycleIndex(forSortOrder sortOrder: Int) -> Int {
        let count = accentCycleRoles.count
        return ((sortOrder % count) + count) % count
    }

    func cycleAccent(forSortOrder sortOrder: Int) -> Color {
        accentCycle[accentCycleIndex(forSortOrder: sortOrder)]
    }

    // MARK: Lookup

    /// Picker order: Classic (the default) first, then the sheet order (§3).
    static let all: [Theme] = [.classic, .cozyHome, .pop, .fresh, .arcade, .duskRedux]

    static func theme(for id: ThemeID) -> Theme {
        all.first { $0.id == id } ?? .classic
    }

    /// Resolves a persisted raw value; unknown or missing → Classic (a user
    /// who never opens the picker sees no change, T1).
    static func theme(forStoredValue raw: String?) -> Theme {
        guard let raw, let id = ThemeID(rawValue: raw) else { return .classic }
        return theme(for: id)
    }
}

// MARK: - The six built-ins (token sheet, plan §3)

extension Theme {
    /// Today's look. The palette mirrors the system grouped-list colors and
    /// the shipping AccentColor asset — but application is a no-op
    /// (`isClassic`); these values exist for the picker's swatches and the
    /// completeness tests.
    static let classic = Theme(
        id: .classic,
        displayName: "Classic",
        tagline: "The app as it is today — clean, simple, amber.",
        iconName: nil,
        iconDisplayName: "Classic",
        fenPresence: .none,
        fenColors: nil,
        light: Palette(
            bg: 0xF2F2F7, surface: 0xFFFFFF, accent: 0xE09140, text: 0x000000,
            accent2: nil, accent3: nil, success: 0x34C759),
        dark: Palette(
            bg: 0x000000, surface: 0x1C1C1E, accent: 0xF0A055, text: 0xFFFFFF,
            accent2: nil, accent3: nil, success: 0x30D158))

    static let cozyHome = Theme(
        id: .cozyHome,
        displayName: "Cozy Home",
        tagline: "Warm creams and terracotta — the house you actually want to tidy.",
        iconName: "AppIcon-Hearth",
        iconDisplayName: "Hearth",
        fenPresence: .lightTouch,
        fenColors: FenColors(
            body: 0xC4643C, muzzle: 0xFFF6EC, eye: 0x2E2015, nose: 0x2E2015,
            innerEar: 0x3B2E24, innerEarOpacity: 0.35),
        light: Palette(
            bg: 0xF7F0E6, surface: 0xFFFDF9, accent: 0xC4643C, text: 0x3B2E24,
            accent2: 0xE3A455, accent3: nil, success: 0x7A9B5E),
        dark: Palette(
            bg: 0x241C15, surface: 0x322820, accent: 0xE08757, text: 0xF5EDE2,
            accent2: 0xEFB968, accent3: nil, success: 0x95B478))

    /// The lead theme. `success` is the sheet's explicit "→ accent2" (teal).
    static let pop = Theme(
        id: .pop,
        displayName: "Pop!",
        tagline: "Candy brights on cream — sherbet, not candy aisle.",
        iconName: "AppIcon-FenWink",
        iconDisplayName: "Fen Wink",
        fenPresence: .medium,
        // The empty-state Fen from the Pop Lead Screens mock (card 1e):
        // tangerine body. fen-geometry.md's cream Pop! row describes the
        // *icon glyph*, which sits on a pink gradient — cream would vanish
        // against this theme's own cream background in-app.
        fenColors: FenColors(
            body: 0xFF8A3B, muzzle: 0xFFF6EC, eye: 0x2E2015, nose: 0x2E2015,
            innerEar: 0x33253A, innerEarOpacity: 0.3),
        light: Palette(
            bg: 0xFFF7EE, surface: 0xFFFFFF, accent: 0xF0509B, text: 0x33253A,
            accent2: 0x00A8A0, accent3: 0xFF8A3B, success: 0x00A8A0),
        dark: Palette(
            bg: 0x251C2E, surface: 0x332841, accent: 0xFF6FB0, text: 0xFBEFF6,
            accent2: 0x2CD1C8, accent3: 0xFFA05C, success: 0x2CD1C8))

    /// `success` is the sheet's explicit "→ accent" (sage would read muted).
    static let fresh = Theme(
        id: .fresh,
        displayName: "Fresh",
        tagline: "Sage and leaf greens — calm, airy, tidy-garden.",
        iconName: "AppIcon-Sprout",
        iconDisplayName: "Sprout",
        fenPresence: .none,
        fenColors: nil,
        light: Palette(
            bg: 0xF4F3EA, surface: 0xFFFFFF, accent: 0x4E7D52, text: 0x29352B,
            accent2: 0x8FAE8B, accent3: 0xA94F6D, success: 0x4E7D52),
        dark: Palette(
            bg: 0x1C231D, surface: 0x28322A, accent: 0x7FAE83, text: 0xEDF2EA,
            accent2: 0x5A7A5E, accent3: 0xC97B95, success: 0x7FAE83))

    /// Dark-first by identity (T4): the dark palette is the indigo night,
    /// the light palette the soft-lavender day-mode. Still follows the
    /// system setting like every other theme.
    static let arcade = Theme(
        id: .arcade,
        displayName: "Arcade",
        tagline: "Indigo night, neon accents — catching clutter is a game.",
        iconName: "AppIcon-NightSprite",
        iconDisplayName: "Night Sprite",
        fenPresence: .fullSprite,
        fenColors: FenColors(
            body: 0xFF4FD8, muzzle: 0xFFC9EC, eye: 0x35E0FF, nose: 0x17133A,
            innerEar: 0x241E52, innerEarOpacity: 0.45),
        light: Palette(
            bg: 0xEDEBFA, surface: 0xFFFFFF, accent: 0xC427A8, text: 0x241E52,
            accent2: 0x0798C4, accent3: nil, success: 0x14935B),
        dark: Palette(
            bg: 0x17133A, surface: 0x241E52, accent: 0xFF4FD8, text: 0xF0EEFF,
            accent2: 0x35E0FF, accent3: nil, success: 0x5CFF9D))

    static let duskRedux = Theme(
        id: .duskRedux,
        displayName: "Dusk Redux",
        tagline: "Plum with warm amber — the retired identity, refined.",
        iconName: "AppIcon-Dusk",
        iconDisplayName: "Dusk",
        fenPresence: .none,
        fenColors: nil,
        light: Palette(
            bg: 0xF3F0FA, surface: 0xFFFFFF, accent: 0x6C4EC2, text: 0x2C2440,
            accent2: 0xE09140, accent3: nil, success: 0x55915F),
        dark: Palette(
            bg: 0x1E1830, surface: 0x2A2342, accent: 0x9B7FE8, text: 0xEFEAFB,
            accent2: 0xF0A055, accent3: nil, success: 0x7FB58A))
}

// MARK: - Hex plumbing

extension UIColor {
    convenience init(srgbHex hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

extension Color {
    /// A fixed (non-dynamic) color from a palette hex — for swatches and Fen,
    /// whose colors don't vary by appearance.
    init(srgbHex hex: UInt32) {
        self.init(uiColor: UIColor(srgbHex: hex))
    }
}
