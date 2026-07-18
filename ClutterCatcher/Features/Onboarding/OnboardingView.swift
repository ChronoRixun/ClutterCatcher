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
        .padding(Tokens.spacingL)
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

/// The waiting room after "Join a Household" (M3-B): no catalog, no seed —
/// just instructions until the share invite lands.
struct JoinWaitingView: View {
    @Environment(AppModel.self) private var appModel
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
            Spacer()
            Button("Set Up This Home Instead") {
                isConfirmingOwnerSwitch = true
            }
            .font(.subheadline)
        }
        .padding(Tokens.spacingL)
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
