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
                        Text("^[\(selectedIDs.count) label](inflect: true) on ^[\(spec.pageCount(forLabelCount: selectedIDs.count)) sheet](inflect: true).")
                    }
                }
            }
            .navigationTitle("Print Labels")
            .navigationBarTitleDisplayMode(.inline)
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
                    let data = renderer.renderPDF(labels: labels)
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
struct LabelPDFPreviewView: View {
    let generated: GeneratedLabelPDF

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PDFViewRepresentable(data: generated.data)
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
                    }
                }
        }
    }

    private func printPDF() {
        let printInfo = UIPrintInfo(dictionary: nil)
        printInfo.outputType = .general
        printInfo.jobName = "ClutterCatcher Labels"
        let controller = UIPrintInteractionController.shared
        controller.printInfo = printInfo
        controller.printingItem = generated.data
        _ = controller.present(animated: true, completionHandler: nil)
    }
}

private struct PDFViewRepresentable: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        // `data` is immutable for the lifetime of the preview sheet; the
        // document set in makeUIView stays current.
    }
}
