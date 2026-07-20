import SwiftUI
import UIKit

/// Settings › Make It Yours › Theme: one card per theme with its personality
/// line and a swatch strip. Selection applies live (no restart) and *offers*
/// the matching app icon — never switches it silently (T7).
struct ThemePickerView: View {
    @Environment(ThemeStore.self) private var themeStore

    /// A just-selected theme whose matching icon differs from the current
    /// one — drives the offer dialog.
    @State private var iconOffer: Theme?
    @State private var iconError: String?

    var body: some View {
        List {
            Section {
                ForEach(Theme.all) { theme in
                    Button {
                        select(theme)
                    } label: {
                        ThemeRow(theme: theme, isActive: theme.id == themeStore.theme.id)
                    }
                    .buttonStyle(.plain)
                }
                .themedRow()
            } footer: {
                Text("Themes follow your device's light and dark setting.")
            }
        }
        .readableContentWidth() // M6.2
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
        .themedScreen()
        .confirmationDialog(
            "Use the matching icon?",
            isPresented: Binding(
                get: { iconOffer != nil },
                set: { if !$0 { iconOffer = nil } }),
            titleVisibility: .visible,
            presenting: iconOffer
        ) { theme in
            Button("Use \(theme.iconDisplayName) Icon") {
                applyIcon(named: theme.iconName)
            }
            Button("Keep Current Icon", role: .cancel) {
                iconOffer = nil
            }
        } message: { theme in
            Text("\(theme.displayName) has a matching app icon — \(theme.iconDisplayName). Your icon never changes unless you say so.")
        }
        .alert(
            "Couldn't Change the Icon",
            isPresented: Binding(
                get: { iconError != nil },
                set: { if !$0 { iconError = nil } })
        ) {
            Button("OK", role: .cancel) { iconError = nil }
        } message: {
            if let iconError {
                Text(iconError)
            }
        }
    }

    private func select(_ theme: Theme) {
        let wasActive = themeStore.theme.id == theme.id
        // Offer the matching icon only on an actual change, and only when
        // the icon isn't already the matching one.
        let wantsOffer = !wasActive && UIApplication.shared.alternateIconName != theme.iconName
        Task {
            await themeStore.select(theme.id)
            // Present only after the theme switch's render settles —
            // presenting in the same transaction gets the dialog dropped.
            if wantsOffer {
                iconOffer = theme
            }
        }
    }

    private func applyIcon(named iconName: String?) {
        Task {
            do {
                try await AppIcons.apply(iconName: iconName)
            } catch {
                Log.app.error("Matching icon change failed: \(String(describing: error))")
                iconError = "Something went wrong changing the icon — try again."
            }
        }
    }
}

private struct ThemeRow: View {
    let theme: Theme
    let isActive: Bool

    var body: some View {
        HStack(spacing: Tokens.spacingM) {
            VStack(alignment: .leading, spacing: 4) {
                Text(theme.displayName)
                    .font(.body.weight(.medium))
                Text(theme.tagline)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                SwatchStrip(theme: theme)
                    .padding(.top, 2)
            }
            Spacer()
            if isActive {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Current theme")
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// A small strip of the theme's defining colors, in the *current*
/// appearance (the colors are dynamic).
private struct SwatchStrip: View {
    let theme: Theme

    private var roles: [Palette.Role] {
        theme.id == .pop ? [.bg, .accent, .accent2, .accent3] : [.bg, .accent, .accent2, .success]
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(roles.enumerated()), id: \.offset) { _, role in
                Circle()
                    .fill(theme.color(role))
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))
            }
        }
        .accessibilityHidden(true)
    }
}
