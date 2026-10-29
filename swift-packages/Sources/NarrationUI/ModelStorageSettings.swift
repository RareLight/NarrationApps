import SwiftUI
import AppKit
import Observation
import AppPresentation
import NativeSpeech
import NarrationCore

@MainActor @Observable
public final class ModelStorageMaintenance {
    public private(set) var isBusy = false
    public private(set) var error: String?
    public private(set) var revision = 0
    private var task: Task<Void, Never>?
    public init() {}
    public func remove(_ model: NarrationCore.SpeechModel, at root: URL, changed: @escaping @MainActor () -> Void) {
        guard !isBusy else { return }
        isBusy = true; error = nil
        task = Task {
            defer { isBusy = false; task = nil; revision += 1; changed() }
            let work = Task.detached(priority: .utility) { try NativeModelStorage.remove(model, at: root) }
            do { try await work.value }
            catch { self.error = error.localizedDescription }
        }
    }
    public func waitForIdle() async { await task?.value }
}

/// A selected model's local footprint, loaded off the UI actor. Request identity
/// rejects late results after a selection/folder change, including failed scans.
@MainActor @Observable
final class SelectedModelStorage {
    struct Selection: Hashable, Sendable {
        let root: URL
        let model: SpeechModel
    }
    enum Action: Equatable { case checking, download, cached, imported, unavailable }
    private(set) var selection: Selection?
    private(set) var entry: StoredSpeechModel?
    private(set) var error: String?
    private(set) var loading = false
    private var request = UUID()
    private let scan: @Sendable (Selection) async throws -> StoredSpeechModel?

    init(scan: @escaping @Sendable (Selection) async throws -> StoredSpeechModel? = { selection in
        let work = Task.detached(priority: .utility) {
            try NativeModelStorage.entries(at: selection.root, models: [selection.model]).first
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }) { self.scan = scan }

    func action(for current: Selection?) -> Action {
        guard let current else { return .unavailable }
        guard selection == current, !loading else { return .checking }
        if error != nil { return .unavailable }
        guard let entry else { return .download }
        return entry.imported ? .imported : .cached
    }

    func load(_ selection: Selection) async {
        let token = UUID(); request = token
        self.selection = selection; loading = true; entry = nil; error = nil
        defer { if request == token { loading = false } }
        do {
            let result = try await scan(selection)
            try Task.checkCancellation()
            guard request == token else { return }
            entry = result
        } catch is CancellationError {
            // An interrupted scan must never enable Download for an unknown cache.
            if request == token { self.selection = nil }
        } catch {
            guard request == token else { return }
            if Task.isCancelled { self.selection = nil; return }
            self.error = error.localizedDescription
        }
    }
}

/// A compact table that never stretches its size/delete columns across the window.
/// Kept separate from loading so sizing it cannot read or mutate model storage.
struct ModelStorageInventory: View {
    let entries: [StoredSpeechModel]
    let canManage: Bool
    let remove: (StoredSpeechModel) -> Void
    @Environment(\.appTextSize) private var textSize
    @Environment(\.dynamicTypeSize) private var dynamicType
    private var scale: CGFloat { max(1, AppTypography.scale(size: textSize, dynamic: dynamicType)) }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8 * scale, verticalSpacing: 6 * scale) {
            ForEach(entries) { entry in
                GridRow(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.model.label).fixedSize(horizontal: false, vertical: true)
                            .frame(minHeight: 28 * scale, alignment: .leading)
                        if entry.imported {
                            Text("Imported · manage in Finder").appFont(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.frame(width: 120 * scale, alignment: .leading)
                    Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 80 * scale, alignment: .trailing).frame(minHeight: 28 * scale)
                    if entry.imported {
                        Color.clear.frame(width: 32 * scale, height: 28 * scale).accessibilityHidden(true)
                    } else {
                        Button("Delete " + entry.model.label, systemImage: "trash") { remove(entry) }
                            .labelStyle(.iconOnly).help("Delete downloaded model")
                            .frame(width: 32 * scale, height: 28 * scale).disabled(!canManage)
                    }
                }
            }
        }.frame(width: 248 * scale, alignment: .leading)
    }
}

/// The same downloaded-model inventory and deletion flow in both apps.
public struct ModelStorageSettings: View {
    private let root: URL
    private let canManage: Bool
    private let revision: Int
    private let choose: () -> Void
    private let useDefault: () -> Void
    private let changed: @MainActor @Sendable () -> Void
    @Bindable private var maintenance: ModelStorageMaintenance
    @State private var entries: [StoredSpeechModel] = []
    @State private var loadedRoot: URL?
    @State private var removing: SelectedModelStorage.Selection?
    @State private var error: String?
    @State private var reload = 0
    @Environment(\.scenePhase) private var scenePhase

    public init(root: URL, canManage: Bool, revision: Int = 0, choose: @escaping () -> Void,
                useDefault: @escaping () -> Void, changed: @escaping @MainActor @Sendable () -> Void, maintenance: ModelStorageMaintenance) {
        self.root = root; self.canManage = canManage; self.revision = revision
        self.choose = choose; self.useDefault = useDefault; self.changed = changed; self.maintenance = maintenance
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(root.path).appFont(.caption).textSelection(.enabled).lineLimit(2).help(root.path)
            HStack {
                Button("Choose Folder…", action: choose)
                Button("Use Hugging Face Cache", action: useDefault)
                    .disabled(root.standardizedFileURL.resolvingSymlinksInPath().path == NativeModelStorage.defaultRoot.path)
            }.disabled(!canManage || maintenance.isBusy)
            if loadedRoot == root {
                if entries.isEmpty { Text("No downloaded models in this location.").foregroundStyle(.secondary) }
                else {
                    ScrollView(.horizontal) {
                        ModelStorageInventory(entries: entries, canManage: canManage && !maintenance.isBusy) {
                            removing = .init(root: root, model: $0.model)
                        }
                    }.fixedSize(horizontal: false, vertical: true)
                }
            } else if error == nil {
                ProgressView("Checking models…").controlSize(.small)
            }
            Text("Sizes exclude shared support files. Deletion affects other apps using this folder.")
                .appFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if maintenance.isBusy { ProgressView().controlSize(.small) }
            if let error = maintenance.error ?? error { Text(error).foregroundStyle(.red).appFont(.caption) }
        }
        .task(id: "\(root.path):\(revision):\(maintenance.revision):\(reload)") {
            let path = root
            entries = []; loadedRoot = nil; removing = nil; error = nil
            let work = Task.detached(priority: .utility) { try NativeModelStorage.entries(at: path) }
            do {
                let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation(); entries = result; loadedRoot = path; error = nil
            } catch is CancellationError {} catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .onChange(of: root) { _, _ in removing = nil }
        .onChange(of: scenePhase) { _, phase in if phase == .active { reload += 1 } }
        .confirmationDialog("Delete downloaded model?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { entry in
            Button("Delete " + entry.model.label, role: .destructive) { remove(entry) }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { entry in
            Text("Delete all cached revisions of \(entry.model.label) in this location? Other apps and unfinished jobs may need it downloaded again. Recordings and reference voices are kept. Quit other apps using this model first.")
        }
    }
    private func remove(_ entry: SelectedModelStorage.Selection) {
        guard canManage, !maintenance.isBusy, loadedRoot == root, entry.root == root,
              entries.contains(where: { $0.id == entry.model && !$0.imported }) else { return }
        removing = nil
        maintenance.remove(entry.model, at: entry.root, changed: changed)
    }
}
