import SwiftUI
import AppPresentation
import LibroCore
import NarrationCore
import NarrationUI

struct LibroDocumentPreview: View {
    @Bindable var model: IntakeModel
    @State private var showingSource = false

    var body: some View {
        if let preview = model.preview {
            VStack(alignment: .leading, spacing: 12) {
                Text(preview.title).appFont(.headline).lineLimit(2)
                if let issue = preview.issue {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .appFont(.caption).foregroundStyle(.secondary)
                } else if !preview.content.isComplete {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(preview.analysisStatus).appFont(.caption)
                    }
                    Text(
                        "Partial preview. Page joins, recurring headers and image descriptions may change as analysis finishes."
                    )
                    .appFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !preview.content.warnings.isEmpty {
                    DisclosureGroup("Analysis notes (\(preview.content.warnings.count))") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(preview.content.warnings, id: \.self) { warning in
                                    Text(warning).appFont(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 120)
                    }
                }
                previewText(preview)
                    .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity).layoutPriority(1)
                HStack {
                    Spacer()
                    Button("Done", action: model.dismissPreview).keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(minWidth: 640, idealWidth: 860, minHeight: 480, idealHeight: 680)
            .onExitCommand(perform: model.dismissPreview)
        }
    }

    private func previewText(_ preview: Preview) -> some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Picker("Preview", selection: $showingSource) {
                        Text("Narration").tag(false)
                        Text("Original Source").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Preview content")
                    DocumentNavigationMenu(entries: preview.content.document.navigationEntries) { entry in
                        guard let index = entry.blockIndex,
                            preview.content.document.blocks.indices.contains(index)
                        else { return }
                        showingSource = true
                        Task { @MainActor in
                            await Task.yield(); proxy.scrollTo(index, anchor: .top)
                        }
                    }
                    .fixedSize()
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if showingSource {
                            ForEach(preview.content.document.blocks.indices, id: \.self) { index in
                                let block = preview.content.document.blocks[index]
                                Text(block.text).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true).id(index)
                            }
                        } else {
                            ForEach(preview.content.chunks, id: \.index) { chunk in
                                Text(chunk.text).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true).id(chunk.index)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct Preview: Identifiable {
    let id: UUID
    let title: String
    let content: DocumentPreviewContent
    var issue: String?

    var analysisStatus: String {
        guard let completed = content.completedPages, let total = content.totalPages else {
            return "Text analysis complete."
        }
        return completed == total
            ? "Text available; finishing analysis…"
            : "Analyzing text · \(completed) of \(total) pages available"
    }
}
