import Foundation
import Observation
import Pronunciation

@MainActor @Observable public final class PronunciationEditor {
    public private(set) var entries: [PronunciationEntry] = []
    public private(set) var error: String?
    public private(set) var saving = false
    public private(set) var loaded = false
    public private(set) var dirty = false
    @ObservationIgnored private let store: PronunciationStore?
    @ObservationIgnored private var revision: String?
    @ObservationIgnored private var editVersion = 0
    @ObservationIgnored private var conflicted = false
    @ObservationIgnored private var debounce: Task<Void, Never>?
    public init(store: PronunciationStore = .init()) { self.store = store }
    /// Canvas/test state never touches the real dictionary or runtime.
    public init(inertEntries: [PronunciationEntry]) { store = nil; entries = inertEntries; loaded = true }
    public var dictionary: PronunciationDictionary? { try? validated() }
    public var validationMessage: String? { do { _ = try validated(); return nil } catch { return error.localizedDescription } }
    private func validated() throws -> PronunciationDictionary {
        try PronunciationDictionary(entries: entries.filter { !$0.word.isEmpty || !$0.spelling.isEmpty })
    }
    public func add() -> UUID {
        let entry = PronunciationEntry(); entries.append(entry); changed(); return entry.id
    }
    public func remove(id: UUID) { entries.removeAll { $0.id == id }; changed() }
    public func update(_ entry: PronunciationEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry; changed()
    }
    private func changed() {
        dirty = true; editVersion += 1
        if !conflicted { error = nil }
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            self?.save()
        }
    }
    public func reload(discardChanges: Bool = false) async {
        guard let store, !saving, !dirty || discardChanges else { return }
        debounce?.cancel()
        let version = editVersion
        do {
            let snapshot = try await Task.detached { try store.load() }.value
            guard editVersion == version else { return }
            if loaded, snapshot.revision == revision, !discardChanges { error = nil; return }
            entries = snapshot.dictionary.entries; revision = snapshot.revision
            dirty = false; loaded = true; error = nil; conflicted = false
        } catch { self.error = error.localizedDescription }
    }
    public func save() {
        guard loaded, !saving, !conflicted, dirty, let store else { return }
        let values: [PronunciationEntry]
        do { values = try validated().entries } catch { self.error = error.localizedDescription; return }
        saving = true
        let expected = revision, version = editVersion
        Task {

            do {
                let snapshot = try await Task.detached { try store.save(entries: values, expectedRevision: expected) }.value
                revision = snapshot.revision
                dirty = editVersion != version; error = nil

            } catch {
                self.error = error.localizedDescription
                if error as? PronunciationError == .conflict { conflicted = true }
            }
            saving = false
            if dirty && error == nil { save() }
        }
    }
}
