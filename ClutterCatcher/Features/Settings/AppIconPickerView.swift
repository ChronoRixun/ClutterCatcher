import SwiftUI
import UIKit

/// The app-icon catalog (T7): the primary icon plus one alternate per theme.
/// Icon state belongs to the system (`UIApplication.alternateIconName`) —
/// nothing here is persisted by the app, which is half of the zero-sync
/// guarantee (T2).
enum AppIcons {
    struct Entry: Identifiable, Equatable, Sendable {
        /// `setAlternateIconName` value; nil is the primary icon (Classic).
        let iconName: String?
        let displayName: String
        /// The matching theme's name, shown under the icon name ("Default"
        /// for Classic, per the mock).
        let subtitle: String
        /// The preview imageset (alternate appiconsets aren't loadable
        /// through `Image(named:)`, so the picker renders copies).
        let previewName: String

        var id: String { previewName }
    }

    /// Picker order mirrors the theme order.
    static let all: [Entry] = Theme.all.map { theme in
        Entry(
            iconName: theme.iconName,
            displayName: theme.iconDisplayName,
            subtitle: theme.isClassic ? "Default" : theme.displayName,
            previewName: "IconPreview-" + previewSuffix(forIconName: theme.iconName))
    }

    static func previewSuffix(forIconName iconName: String?) -> String {
        guard let iconName else { return "Classic" }
        return String(iconName.dropFirst("AppIcon-".count))
    }

    static func entry(forIconName iconName: String?) -> Entry? {
        all.first { $0.iconName == iconName }
    }

    /// Applies an icon choice. A no-op when it's already active, so callers
    /// never trigger the system's "changed the icon" alert redundantly.
    @MainActor
    static func apply(iconName: String?) async throws {
        guard UIApplication.shared.alternateIconName != iconName else { return }
        try await UIApplication.shared.setAlternateIconName(iconName)
    }
}

/// Settings › Make It Yours › App Icon: a six-tile grid; tap = instant swap,
/// ring + check marks the active icon. Any icon goes with any theme.
struct AppIconPickerView: View {
    @Environment(ThemeStore.self) private var themeStore

    /// Bumped after every applied change so `currentIconName` re-reads.
    /// The icon is system state — reading it live at render beats caching
    /// a snapshot that can go stale (or start nil) under the system's own
    /// timing.
    @State private var iconRefresh = 0
    @State private var iconError: String?

    private var currentIconName: String? {
        _ = iconRefresh
        return UIApplication.shared.alternateIconName
    }

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: Tokens.spacingM)]

    var body: some View {
        List {
            Section {
                LazyVGrid(columns: columns, spacing: Tokens.spacingL) {
                    ForEach(AppIcons.all) { entry in
                        tile(for: entry)
                    }
                }
                .padding(.vertical, Tokens.spacingS)
            } header: {
                Text("Just for this device — pick any, any time")
            } footer: {
                Text("Changing your theme offers the matching icon — it never switches on its own.")
            }
            .themedRow()
        }
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
        .themedScreen()
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

    private func tile(for entry: AppIcons.Entry) -> some View {
        let isActive = entry.iconName == currentIconName
        return Button {
            select(entry)
        } label: {
            VStack(spacing: Tokens.spacingS) {
                Image(entry.previewName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        if isActive {
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(.tint, lineWidth: 3)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if isActive {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.body)
                                .foregroundStyle(.white, .tint)
                                .offset(x: 6, y: -6)
                        }
                    }
                VStack(spacing: 0) {
                    Text(entry.displayName)
                        .font(.footnote.weight(.medium))
                    Text(entry.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.displayName) icon, for \(entry.subtitle)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func select(_ entry: AppIcons.Entry) {
        Task {
            do {
                try await AppIcons.apply(iconName: entry.iconName)
                iconRefresh += 1
            } catch {
                Log.app.error("Alternate icon change failed: \(String(describing: error))")
                iconError = "Something went wrong changing the icon — try again."
            }
        }
    }
}
