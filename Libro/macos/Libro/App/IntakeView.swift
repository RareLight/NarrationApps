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
    @State private var showingDetails = false
    @State private var showingIssueNotice = false
    @State private var issueNoticeMessages: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let batch = model.activeBatch {
                    HStack {
                        Text(batchDescription(batch)).appFont(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Next Batch Settings…") { showingNextBatchSettings = true }
                    }
                } else { NarrationControls(model: model) }
            }.padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if model.displayedDocuments.isEmpty {
                ContentUnavailableView {
                    Label("Add documents", systemImage: "doc.badge.plus")
                } description: {
                    Text("Drop documents or folders, or use Add Documents.")
                } actions: {
                    Button("Add Documents…") { model.openInputs() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { DocumentQueueView(model: model).padding(.top, 8) }
            Divider()
            HStack(alignment: .center, spacing: 24) {
                coverControls
                Spacer(minLength: 12)
                transportControls
            }.padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            statusBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 8).stroke(.tint, lineWidth: 3).padding(4).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { model.importDrop($0) }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Add Documents…", systemImage: "doc.badge.plus") { model.openInputs() }
                    .help("Add documents to the queue")
                Menu("Queue Actions", systemImage: "ellipsis") {
                    Button("Add Folder…", systemImage: "folder.badge.plus") { model.openInputs(foldersOnly: true) }
                    Button("Queue Unfinished") { model.retryUnfinished() }
                        .disabled(!model.outcomes.values.contains { $0.state == .failed || $0.state == .cancelled || $0.state == .skipped })
                    Divider()
                    Button("Remove Selected", systemImage: "minus") { model.removeSelected() }.disabled(model.selection.isEmpty || model.busy || model.isGenerating)
                    Button("Clear Finished") { model.clearFinished() }.disabled(!model.hasFinished || model.busy || model.isGenerating)
                    Button("Clear Queue") { model.clear() }.disabled(!model.canClearQueue)
                    Divider()
                    Button("Queue Details…", systemImage: "info.circle") { showingIssueNotice = false; showingDetails = true }
                }
                .popover(isPresented: $showingIssueNotice, arrowEdge: .top) { issueNotice }
                .onChange(of: issueMessages) { previous, current in
                    let added = current.filter { !previous.contains($0) }
                    if current.isEmpty { showingIssueNotice = false }
                    else if !added.isEmpty {
                        issueNoticeMessages = added
                        showingIssueNotice = true
                    }
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
                    }.help("Queue this document; use Start to process the next batch")
                    Spacer()
                    Button("Done") { model.failureDetails = nil }.keyboardShortcut(.defaultAction)
                }
            }.padding().frame(width: 560).onExitCommand { model.failureDetails = nil }
        }
        .sheet(isPresented: Binding(get: { model.preview != nil }, set: { if !$0 { model.dismissPreview() } })) {
            LibroDocumentPreview(model: model)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 16) {
            transportButton(model.isGenerating ? (model.pauseRequested ? "Resume" : "Pause") : "Start",
                symbol: model.isGenerating && !model.pauseRequested ? "pause.fill" : "play.fill",
                color: .green, disabled: model.isStopping || (!model.isGenerating && !model.canGenerate),
                help: model.isGenerating ? "Pause or resume at the next safe operation boundary"
                    : (model.generationBlocker?.message ?? "Process queued documents")) {
                if model.isGenerating { model.togglePause() } else { model.generate() }
            }
            transportButton("Skip", symbol: "forward.end.fill", color: .blue,
                disabled: model.queueState?.canSkip != true || model.isStopping,
                help: "Confirm and skip the current item; unfinished audio is discarded") { model.confirmSkip() }
            transportButton("Stop", symbol: "stop.fill", color: .red,
                disabled: !model.isGenerating || model.isStopping,
                help: "Stop the queue; saved audio is kept") { model.confirmStop() }
        }.fixedSize()
    }

    private func transportButton(_ title: String, symbol: String, color: Color, disabled: Bool, help: String,
                                 action: @escaping () -> Void) -> some View {
        VStack(spacing: 3) {
            Button(action: action) {
                Image(systemName: symbol).appFont(.title2).frame(minWidth: 24, minHeight: 24)
                    .foregroundStyle(disabled ? Color.secondary : color)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
            .disabled(disabled).accessibilityLabel(title).help(help)
            Text(title).appFont(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }

    private var outputControls: some View {
        let url = model.activeBatch?.outputDirectory ?? model.output?.url
        return HStack(spacing: 8) {
            Text("Save Location:").fixedSize()
            Text(url?.path ?? "Choose a folder…")
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .frame(maxWidth: 280, alignment: .leading).help(url?.path ?? "No folder selected")
            Button("Browse…") { model.browse(.output) }
                .controlSize(.small).fixedSize()
                .disabled(model.busy || model.isGenerating)
                .help(model.isGenerating ? "Change the next destination in Next Batch Settings" : "Choose the output folder")
        }.frame(maxWidth: 440, alignment: .trailing).layoutPriority(1)
    }

    @ViewBuilder private var coverControls: some View {
        if !model.selection.isEmpty {
            if model.outputFormat.supportsCoverArtwork {
                CoverArtworkPicker(title: model.selection.count > 1 ? "Selected Covers" : "Cover Art",
                    url: model.selectedCoverURL, selected: model.selectionHasCover,
                    choose: model.chooseCover, remove: model.removeCover,
                    failure: { model.planningError = $0 })
                    .disabled(model.busy || model.isGenerating)
            } else {
                Text("WAV keeps cover choices for later exports").appFont(.caption).foregroundStyle(.secondary)
            }
        } else {
            Label("Select an item to edit its cover", systemImage: "photo")
                .appFont(.caption).foregroundStyle(.secondary)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Button { if !model.assetsReady || model.workspace?.url == nil || model.setupVerificationFailed { model.settingsTab = .models; openSettings() } else { showingDetails = true } } label: {
                Label(appStatus, systemImage: appStatusSymbol).lineLimit(1)
            }.buttonStyle(.plain).help(model.speechSetupDisabledReason ?? "\(model.readiness) · Click for queue details")
            Divider().frame(height: 16)
            Text(queueCounts).monospacedDigit().lineLimit(1).help("Queue totals; completed files are retained")
            Divider().frame(height: 16)
            HStack(spacing: 8) {
                if hasIssues {
                    Button("Review issues", systemImage: "exclamationmark.circle") { showingDetails = true }
                        .buttonStyle(.plain).lineLimit(1).help("Show import, destination and queue diagnostics")
                } else {
                    Text(activityLabel).lineLimit(1).truncationMode(.middle)
                        .help(model.isGenerating ? model.generationStatus : model.status)
                }
                if model.isGenerating && model.queueState?.phase != .paused {
                    if let fraction = activityFraction { ProgressView(value: fraction).frame(width: 100) }
                    else { ProgressView().controlSize(.small) }
                } else if model.isPreparingModel, let progress = model.preparationProgress, progress.totalBytes > 0 {
                    ProgressView(value: Double(progress.completedBytes) / Double(progress.totalBytes)).frame(width: 100)
                } else if model.busy || model.isPreparingModel || model.planning { ProgressView().controlSize(.small) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if model.busy || model.isPreparingModel {
                Button("Cancel") { model.cancel() }.controlSize(.small)
            }
            Divider().frame(height: 16)
            outputControls
        }
        .appFont(.caption).padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
        .popover(isPresented: $showingDetails, arrowEdge: .top) { details }
    }

    private var appStatus: String {
        if model.isPreparingModel { return model.preparationIsCheck ? "Checking model" : "Installing model" }
        if model.checkingAssets { return "Checking model" }
        if model.workspace?.url == nil { return "Choose workspace" }
        if !model.assetsReady || model.setupVerificationFailed { return "Model setup needed" }
        return "Ready"
    }
    private var appStatusSymbol: String {
        if model.checkingAssets || model.isPreparingModel { return "clock" }
        return model.workspace?.url != nil && model.assetsReady && !model.setupVerificationFailed ? "checkmark.circle" : "exclamationmark.triangle"
    }
    private var queueCounts: String {
        let waiting = model.candidates.count + (model.queueState?.pending.count ?? 0)
        let saved = model.outcomes.values.filter { $0.state == .published }.count
        let failed = model.outcomes.values.filter { $0.state == .failed }.count
        let skipped = Set(model.outcomes.filter { $0.value.state == .skipped }.keys).union(model.skippedExisting).count
        return "\(waiting) queued · \(saved) saved" + (failed > 0 ? " · \(failed) failed" : "") + (skipped > 0 ? " · \(skipped) skipped" : "")
    }
    private var issueMessages: [String] {
        let messages = [model.planningError, model.output?.error, model.workspace?.error, model.dropError,
            model.setupVerificationFailed ? model.preparationStatus : nil]
            .compactMap { $0 } + model.issues.map { "\($0.source.lastPathComponent): \($0.message)" }
            + model.documents.compactMap { document -> String? in
                guard let outcome = model.outcomes[document.id], outcome.state == .failed else { return nil }
                return "\(document.source.lastPathComponent): \(outcome.message ?? "Generation failed.")"
            }
        return messages.filter { !$0.isEmpty }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
    private var hasIssues: Bool { !issueMessages.isEmpty }
    private var issueNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Queue issue", systemImage: "exclamationmark.triangle").appFont(.headline)
            ForEach(Array(issueNoticeMessages.prefix(3).enumerated()), id: \.offset) { _, message in
                Text(message).lineLimit(4).textSelection(.enabled)
            }
            HStack {
                Button("View diagnostics…") { showingIssueNotice = false; showingDetails = true }
                Spacer()
                Button("Dismiss") { showingIssueNotice = false }
            }
        }.appFont(.callout).padding(12).frame(width: 340)
    }
    private var activityLabel: String {
        if model.isStopping { return "Stopping…" }
        if hasIssues { return "Review details" }
        if model.isGenerating {
            switch model.queueState?.phase {
            case .paused: return "Paused"
            case .pausing: return "Pausing…"
            case .skipping: return "Skipping…"
            default: break
            }
            if let progress = model.activityProgress?.preparation?.progress {
                return QueueStatusPresentation.preparation(progress)
            }
            if let speech = model.speechProgress {
                return speech.phase == .publishing ? "Saving audio…" : "Narrating \(speech.completedChunks)/\(speech.totalChunks)"
            }
            return "Starting…"
        }
        if model.isPreparingModel { return model.preparationIsCheck ? "Checking setup…" : "Installing…" }
        if model.busy { return model.hasCoverWork ? "Preparing…" : "Analyzing inputs…" }
        if model.planning { return "Checking destinations…" }
        if let summary = model.batchSummary { return summary.cancelled ? "Stopped" : "Batch complete" }
        return "Drop documents to add · Double-click to preview"
    }
    private var activityFraction: Double? {
        if let progress = model.activityProgress?.preparation?.progress { return progress.fractionCompleted }
        if let progress = model.speechProgress, progress.totalChunks > 0, progress.phase != .publishing {
            return Double(progress.completedChunks) / Double(progress.totalChunks)
        }
        return nil
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Queue Details").appFont(.headline)
            if model.isPreparingModel { PreparationProgressView(model: model) }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(detailMessages.enumerated()), id: \.offset) { _, text in
                        Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxHeight: 250)
            HStack {
                if !model.assetsReady || model.setupVerificationFailed { Button("Model Settings…") { showingDetails = false; model.settingsTab = .models; openSettings() } }
                Spacer()
                Button("Done") { showingDetails = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(16).frame(width: 440)
    }
    private var detailMessages: [String] {
        let values: [String?] = issueMessages.map(Optional.some) + [model.debugLogStatus,
            model.isGenerating ? model.generationStatus : nil,
            model.isPreparingModel ? model.preparationStatus : nil,
            model.busy ? model.activityStatus : nil, model.readiness,
            model.status, model.importSummary, model.notificationSummary, model.notificationStatus,
            model.generationBlocker?.message,
            "Pause finishes the current operation before waiting. Skip discards unfinished audio. Saved files are kept.",
            "Drag rows to reorder waiting items. Current and finished batch items stay fixed; new imports belong to the next batch."]
        return values.compactMap { $0 }.filter { !$0.isEmpty }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
    private func batchDescription(_ batch: BatchRequest) -> String {
        let narration = batch.settings.model == .kokoro ? "Kokoro · \(VoicePresentation.name(batch.settings.voice)) · \(String(format: "%.2f", batch.settings.speed))×" : "Soprano"
        return "\(narration) · \(batch.outputFormat.rawValue.uppercased())"
    }
}
