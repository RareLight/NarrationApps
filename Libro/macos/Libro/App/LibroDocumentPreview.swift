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

struct LibroDocumentPreview: View {
    let preview: Preview
    @State private var showingSource = false
    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading) {
                HStack {
                    Picker("Preview", selection: $showingSource) {
                        Text("Narration").tag(false); Text("Original Source").tag(true)
                    }.pickerStyle(.segmented)
                    DocumentNavigationMenu(entries: preview.document.navigationEntries) { entry in
                        guard let index = entry.blockIndex, preview.document.blocks.indices.contains(index) else {
                            return
                        }
                        showingSource = true
                        Task { @MainActor in
                            await Task.yield(); proxy.scrollTo(index, anchor: .top)
                        }
                    }
                }
                ScrollView {
                    if showingSource {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(preview.document.blocks.enumerated()), id: \.offset) { index, block in
                                Text(block.text).textSelection(.enabled).id(index)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(preview.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

struct Preview: Identifiable {
    let id: UUID; let title: String; let text: String; let isPDF: Bool; let warnings: [String];
    let document: SemanticDocument
}
