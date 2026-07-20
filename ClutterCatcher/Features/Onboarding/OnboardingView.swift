import SwiftUI

/// First-launch onboarding on a virgin database (M3-B): one explicit choice
/// between owning a new household catalog and joining an existing one. A
/// share invite arriving while either screen shows routes straight into the
/// join flow — `ShareAcceptanceModel` doesn't wait for a choice here.
struct OnboardingView: View {
    @Environment(AppModel.self) private var appModel
    @State private var isWorking = false

    var body: some View {
        @Bindable var appModel = appModel
        VStack(spacing: Tokens.spacingL) {
            Spacer()
            Image(systemName: "shippingbox")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Welcome to ClutterCatcher")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text("One catalog for the whole household: label bins with QR codes, scan to see what's inside.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()

            VStack(spacing: Tokens.spacingM) {
                Button {
                    isWorking = true
                    Task {
                        await appModel.setUpThisHome()
                        isWorking = false
                    }
                } label: {
                    VStack(spacing: 2) {
                        Text("Set Up This Home")
                            .font(.headline)
                        Text("Start a new catalog and invite the family later.")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Tokens.spacingS)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    isWorking = true
                    Task {
                        await appModel.chooseJoin()
                        isWorking = false
                    }
                } label: {
                    VStack(spacing: 2) {
                        Text("Join a Household")
                            .font(.headline)
                        Text("Someone already set it up and will invite you.")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Tokens.spacingS)
                }
                .buttonStyle(.bordered)
            }
            .disabled(isWorking)
        }
        // M6.2: a welcome card, not a 12-inch spread — cap on iPad widths.
        .frame(maxWidth: 480)
        .padding(Tokens.spacingL)
        .discoveredHouseholdOfferDialog(appModel)
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { appModel.onboardingError != nil },
                set: { if !$0 { appModel.onboardingError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appModel.onboardingError ?? "")
        }
    }
}

/// M7b rider: the seeding guard's interposed question, shared by both
/// screens that can seed (onboarding's primary button and the waiting
/// screen's escape hatch). Joining rides the M6.2 discovered-zone machinery;
/// "anyway" is the pre-rider owner path as a deliberate choice — the guard
/// warns, it never forbids.
private struct DiscoveredHouseholdOfferDialog: ViewModifier {
    @Bindable var appModel: AppModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "This Apple ID is already in a household — join it instead?",
            isPresented: Binding(
                get: { appModel.discoveredHouseholdOffer != nil },
                set: { if !$0 { appModel.dismissDiscoveredOffer() } }),
            titleVisibility: .visible
        ) {
            Button("Join My Household") {
                Task { await appModel.joinDiscoveredHousehold() }
            }
            Button("Start a Separate Catalog Anyway", role: .destructive) {
                Task { await appModel.setUpThisHomeAnyway() }
            }
            Button("Cancel", role: .cancel) {
                appModel.dismissDiscoveredOffer()
            }
        } message: {
            Text("This device's Apple ID already belongs to a ClutterCatcher household. Joining connects this device to the family's catalog; starting fresh makes a second, separate one.")
        }
    }
}

extension View {
    func discoveredHouseholdOfferDialog(_ appModel: AppModel) -> some View {
        modifier(DiscoveredHouseholdOfferDialog(appModel: appModel))
    }
}

/// The waiting room after "Join a Household" (M3-B): no catalog, no seed —
/// just instructions until the share invite lands. Since M6.2 it also
/// checks whether this Apple ID already carries the household's shared zone
/// (a participant's second device needs no invite) — on appear and on every
/// return to the foreground, mirroring the DL26 activation-fetch discipline.
struct JoinWaitingView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isConfirmingOwnerSwitch = false

    var body: some View {
        VStack(spacing: Tokens.spacingL) {
            Spacer()
            Image(systemName: "envelope.badge")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Waiting for Your Invite")
                .font(.title.bold())
            VStack(alignment: .leading, spacing: Tokens.spacingM) {
                InstructionRow(number: 1, text: "Ask the person who set up ClutterCatcher to open its Family tab and invite you.")
                InstructionRow(number: 2, text: "Open the invite they send you (usually in Messages) on this device.")
                InstructionRow(number: 3, text: "The household's catalog appears here automatically.")
            }
            .padding(.horizontal, Tokens.spacingS)
            // M6.2 §3: second devices need no invite — discovery runs on
            // appear and on every foreground. Saying so keeps a briefly
            // slow iCloud session from steering people into "Set Up This
            // Home Instead" (seen in the wild on the first device pass).
            Text("Already in the household on another device? No invite needed — the catalog connects on its own once iCloud catches up.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button("Set Up This Home Instead") {
                isConfirmingOwnerSwitch = true
            }
            .font(.subheadline)
            // M7b rider: the guard's one discovery check runs first; keep
            // the escape hatch quiet while it does (≤ its 4 s timeout).
            .disabled(appModel.isCheckingForHousehold)
            // Anchored to its button so iPad presents a sane popover
            // (M6.2 popover audit).
            .confirmationDialog(
                "Start your own catalog?",
                isPresented: $isConfirmingOwnerSwitch,
                titleVisibility: .visible
            ) {
                Button("Set Up This Home") {
                    Task { await appModel.setUpThisHome() }
                }
            } message: {
                Text("Only one person per household should do this — everyone else joins by invite.")
            }
        }
        .frame(maxWidth: 480) // M6.2 — see OnboardingView
        .padding(Tokens.spacingL)
        .discoveredHouseholdOfferDialog(appModel)
        .task {
            await ShareAcceptanceModel.shared.discoverExistingHousehold()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await ShareAcceptanceModel.shared.discoverExistingHousehold() }
            }
        }
    }
}

private struct InstructionRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.spacingM) {
            Text("\(number)")
                .font(.subheadline.bold())
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
