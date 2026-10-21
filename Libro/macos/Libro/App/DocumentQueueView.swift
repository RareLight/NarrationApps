import SwiftUI
import AppPresentation
import PronunciationUI
import NarrationUI
import ProcessingPipeline
import AppKit
import UniformTypeIdentifiers
import LibroCore
import NarrationCore
import Darwin
import AVFoundation
import AudioOutput
import OSLog
@preconcurrency import UserNotifications

struct DocumentQueueView: View {
    @Bindable var model: IntakeModel
    @FocusState private var editingOutput: UUID?
    @FocusState private var tableFocused: Bool
    @State private var navigation = QueueKeyboardSelection()

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Documents").appFont(.headline)
                Text("\(model.displayedDocuments.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Preview Selected", systemImage: "doc.text.magnifyingglass") { model.previewSelected() }
                    .disabled(model.selectedDocument == nil || model.busy)
            }.padding(.horizontal, 16)
            Table(of: InputDocument.self, selection: $model.selection) {
                TableColumn("Document") { document in
                    HStack(spacing: 8) {
                        DocumentCoverIcon(digest: model.coverDigests[DocumentCoverPreferences.key(document.source)],
                            store: model.coverStore,
                            symbol: document.kind == .epub ? "book.closed" : document.kind == .pdf ? "doc.richtext" : "doc.text")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(document.source.lastPathComponent).lineLimit(1)
                            if document.textEncoding != .automatic { Text(document.textEncoding.label).appFont(.caption).foregroundStyle(.secondary) }
                            let folder = (document.relativePath as NSString).deletingLastPathComponent
                            if !folder.isEmpty { Text(folder).appFont(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }.help(document.source.path)
                }.width(min: 170, ideal: 260, max: 600)
                TableColumn("Output") { document in
                    TextField("Output name for \(document.source.lastPathComponent)", text: Binding(get: { model.outputName(document) }, set: {
                        model.names[document.id] = $0; model.replan()
                    }))
                    .focused($editingOutput, equals: document.id)
                    .onSubmit { editingOutput = nil; tableFocused = true }
                    .disabled(model.activeIDs.contains(document.id) || (model.outcomes[document.id]?.state == .published && !model.retryQueued.contains(document.id)))
                    .help(model.outputDestinationHint(document))
                }.width(min: 170, ideal: 240, max: 600)
                TableColumn("Status") { document in
                    HStack(alignment: .center, spacing: 8) {
                        Label(model.rowStatus(document), systemImage: statusSymbol(document))
                            .lineLimit(2).help(model.rowStatus(document))
                        Spacer(minLength: 0)
                        if model.outcomes[document.id]?.state == .published {
                            Button("\(model.playingDocument == document.id ? "Stop" : "Play") audio for \(document.source.lastPathComponent)", systemImage: model.playingDocument == document.id ? "stop.fill" : "play.fill") { model.play(document) }
                                .labelStyle(.iconOnly).help("Play or stop saved audio")
                        } else if model.outcomes[document.id]?.state == .failed {
                            Button("Details") { model.showFailure(document) }.help("Failure details for \(document.source.lastPathComponent)")
                        }
                    }
                }.width(min: 160, ideal: 210, max: 330)
            } rows: {
                ForEach(model.displayedDocuments) { document in
                    if model.canDrag(document) {
                        TableRow(document).draggable(model.dragPayload(document))
                    } else { TableRow(document) }
                }
                .dropDestination(for: QueueRowDrag.self) { index, items in model.moveQueue(items, to: index) }
            }
            .focusable().focused($tableFocused)

            .defaultFocus($tableFocused, true)
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                guard editingOutput == nil, press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
                model.selection = navigation.move(rows: model.displayedDocuments.map(\.id), selection: model.selection,
                    forward: press.key == .downArrow, extending: press.modifiers.contains(.shift))
                return .handled
            }
            .onKeyPress(.delete) {
                guard editingOutput == nil else { return .ignored }
                model.removeSelected(); return .handled
            }
            .onKeyPress(.space) {
                guard editingOutput == nil, model.selectedDocument != nil, !model.busy else { return .ignored }
                model.previewSelected(); return .handled
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if ids.count == 1, let document = model.displayedDocuments.first(where: { ids.contains($0.id) }) {
                    Button("Preview Text") { model.showPreview(document) }.disabled(model.busy)
                    if [.text, .markdown].contains(document.kind) {
                        Menu("Text Encoding") {
                            Picker("Text Encoding", selection: Binding(
                                get: { model.documents.first(where: { $0.id == document.id })?.textEncoding ?? document.textEncoding },
                                set: { model.setTextEncoding($0, for: document) })) {
                                ForEach(TextFileEncoding.allCases, id: \.self) { encoding in Text(encoding.label).tag(encoding) }
                            }.pickerStyle(.inline)
                        }
                        .disabled(model.busy || model.activeIDs.contains(document.id) ||
                                  (model.outcomes[document.id]?.state == .published && !model.retryQueued.contains(document.id)))
                    }
                    if document.kind == .epub || document.kind == .pdf {
                        Button("Use Book Cover") { model.useBookCover(document) }.disabled(model.busy || model.isGenerating)
                    }
                    if let outcome = model.outcomes[document.id] {
                        if outcome.state == .published {
                            Button(model.playingDocument == document.id ? "Stop Audio" : "Play Audio") { model.play(document) }
                            Button("Reveal Audio in Finder") { NSWorkspace.shared.activateFileViewerSelecting([outcome.destination]) }
                        } else {
                            if outcome.state == .failed { Button("Failure Details…") { model.showFailure(document) } }
                        }
                    }
                    if model.skippedExisting.contains(document.id) || model.outcomes[document.id] != nil {
                        Button("Queue Again") { model.retry(document) }
                            .disabled(model.busy || model.activeIDs.contains(document.id) || model.retryQueued.contains(document.id))
                    }
                    Divider()
                }
                Button("Remove from Queue") { model.selection = ids; model.removeSelected() }
                    .disabled(ids.isEmpty || model.busy || model.isGenerating)
            } primaryAction: { ids in
                if ids.count == 1, let document = model.displayedDocuments.first(where: { ids.contains($0.id) }) { model.showPreview(document) }
            }
            .onDeleteCommand { if editingOutput == nil { model.removeSelected() } }
            .onExitCommand { editingOutput = nil; tableFocused = true }
        }
    }

    private func statusSymbol(_ document: InputDocument) -> String {
        if model.skippedExisting.contains(document.id) { return "forward.end" }
        if model.retryQueued.contains(document.id) { return "clock" }
        switch model.outcomes[document.id]?.state {
        case .published: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        case .cancelled: return "stop.circle"
        case .skipped: return "forward.end"
        case nil: return model.activeIDs.contains(document.id) ? "waveform" : "clock"
        }
    }
}

private struct DocumentCoverIcon: View {
    let digest: String?
    let store: CoverArtworkStore
    let symbol: String
    @State private var thumbnail: (digest: String, image: NSImage)?

    var body: some View {
        Group {
            if let thumbnail, thumbnail.digest == digest {
                Image(nsImage: thumbnail.image).resizable().scaledToFit()
                    .accessibilityLabel("Cover art assigned")
            } else {
                Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .frame(width: 28, height: 36)
        .task(id: digest) {
            thumbnail = nil
            guard let digest else { return }
            let store = store
            let data = await Task.detached(priority: .utility) {
                try? store.load(digest).thumbnailData()
            }.value
            guard !Task.isCancelled, let data, let image = NSImage(data: data) else { return }
            thumbnail = (digest, image)
        }
    }
}
