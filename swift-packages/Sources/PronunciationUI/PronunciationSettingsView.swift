import SwiftUI
import Pronunciation
import AppPresentation

public struct PronunciationSettingsView: View {
    @State private var editor: PronunciationEditor
    @Bindable private var preview: PronunciationPreview
    @State private var selection: UUID?
    @State private var sentence = ""
    @State private var suggestions: [String] = []
    @State private var suggestionTask: Task<Void, Never>?
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
            SettingsSectionHeader(title: "Pronunciation", explanation: "Matches whole words in any capitalization. New narration only; sources and existing recordings stay unchanged.")
            Text("Enter a word and how it should sound using English letters, for example, “SQLite” → “sequel lite”. The dictionary is shared by Libro and VoiceRelay.")
            VStack(spacing: 12) {
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
                                beforePreview(); preview.play(entry: entry, dictionary: dictionary, configuration: configuration, sentence: sentence)
                            }
                        } label: {
                            if preview.renderingID == entry.id { ProgressView().controlSize(.small) }
                            else { Image(systemName: preview.playingID == entry.id.uuidString ? "stop.fill" : "play.fill") }
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(preview.renderingID == entry.id || preview.playingID == entry.id.uuidString ? "Stop pronunciation preview" : "Play pronunciation for \(entry.word)")
                        .help("Preview with the selected voice")
                        .disabled(configuration == nil || editor.dictionary == nil || entry.word.isEmpty || (entry.spelling.isEmpty && entry.phonemes == nil))
                    }
                    .tag(entry.id)
                    .listRowBackground(Color.clear)
                    .onTapGesture { selection = entry.id }
                }
            }.listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: min(360, max(160, CGFloat(editor.entries.count) * 44)))
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
                .clipShape(.rect(cornerRadius: 12))
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
            if let entry = editor.entries.first(where: { $0.id == selection }) {
                DisclosureGroup("Advanced pronunciation") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Language tag (default en)", text: optionalBinding(entry, \.language))
                            .help("For example en, en-GB, fr or ja. English rules do not apply to other languages.")
                        TextField("Exact document title (blank for all)", text: optionalBinding(entry, \.documentTitle))
                            .help("Matches the title in the narration preview, ignoring capitalization. Overrides shared rules for that title.")
                        Picker("Model", selection: optionalBinding(entry, \.model)) {
                            Text("All models").tag("")
                            ForEach(["kokoro", "soprano", "qwen3", "chatterbox", "orpheus"], id: \.self) { Text($0).tag($0) }
                        }
                        if entry.model == "kokoro" || entry.phonemes != nil {
                            TextField("Kokoro phones (optional)", text: optionalBinding(entry, \.phonemes))
                                .help("Advanced: exact supported Kokoro phonemes. Preview validates vocabulary and alignment; source markup is never interpreted.")
                        }
                    }.textFieldStyle(.roundedBorder)
                }
            }
            DisclosureGroup("Preview a sentence or review names") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Sentence or passage containing the word", text: $sentence, axis: .vertical)
                        .lineLimit(2...5).textFieldStyle(.roundedBorder)
                        .onChange(of: sentence) { _, value in
                            preview.stop(); if value.utf8.count > 64_000 { sentence = String(value.prefix(8_000)) }
                        }
                    Text("Row Play uses this passage when supplied. Suggestions are names to review, not guessed pronunciations.").foregroundStyle(.secondary)
                    Button("Find repeated names") {
                        suggestionTask?.cancel()
                        let text = sentence
                        suggestionTask = Task {
                            let task = Task.detached { try PronunciationSuggestions.repeatedNames(in: text) }
                            do { let names = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }; try Task.checkCancellation(); suggestions = names } catch {}
                        }
                    }
                    ForEach(suggestions, id: \.self) { name in
                        Button("Add “\(name)” for review") {
                            selection = editor.add(word: name); suggestions.removeAll { $0 == name }
                        }.disabled(!editor.loaded || editor.entries.count >= 500)
                    }
                }
            }
            DisclosureGroup("Review retained narration") {
                NarrationReviewView(preview: preview, configuration: configuration, beforeWork: beforePreview)
            }
            }
            .containerRelativeFrame(.horizontal) { width, _ in width * 0.75 }
            .frame(maxWidth: .infinity)
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
        .onDisappear { editor.save(); preview.stop(); suggestionTask?.cancel() }
        .onChange(of: configuration) { _, _ in preview.stop() }
    }
    private func optionalBinding(_ entry: PronunciationEntry, _ path: WritableKeyPath<PronunciationEntry, String?>) -> Binding<String> {
        Binding(get: { editor.entries.first(where: { $0.id == entry.id })?[keyPath: path] ?? "" }, set: { value in
            guard var updated = editor.entries.first(where: { $0.id == entry.id }) else { return }
            preview.stop(); updated[keyPath: path] = value.isEmpty ? nil : value; editor.update(updated)
        })
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
