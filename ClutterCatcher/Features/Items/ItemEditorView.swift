import PhotosUI
import SwiftUI

/// Create/edit sheet for an item: photo, name, quantity, category, notes.
///
/// Photo model (M6): the chosen `photo_asset_ref` is *staged* in the editor
/// and committed with Save, exactly like the other fields — so cancelling
/// discards a freshly captured photo and never disturbs the item's existing
/// one. Every ref minted this session that isn't the final choice (plus the
/// original when it's replaced/removed) is cleaned up at commit; a cancel
/// deletes only the uncommitted captures. Container cover, by contrast, edits
/// the *container* and applies immediately (§6).
struct ItemEditorView: View {
    /// nil creates a new item in `containerID`.
    let item: Item?
    let containerID: String

    @Environment(\.appDatabase) private var appDatabase
    @Environment(\.photoStore) private var photoStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var quantity: Int
    @State private var notes: String
    @State private var categoryID: String?
    @State private var categories: [Category] = []
    @State private var isConfirmingDelete = false
    @State private var saveError: String?
    @State private var createdByName: String?

    // Photo state (M6).
    @State private var photoAssetRef: String?
    @State private var isCover = false
    @State private var isShowingSourceChooser = false
    @State private var isShowingCamera = false
    @State private var isShowingLibrary = false
    @State private var isShowingFullScreen = false
    @State private var pickedItem: PhotosPickerItem?
    /// Every ref captured/picked this session, in order — the cleanup ledger.
    @State private var sessionRefs: [String] = []
    /// Set once a Save or Delete commits, so `onDisappear` doesn't treat a
    /// committed edit as a cancel and delete the wrong files.
    @State private var didCommit = false

    /// The item's photo ref as it stands in the database — the file to keep on
    /// cancel and to delete when a Save replaces or removes it.
    private let originalRef: String?

    private var itemRepository: ItemRepository { ItemRepository(database: appDatabase) }
    private var categoryRepository: CategoryRepository { CategoryRepository(database: appDatabase) }
    private var containerRepository: ContainerRepository { ContainerRepository(database: appDatabase) }

    init(item: Item?, containerID: String) {
        self.item = item
        self.containerID = containerID
        _name = State(initialValue: item?.name ?? "")
        _quantity = State(initialValue: item?.quantity ?? 1)
        _notes = State(initialValue: item?.notes ?? "")
        _categoryID = State(initialValue: item?.categoryId)
        _photoAssetRef = State(initialValue: item?.photoAssetRef)
        originalRef = item?.photoAssetRef
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                photoSection
                Section {
                    TextField("Item name", text: $name)
                        .textInputAutocapitalization(.words)
                    Stepper(value: $quantity, in: 1...999) {
                        LabeledContent("Quantity", value: "\(quantity)")
                    }
                }
                Section("Category") {
                    Picker("Category", selection: $categoryID) {
                        Text("None").tag(String?.none)
                        ForEach(categories) { category in
                            HStack {
                                Circle()
                                    .fill(Tokens.categoryColor(for: category.colorToken))
                                    .frame(width: 10, height: 10)
                                Text(category.name)
                            }
                            .tag(String?.some(category.id))
                        }
                    }
                }
                Section {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Notes")
                } footer: {
                    if let createdByName {
                        Text("Added by \(createdByName)")
                    }
                }
                if item != nil {
                    Section {
                        Button("Delete Item", role: .destructive) {
                            isConfirmingDelete = true
                        }
                    }
                }
            }
            .navigationTitle(item == nil ? "New Item" : "Edit Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(trimmedName.isEmpty)
                }
            }
            .confirmationDialog(
                "Delete this item?",
                isPresented: $isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Item", role: .destructive) { deleteItem() }
            }
            .confirmationDialog(
                "Item Photo",
                isPresented: $isShowingSourceChooser,
                titleVisibility: .visible
            ) {
                Button("Take Photo") { isShowingCamera = true }
                Button("Choose from Library") { isShowingLibrary = true }
                if photoAssetRef != nil {
                    Button("Remove Photo", role: .destructive) { removePhoto() }
                }
            }
            .sheet(isPresented: $isShowingCamera) {
                CameraPicker(
                    onImage: { image in handleCaptured(image) },
                    onFinish: { isShowingCamera = false }
                )
                .ignoresSafeArea()
            }
            .photosPicker(isPresented: $isShowingLibrary, selection: $pickedItem, matching: .images)
            .fullScreenCover(isPresented: $isShowingFullScreen) {
                if let ref = photoAssetRef {
                    FullScreenPhotoView(ref: ref)
                }
            }
            .onChange(of: pickedItem) { _, newItem in
                loadPickedItem(newItem)
            }
            .saveErrorAlert($saveError)
            .task {
                await loadSupportingState()
            }
            .onDisappear {
                // A cancel (button or interactive dismiss) discards only the
                // uncommitted captures; the item keeps `originalRef`.
                if !didCommit {
                    discardSessionFiles(keeping: originalRef)
                }
            }
        }
    }

    // MARK: Photo section

    @ViewBuilder private var photoSection: some View {
        Section {
            if let ref = photoAssetRef {
                HStack(spacing: Tokens.spacingL) {
                    Button {
                        isShowingFullScreen = true
                    } label: {
                        PhotoThumbnailView(ref: ref, size: 88)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View photo full screen")

                    VStack(alignment: .leading, spacing: Tokens.spacingM) {
                        Button("Replace Photo") { isShowingSourceChooser = true }
                        Button("Remove Photo", role: .destructive) { removePhoto() }
                    }
                }
                if item != nil {
                    Button {
                        toggleCover()
                    } label: {
                        HStack {
                            Label("Set as Container Cover", systemImage: "square.grid.2x2")
                            Spacer()
                            if isCover {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .accessibilityLabel("Current cover")
                            }
                        }
                    }
                }
            } else {
                Button {
                    isShowingSourceChooser = true
                } label: {
                    Label("Add Photo", systemImage: "camera")
                }
            }
        } header: {
            Text("Photo")
        }
    }

    // MARK: Photo actions

    private func handleCaptured(_ image: UIImage) {
        do {
            // Runs on the main actor: a single ≤2048 px encode is brief, and
            // this avoids passing a UIImage across an isolation boundary.
            let ref = try photoStore.importImage(image)
            sessionRefs.append(ref)
            photoAssetRef = ref
        } catch {
            Log.data.error("Photo import failed: \(String(describing: error))")
            saveError = "Couldn't process that photo — try again."
        }
    }

    private func loadPickedItem(_ pickerItem: PhotosPickerItem?) {
        guard let pickerItem else { return }
        Task {
            defer { pickedItem = nil }
            do {
                if let data = try await pickerItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    handleCaptured(image)
                } else {
                    saveError = "Couldn't load that photo."
                }
            } catch {
                Log.data.error("Loading picked photo failed: \(String(describing: error))")
                saveError = "Couldn't load that photo."
            }
        }
    }

    private func removePhoto() {
        // Files are cleaned at commit/cancel via `sessionRefs`/`originalRef`;
        // clearing the staged ref is all that's needed here.
        photoAssetRef = nil
    }

    private func toggleCover() {
        guard let itemID = item?.id else { return }
        let makeCover = !isCover
        isCover = makeCover
        Task {
            do {
                try await containerRepository.setCover(
                    containerID: containerID, itemID: makeCover ? itemID : nil)
            } catch {
                isCover = !makeCover // revert on failure
                Log.data.error("Set cover failed: \(String(describing: error))")
                saveError = error.localizedDescription
            }
        }
    }

    // MARK: Load

    private func loadSupportingState() async {
        do {
            categories = try await categoryRepository.allCategories()
        } catch {
            Log.data.error("Category fetch for picker failed: \(String(describing: error))")
        }
        if let createdBy = item?.createdBy {
            createdByName = try? await appDatabase.writer.read { db in
                try Participant.displayName(db, createdBy: createdBy)
            }
        }
        if let item {
            do {
                let container = try await containerRepository.fetchContainer(id: containerID)
                isCover = (container?.coverItemId == item.id)
            } catch {
                Log.data.error("Cover state fetch failed: \(String(describing: error))")
            }
        }
    }

    // MARK: Save / delete

    private func save() {
        let name = trimmedName
        let quantity = quantity
        let notes = notes
        let categoryID = categoryID
        let photoAssetRef = photoAssetRef
        let existing = item
        Task {
            do {
                if var item = existing {
                    item.name = name
                    item.quantity = quantity
                    item.notes = notes
                    item.categoryId = categoryID
                    item.photoAssetRef = photoAssetRef
                    try await itemRepository.updateItem(item)
                } else {
                    try await itemRepository.createItem(
                        containerID: containerID,
                        name: name,
                        quantity: quantity,
                        notes: notes,
                        categoryID: categoryID,
                        photoAssetRef: photoAssetRef)
                }
                didCommit = true
                cleanUpAfterCommit(keeping: photoAssetRef)
                dismiss()
            } catch {
                Log.data.error("Item save failed: \(String(describing: error))")
                saveError = error.localizedDescription
            }
        }
    }

    private func deleteItem() {
        guard let id = item?.id else { return }
        let refs = Set(sessionRefs + [originalRef, photoAssetRef].compactMap { $0 })
        Task {
            do {
                try await itemRepository.deleteItems(ids: [id])
                didCommit = true
                for ref in refs { try? photoStore.delete(id: ref) }
                dismiss()
            } catch {
                Log.data.error("Item delete failed: \(String(describing: error))")
                saveError = error.localizedDescription
            }
        }
    }

    // MARK: Photo cleanup

    /// After a committed Save: delete every session capture and the original
    /// ref, except the one now in effect. A no-op when the photo is unchanged.
    private func cleanUpAfterCommit(keeping keptRef: String?) {
        var doomed = Set(sessionRefs)
        if let originalRef { doomed.insert(originalRef) }
        if let keptRef { doomed.remove(keptRef) }
        for ref in doomed { try? photoStore.delete(id: ref) }
    }

    /// On cancel: delete only the uncommitted captures (keep `keptRef`, the
    /// original the DB row still points at).
    private func discardSessionFiles(keeping keptRef: String?) {
        for ref in sessionRefs where ref != keptRef {
            try? photoStore.delete(id: ref)
        }
    }
}
