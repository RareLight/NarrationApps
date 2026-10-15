import SwiftUI
import Pronunciation

public struct PronunciationSettingsView: View {
    @State private var editor: PronunciationEditor
    @Bindable private var preview: PronunciationPreview
    @State private var selection: UUID?
    private let configuration: PronunciationPreviewConfiguration?
    private let unavailableReason: String?
    private let beforePreview: @MainActor () -> Void
    public init(preview: PronunciationPreview, configuration: PronunciationPreviewConfiguration?, unavailableReason: String? = nil,
                editor: PronunciationEditor = .init(), beforePreview: @escaping @MainActor () -> Void = {}) {
        self.beforePreview = beforePreview; self.preview = preview; self.configuration = configuration; self.unavailableReason = unavailableReason
        _editor = State(initialValue: editor)
    }
    public var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pronunciation").fontWeight(.semibold)
            Text("Enter a word and how it should sound using English letters, for example, “SQLite” → “sequel lite”. The dictionary is shared by Libro and VoiceRelay.")
            Text("Matches whole words without regard to capitalization. Changes apply to new narration; source documents and existing recordings are preserved.").foregroundStyle(.secondary)
            List(selection: $selection) {
                ForEach(editor.entries) { entry in
                    HStack {
                        TextField("Word", text: binding(entry, \.word))
                            .accessibilityLabel("Word")
                        TextField("Phonetic spelling", text: binding(entry, \.spelling)).autocorrectionDisabled()
                            .accessibilityLabel("Phonetic spelling for \(entry.word)")
                        Button {
                            if preview.renderingID == entry.id || preview.playingID == entry.id.uuidString { preview.stop() }
                            else if let configuration, let dictionary = editor.dictionary {
                                beforePreview(); preview.play(entry: entry, dictionary: dictionary, configuration: configuration)
                            }
                        } label: {
                            if preview.renderingID == entry.id { ProgressView().controlSize(.small) }
                            else { Image(systemName: preview.playingID == entry.id.uuidString ? "stop.fill" : "play.fill") }
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(preview.renderingID == entry.id || preview.playingID == entry.id.uuidString ? "Stop pronunciation preview" : "Play pronunciation for \(entry.word)")
                        .help("Render and play using the currently selected voice")
                        .disabled(configuration == nil || editor.dictionary == nil || entry.word.isEmpty || entry.spelling.isEmpty)
                    }
                    .tag(entry.id)
                    .onTapGesture { selection = entry.id }
                }
            }.listStyle(.bordered).frame(height: min(360, max(160, CGFloat(editor.entries.count) * 44)))
            HStack {
                ControlGroup {
                    Button { selection = editor.add() } label: { Image(systemName: "plus") }
                        .help("Add pronunciation").accessibilityLabel("Add pronunciation").disabled(!editor.loaded || editor.entries.count >= 500)
                    Button { if let selection { preview.stop(); editor.remove(id: selection); self.selection = nil } } label: { Image(systemName: "minus") }
                        .help("Remove selected pronunciation").accessibilityLabel("Remove selected pronunciation").disabled(selection == nil)
                }.fixedSize()
                Spacer()
                Button("Reload") { preview.stop(); Task { await editor.reload(discardChanges: true) } }.disabled(editor.saving)
                Button("Save") { editor.save() }.disabled(!editor.dirty || editor.dictionary == nil || editor.saving)
            }
            if let error = editor.error ?? editor.validationMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            else { Text(!editor.loaded ? "Loading dictionary…" : editor.saving ? "Saving…" : (editor.dirty ? "Unsaved changes" : "Saved locally. Valid changes save automatically.")).foregroundStyle(.secondary) }
            if let error = preview.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let unavailableReason { Text(unavailableReason).foregroundStyle(.secondary) }
            else { Text("Play uses your selected voice and speed. A new preview may take a moment to prepare.").foregroundStyle(.secondary) }
        }
        .padding()
        }
        .task {
            await editor.reload()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                await editor.reload()
            }
        }
        .onDisappear { editor.save(); preview.stop() }
        .onChange(of: configuration) { _, _ in preview.stop() }
    }
    private func binding(_ entry: PronunciationEntry, _ path: WritableKeyPath<PronunciationEntry, String>) -> Binding<String> {
        Binding(get: { editor.entries.first(where: { $0.id == entry.id })?[keyPath: path] ?? "" }, set: { value in
            guard var updated = editor.entries.first(where: { $0.id == entry.id }) else { return }
            preview.stop(); updated[keyPath: path] = value; editor.update(updated)
        })
    }
}

#Preview("Pronunciation — inert dictionary") {
    PronunciationSettingsView(preview: .init(), configuration: nil, unavailableReason: "Install a speech model to preview pronunciations.",
        editor: .init(inertEntries: [.init(word: "SQLite", spelling: "sequel lite"), .init(word: "Libro", spelling: "lee bro")]))
        .frame(width: 600, height: 500)
}
