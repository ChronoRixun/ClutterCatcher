import PDFKit
import SwiftUI
import UIKit

/// Builds a printable label sheet: pick a sheet format, pick containers,
/// generate the paginated PDF, then print or share it. Generating assigns
/// permanent label slots to containers that don't have one yet.
struct LabelSheetView: View {
    @Environment(\.appDatabase) private var appDatabase
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [ContainerCandidate] = []
    @State private var selectedIDs: Set<String>
    @State private var specID = LabelSheetSpec.avery5163.id
    /// 1-based cell where printing starts; a per-print choice, never persisted.
    @State private var startPosition = 1
    @State private var generated: GeneratedLabelPDF?

    /// Stale preselected ids (a deleted container) are harmless: generation
    /// only ever uses the selection's intersection with live candidates.
    init(preselectedContainerIDs: Set<String> = []) {
        _selectedIDs = State(initialValue: preselectedContainerIDs)
    }

    private var containerRepository: ContainerRepository { ContainerRepository(database: appDatabase) }
    private var settingsRepository: SettingsRepository { SettingsRepository(database: appDatabase) }

    private var spec: LabelSheetSpec {
        LabelSheetSpec.preset(id: specID) ?? .avery5163
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sheet format") {
                    Picker("Sheet format", selection: $specID) {
                        ForEach(LabelSheetSpec.presets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .themedRow()

                Section {
                    Stepper(value: $startPosition, in: 1...spec.cellsPerPage) {
                        LabeledContent("Start at label position", value: "\(startPosition)")
                    }
                } footer: {
                    Text("Skips already-used stickers on a partially-used sheet.")
                }
                .themedRow()

                Section {
                    if candidates.isEmpty {
                        Text("No containers yet — add some first.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(candidates) { candidate in
                            Button {
                                toggle(candidate.id)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(candidate.container.name)
                                        Text(candidate.roomName)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: selectedIDs.contains(candidate.id)
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedIDs.contains(candidate.id)
                                                         ? Color.accentColor : Color.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Containers")
                } footer: {
                    if !selectedIDs.isEmpty {
                        Text("^[\(selectedIDs.count) label](inflect: true) on ^[\(spec.pageCount(forLabelCount: selectedIDs.count, startingAt: startPosition - 1)) sheet](inflect: true).")
                    }
                }
                .themedRow()
            }
            .navigationTitle("Print Labels")
            .navigationBarTitleDisplayMode(.inline)
            .themedScreen()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Select") {
                        Button("Select All") { selectedIDs = Set(candidates.map(\.id)) }
                        Button("Select None") { selectedIDs = [] }
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        generatePDF()
                    } label: {
                        Label("Generate Label Sheet", systemImage: "qrcode")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedIDs.isEmpty)
                }
            }
            .sheet(item: $generated) { generated in
                LabelPDFPreviewView(generated: generated)
            }
            .task {
                if let saved = try? await settingsRepository.value(forKey: Setting.labelSheetSpecKey),
                   LabelSheetSpec.preset(id: saved) != nil {
                    specID = saved
                }
                do {
                    for try await value in containerRepository.observeAllCandidates() {
                        candidates = value
                    }
                } catch {
                    Log.data.error("Label candidate observation failed: \(String(describing: error))")
                }
            }
            .onChange(of: specID) { _, newValue in
                // A position picked for one grid is meaningless on another.
                startPosition = 1
                Task {
                    try? await settingsRepository.setValue(
                        newValue, forKey: Setting.labelSheetSpecKey)
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    /// Slot assignment happens first, so a container keeps the same label
    /// forever; the PDF then renders in slot order.
    private func generatePDF() {
        let spec = spec
        let startOffset = startPosition - 1
        let selection = candidates.filter { selectedIDs.contains($0.id) }
        Task {
            do {
                let slots = try await containerRepository.assignLabelSlots(
                    containerIDs: selection.map(\.id))
                let ordered = selection.sorted {
                    (slots[$0.id] ?? .max) < (slots[$1.id] ?? .max)
                }
                let labels: [LabelPDFRenderer.Label] = ordered.compactMap { candidate in
                    guard let uuid = UUID(uuidString: candidate.container.id) else { return nil }
                    return LabelPDFRenderer.Label(
                        payload: .container(uuid),
                        title: candidate.container.name,
                        subtitle: candidate.roomName)
                }
                let renderer = LabelPDFRenderer(spec: spec)
                let url = FileManager.default.temporaryDirectory
                    .appending(path: "ClutterCatcher-Labels.pdf")
                // Rendering many QR codes is real work — keep it off the
                // main actor so the sheet stays responsive.
                let data = try await Task.detached {
                    let data = renderer.renderPDF(labels: labels, startOffset: startOffset)
                    try data.write(to: url, options: .atomic)
                    return data
                }.value
                generated = GeneratedLabelPDF(data: data, url: url)
            } catch {
                Log.data.error("Label PDF generation failed: \(String(describing: error))")
            }
        }
    }
}

struct GeneratedLabelPDF: Identifiable {
    let id = UUID()
    let data: Data
    let url: URL
}

/// Full-screen preview of the generated sheet with Print and Share.
/// The *page* stays white in every theme — labels print on white sticker
/// stock — while the desk behind it takes the theme background, so the
/// preview reads as a white sheet on a themed desk.
struct LabelPDFPreviewView: View {
    let generated: GeneratedLabelPDF

    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeStore.self) private var themeStore
    /// Anchor for the iPad print popover (M6.2) — rides behind the Print
    /// button so the popover points at it.
    @State private var printAnchor: UIView?

    var body: some View {
        let theme = themeStore.theme
        NavigationStack {
            PDFViewRepresentable(
                data: generated.data,
                deskColor: theme.isClassic ? nil : theme.uiColor(.bg))
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Label Sheet")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        ShareLink(item: generated.url)
                        Button("Print", systemImage: "printer") {
                            printPDF()
                        }
                        .background(PrintAnchorView(view: $printAnchor))
                    }
                }
        }
        // M6.2: the preview finally has room on iPad — page sizing gives the
        // sheet the big canvas; iPhone sheets are unaffected.
        .presentationSizing(.page)
    }

    private func printPDF() {
        let printInfo = UIPrintInfo(dictionary: nil)
        printInfo.outputType = .general
        printInfo.jobName = "ClutterCatcher Labels"
        let controller = UIPrintInteractionController.shared
        controller.printInfo = printInfo
        controller.printingItem = generated.data
        // iPad presents printing as a popover, which needs a source anchor —
        // the bare present(animated:) is iPhone-shaped (M6.2 popover audit).
        // On iPhone the anchored call behaves exactly like the bare one.
        if let anchor = printAnchor, anchor.window != nil {
            _ = controller.present(
                from: anchor.bounds, in: anchor, animated: true, completionHandler: nil)
        } else {
            _ = controller.present(animated: true, completionHandler: nil)
        }
    }
}

/// An invisible UIKit view whose frame tracks the SwiftUI view it backs —
/// the popover source `UIPrintInteractionController` needs on iPad.
private struct PrintAnchorView: UIViewRepresentable {
    @Binding var view: UIView?

    func makeUIView(context: Context) -> UIView {
        let anchor = UIView()
        anchor.isUserInteractionEnabled = false
        // Defer: assigning @State during view construction is a render-loop
        // violation (the DL59 family of timing lessons).
        DispatchQueue.main.async { view = anchor }
        return anchor
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct PDFViewRepresentable: UIViewRepresentable {
    let data: Data
    /// Background behind the rendered page. nil (Classic) leaves PDFView's
    /// default — the structural no-op.
    let deskColor: UIColor?

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        if let deskColor {
            view.backgroundColor = deskColor
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        // `data` is immutable for the lifetime of the preview sheet; the
        // document set in makeUIView stays current, and the theme can't
        // change while this sheet is up (the picker lives in Settings).
    }
}
