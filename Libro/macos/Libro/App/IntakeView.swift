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

struct IntakeView: View {
    @Bindable var model: IntakeModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var dropTarget = false
    @State private var showingNextBatchSettings = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if let batch = model.activeBatch {
                    Label("Current batch · \(batch.documents.count) documents", systemImage: "waveform").appFont(.headline)
                    Text(batchDescription(batch)).appFont(.callout).foregroundStyle(.secondary)
                    HStack {
                        Text("\(model.candidates.count) documents waiting for the next batch")
                            .appFont(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Next Batch Settings…") { showingNextBatchSettings = true }
                    }
                } else {
                    NarrationControls(model: model)
                    setupStatus
                }
            }.padding(16)
            Divider()
            if model.displayedDocuments.isEmpty {
                ContentUnavailableView {
                    Label("Add documents", systemImage: "doc.badge.plus")
                } description: {
                    Text("Drop TXT, Markdown, RTF, PDF files, or folders. Subfolders are included.")
                } actions: {
                    Button("Add Documents…") { model.openInputs() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DocumentQueueView(model: model).padding(.top, 12)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let batch = model.activeBatch {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Current batch saves to").appFont(.caption).foregroundStyle(.secondary)
                            Text(batch.outputDirectory.path).lineLimit(2).truncationMode(.middle)
                                .textSelection(.enabled).help(batch.outputDirectory.path)
                        }
                        Spacer()
                        Button("Reveal current batch output folder", systemImage: "folder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: batch.outputDirectory.path) }
                            .labelStyle(.iconOnly)
                    }
                } else {
                    DirectoryRow(model: model, label: "Save audio to", selection: model.output, role: .output)
                }
                inputAndPlanningFeedback
                activity
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        if !model.isGenerating {
                            Text("\(model.candidates.count) \(model.candidates.count == 1 ? "document" : "documents") queued")
                                .appFont(.caption).foregroundStyle(.secondary)
                            if let blocker = model.generationBlocker, blocker != .preparation, blocker != .intake, blocker != .planning {
                                Text(blocker.message).appFont(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if model.outcomes.values.contains(where: { $0.state != .published }) {
                        Button("Queue Unfinished") { model.retryUnfinished() }
                            .disabled(model.documents.allSatisfy { model.outcomes[$0.id]?.state == .published || model.retryQueued.contains($0.id) || model.outcomes[$0.id] == nil })
                            .help("Queue failed or cancelled documents for the next batch")
                    }
                    if model.isGenerating { Button("Cancel Batch") { model.cancel() } }
                    else {
                        Button("Generate Audio") { model.generate() }.buttonStyle(.borderedProminent)
                            .disabled(!model.canGenerate).help(model.generationBlocker?.message ?? "Generate the queued documents")
                    }
                }
            }.padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 8).stroke(.tint, lineWidth: 3).padding(4).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in model.importDrop(providers) }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Add Documents…", systemImage: "doc.badge.plus") { model.openInputs() }.labelStyle(.titleAndIcon)
                Menu("Queue Actions", systemImage: "ellipsis") {
                    Button("Add Folder…", systemImage: "folder.badge.plus") { model.openInputs(foldersOnly: true) }
                    Divider()
                    Button("Remove Selected", systemImage: "minus") { model.removeSelected() }.disabled(model.selection.isEmpty || model.busy || model.isGenerating)
                    Button("Clear Finished") { model.clearFinished() }.disabled(!model.hasFinished || model.busy || model.isGenerating)
                    Button("Clear Queue") { model.clear() }.disabled(model.documents.isEmpty || model.busy || model.isGenerating)
                }
            }
        }
        .onAppear { model.reopenWindow = { openWindow(id: "main") }; model.replan() }
        .sheet(isPresented: $showingNextBatchSettings) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Next batch settings").appFont(.headline)
                NarrationControls(model: model)
                DirectoryRow(model: model, label: "Next batch saves to", selection: model.output, role: .output)
                Text("Changes apply when you start the next batch. The current batch keeps its original settings and destination.")
                    .appFont(.callout).foregroundStyle(.secondary)
                HStack {
                    Text("Closing the main window keeps processing. Quitting offers cancellation.")
                        .appFont(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { showingNextBatchSettings = false }.keyboardShortcut(.defaultAction)
                }
            }.padding(20).frame(width: 660).onExitCommand { showingNextBatchSettings = false }
        }
        .sheet(item: $model.failureDetails) { details in
            VStack(alignment: .leading, spacing: 16) {
                Text("Generation failed: \(details.name)").appFont(.headline)
                Text(details.message).textSelection(.enabled)
                DisclosureGroup("Diagnostics") {
                    Text("Job: \(details.id.uuidString)").appFont(.caption).textSelection(.enabled)
                    if let url = model.debugLogURL { Button("Open Debug Log") { NSWorkspace.shared.open(url) } }
                    Button("Troubleshooting Settings…") { model.settingsTab = .troubleshooting; model.failureDetails = nil; openSettings() }
                    Text("Enable debug logging before generating again. The log stays in the selected workspace.")
                        .appFont(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Queue Again") {
                        if let document = model.documents.first(where: { $0.id == details.id }) { model.retry(document) }
                        model.failureDetails = nil
                    }.help("Queue this document; use Generate Audio to start the next batch")
                    Spacer()
                    Button("Done") { model.failureDetails = nil }.keyboardShortcut(.defaultAction)
                }
            }.padding().frame(width: 560).onExitCommand { model.failureDetails = nil }
        }
        .sheet(item: $model.preview) { preview in
            VStack(alignment: .leading, spacing: 12) {
                Text(preview.title).appFont(.headline)
                if preview.isPDF { Text("PDF reading order and repeated headers may need review.").appFont(.caption).foregroundStyle(.secondary) }
                ForEach(preview.warnings, id: \.self) { warning in
                    Text(warning).appFont(.caption).foregroundStyle(.secondary)
                }
                LibroDocumentPreview(preview: preview)
                Button("Done") { model.preview = nil }.keyboardShortcut(.defaultAction)
            }.padding().frame(minWidth: 560, minHeight: 420).onExitCommand { model.preview = nil }
        }
    }

    @ViewBuilder private var setupStatus: some View {
        if model.workspace?.url == nil {
            HStack {
                Label(model.workspace?.error ?? "Choose a Libro workspace to use local models.", systemImage: "exclamationmark.triangle")
                    .appFont(.callout)
                Spacer()
                Button("Model Settings…") { model.settingsTab = .models; openSettings() }
            }
        } else if model.isPreparingModel {
            HStack { Text(model.preparationIsCheck ? "Checking speech setup…" : "Installing speech model…"); Spacer(); Button(model.preparationIsCheck ? "Cancel Check" : "Cancel Installation") { model.cancel() } }
        } else if model.checkingAssets {
            HStack { ProgressView().controlSize(.small); Text(model.readiness).appFont(.callout) }
        } else if !model.assetsReady || model.setupVerificationFailed {
            HStack(alignment: .center) {
                Label(model.setupVerificationFailed ? model.preparationStatus : model.readiness, systemImage: "exclamationmark.triangle")
                    .appFont(.callout).lineLimit(2)
                Spacer()
                Button("Speech Setup…") { model.settingsTab = .models; openSettings() }
                    .help("Install a model or check speech setup in Models settings")
            }
        } else {
            HStack {
                Label("Ready for offline generation", systemImage: "checkmark.circle").appFont(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    @ViewBuilder private var inputAndPlanningFeedback: some View {
        if let error = model.planningError, model.output?.url != nil {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
        }
        if let error = model.dropError { Label(error, systemImage: "exclamationmark.triangle").textSelection(.enabled) }
        if let message = model.debugLogStatus { Label(message, systemImage: "exclamationmark.triangle").textSelection(.enabled) }
        if model.planning { ProgressView("Checking output destinations…").controlSize(.small) }
        if model.planned.contains(where: \.replacesExisting) {
            Label("\(model.planned.filter(\.replacesExisting).count) existing outputs. Libro will ask before replacing them.", systemImage: "doc.on.doc")
                .appFont(.caption).foregroundStyle(.secondary)
        }
        if let summary = model.importSummary {
            DisclosureGroup(model.issues.isEmpty ? "Import details" : "Input errors · \(model.issues.count)") {
                Text(summary).appFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if !model.issues.isEmpty {
                    ScrollView {
                        ForEach(Array(model.issues.enumerated()), id: \.offset) { _, issue in
                            Text("\(issue.source.lastPathComponent): \(issue.message)").textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.frame(maxHeight: 100)
                }
            }.appFont(.callout)
        }
    }

    @ViewBuilder private var activity: some View {
        if model.isGenerating {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.generationStatus).appFont(.callout).lineLimit(2).truncationMode(.middle)
                    .help(model.generationStatus).textSelection(.enabled)
                if let progress = model.activityProgress?.preparation?.progress {
                    if let fraction = progress.fractionCompleted {
                        ProgressView(value: fraction) {
                            Text(progress.countLabel ?? "Preparing document…").appFont(.caption)
                        }.accessibilityLabel(progress.countLabel ?? "Document preparation")
                    } else { ProgressView().controlSize(.small) }
                } else if let progress = model.speechProgress, progress.phase != .publishing {
                    ProgressView(value: Double(progress.completedChunks), total: Double(max(1, progress.totalChunks))) {
                        Text("\(progress.completedChunks) of \(progress.totalChunks) chunks").appFont(.caption)
                    }
                    DisclosureGroup("Generation details") {
                        Text("\(progress.completedChunks) of \(progress.totalChunks) chunks")
                            .appFont(.caption).foregroundStyle(.secondary)
                    }
                } else { ProgressView().controlSize(.small) }
            }
        } else if model.isPreparingModel {
            PreparationProgressView(model: model)
        } else if model.busy && !model.hasOwnedProbe {
            HStack {
                ProgressView().controlSize(.small)
                Text(model.activityStatus).appFont(.callout)
                Spacer(); Button(model.inputCancelLabel) { model.cancelIntake() }
            }
        } else if let summary = model.batchSummary {
            Label(model.generationStatus, systemImage: summary.cancelled ? "stop.circle" : (summary.failedCount > 0 ? "exclamationmark.circle" : "checkmark.circle"))
                .appFont(.callout).textSelection(.enabled)
            idleFeedback
        } else {
            if let summary = model.notificationSummary { Text(summary).appFont(.callout) }
            idleFeedback
        }
    }

    @ViewBuilder private var idleFeedback: some View {
        if model.status != "Add documents or drop files and folders here.", model.status != model.importSummary,
           model.status != model.generationStatus, model.status != model.probeStatus {
            Text(model.status).appFont(.callout).textSelection(.enabled)
        } else if model.batchSummary == nil, !model.generationStatus.isEmpty {
            Text(model.generationStatus).appFont(.callout).textSelection(.enabled)
        }
    }

    private func batchDescription(_ batch: BatchRequest) -> String {
        let narration = batch.settings.model == .kokoro ? "Kokoro · \(VoicePresentation.name(batch.settings.voice)) · \(String(format: "%.2f", batch.settings.speed))×" : "Soprano"
        return "\(narration) · \(batch.outputFormat.rawValue.uppercased())"
    }
}

