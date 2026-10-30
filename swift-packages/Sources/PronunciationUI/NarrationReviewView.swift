import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NarrationCore
import ProcessingPipeline
import AudioOutput
import Pronunciation

/// Shared explicit review. Preview ownership is joined by both apps' existing
/// start/setup/quit paths. No app library, feed or original export is mutated.
struct NarrationReviewView: View {
    @Bindable var preview: PronunciationPreview
    let configuration: PronunciationPreviewConfiguration?
    let beforeWork: @MainActor () -> Void
    let store = NarrationReviewStore()
    @State private var records: [NarrationReviewStore.Summary] = []
    @State private var selected: UUID?
    @State private var record: NarrationReviewStore.Record?
    @State private var passage = 0
    @State private var split = false
    @State private var applyRules = false
    @State private var message: String?
    @State private var error: String?
    @State private var preparing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Load retained narration") { Task { await reload() } }.disabled(preview.hasOwnedWork || preparing)
            if !records.isEmpty {
                Picker("Recording", selection: $selected) {
                    Text("Choose a recording").tag(UUID?.none)
                    ForEach(records) { item in
                        Text(item.created.formatted(date: .abbreviated, time: .shortened) + " · \(item.passages) passages" + (item.complete ? "" : " · incomplete")).tag(Optional(item.id))
                    }
                }.disabled(preview.hasOwnedWork)
                if let record {
                    Picker("Passage", selection: $passage) {
                        ForEach(record.plan.utterances.indices, id: \.self) { Text("\($0 + 1)").tag($0) }
                    }.disabled(preview.hasOwnedWork)
                    if record.plan.utterances.indices.contains(passage) {
                        Text(record.plan.utterances[passage].text).textSelection(.enabled)
                            .frame(maxHeight: 130, alignment: .topLeading).clipped()
                        if let diagnostic = record.artifacts[passage]?.diagnostics {
                            Text(diagnostic.flags.isEmpty ? "No basic audio flags. Listening is still needed." : "Review: " + diagnostic.flags.map(\.rawValue).joined(separator: ", "))
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Play passage") { play(record) }
                            Button("Check words locally") { check(record) }
                        }.disabled(preview.hasOwnedWork || preparing || record.artifacts[passage] == nil || configuration == nil)
                        Toggle("Replan phrase boundaries when regenerating", isOn: $split).disabled(preview.hasOwnedWork)
                        Toggle("Apply current pronunciation rules", isOn: $applyRules).disabled(preview.hasOwnedWork)
                        HStack {
                            Button("Regenerate passage") { regenerate(record) }.disabled(!record.complete || configuration == nil)
                            Button("Export new WAV…") { export(record) }.disabled(!record.complete)
                            Button(role: .destructive) { remove(record) } label: { Image(systemName: "trash") }.help("Delete retained review material only")
                        }.disabled(preview.hasOwnedWork || preparing)
                        if !record.complete {
                            Button("Generate missing passages") { fillMissing(record) }
                                .disabled(preview.hasOwnedWork || preparing || configuration == nil)
                        }
                    }
                }
            } else { Text("Enable “Keep chunks for narration review” in model details before generating new audio.").foregroundStyle(.secondary) }
            if preview.hasOwnedWork { Button("Stop review") { preview.stop() } }
            if let message { Text(message).foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .onChange(of: selected) { _, id in
            record = nil; passage = 0
            guard let id else { return }
            Task { do { let loaded = try await Task.detached { try store.load(id) }.value; if selected == id { record = loaded } } catch { self.error = error.localizedDescription } }
        }
        .onDisappear { preview.stop() }
    }
    private func reload() async {
        preparing = true; defer { preparing = false }
        do { records = try await Task.detached { try store.records() }.value }
        catch { self.error = error.localizedDescription }
    }
    private func start(_ operation: @escaping @MainActor () async throws -> Void) {
        beforeWork(); error = nil; message = nil
        preview.performReview { do { try await operation() } catch is CancellationError {} catch { self.error = error.localizedDescription } }
    }
    private func play(_ record: NarrationReviewStore.Record) {
        let index = passage
        start {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NarrationReview-\(UUID().uuidString)")
            let audio = directory.appendingPathComponent("passage.wav")
            let task = Task.detached {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let writer = try AtomicAudioWriter(destination: audio)
                defer { writer.abort() }
                try writer.append(samples: store.samples(record.id, index: index), sampleRate: record.plan.settings.model.capabilities.sampleRate)
                try writer.publish(replaceExisting: false)
            }
            do {
                try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                try Task.checkCancellation()
                preview.player.toggle(url: audio, id: record.id.uuidString)
                while preview.player.playingID != nil && !Task.isCancelled { try await Task.sleep(for: .milliseconds(100)) }
            } catch { preview.player.stop(); _ = await Task.detached { try? FileManager.default.removeItem(at: directory) }.value; throw error }
            preview.player.stop(); _ = await Task.detached { try? FileManager.default.removeItem(at: directory) }.value
        }
    }
    private func check(_ record: NarrationReviewStore.Record) {
        let index = passage
        start {
            let task = Task.detached {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NarrationCheck-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }
                let audio = directory.appendingPathComponent("check.wav"), writer = try AtomicAudioWriter(destination: directory.appendingPathComponent("check.wav"))
                defer { writer.abort() }
                try writer.append(samples: store.samples(record.id, index: index), sampleRate: record.plan.settings.model.capabilities.sampleRate); try writer.publish(replaceExisting: false)
                let lease = try await InferenceLease.acquire(priority: .background)
                let text = try await LocalNarrationRecognition.transcribe(audio, language: record.plan.settings.languageCode)
                withExtendedLifetime(lease) {}
                var diagnostic = record.artifacts[index]!.diagnostics
                try diagnostic.compare(expected: record.plan.utterances[index].text, recognized: text)
                return diagnostic
            }
            let diagnostic = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            message = "Word difference: \(Int((diagnostic.wordErrorRate ?? 0) * 100))%. Recognition can misread names and numbers; this is a review signal, not a pronunciation score."
        }
    }
    private func regenerate(_ record: NarrationReviewStore.Record) {
        guard let configuration else { return }
        let index = passage, replan = split, apply = applyRules
        start {
            let task = Task.detached {
                let dictionary = apply ? try PronunciationStore().load().dictionary : nil
                return try await NarrationReviewRepair.regenerate(store: store, id: record.id, index: index,
                    configuration: .init(executable: configuration.worker, inferencePriority: configuration.priority), workspace: configuration.workspace, splitAtSentences: replan, pronunciations: dictionary)
            }
            let id = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation(); await reload(); selected = id
            message = "New take retained. Original recording and published episodes are unchanged."
        }
    }
    private func fillMissing(_ record: NarrationReviewStore.Record) {
        guard let configuration else { return }
        start {
            let task = Task.detached {
                try await NarrationReviewRepair.fillMissing(store: store, id: record.id,
                    configuration: .init(executable: configuration.worker, inferencePriority: configuration.priority), workspace: configuration.workspace)
            }
            let id = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation(); await reload(); selected = id
            message = "Completed a new private take. Verified existing passages and original recordings are unchanged."
        }
    }
    private func export(_ record: NarrationReviewStore.Record) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.wav]; panel.nameFieldStringValue = "Reviewed narration.wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        start {
            let task = Task.detached { try store.export(record.id, to: url) }
            _ = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation(); message = "Saved a new WAV. Original recordings and podcast transcripts are unchanged."
        }
    }
    private func remove(_ record: NarrationReviewStore.Record) {
        start {
            try await Task.detached { try store.remove(record.id) }.value
            selected = nil; self.record = nil; await reload()
        }
    }
}
