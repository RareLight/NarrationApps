import SwiftUI
import AppPresentation
import PronunciationUI
import NarrationUI
import ProcessingPipeline
import AppKit
import UniformTypeIdentifiers
import LibroCore
import NarrationCore
import NativeSpeech
import Darwin
import AVFoundation
import AudioOutput
import OSLog
@preconcurrency import UserNotifications

enum SettingsTab: String, SettingsPane {
    case general = "General", document = "Document", models = "Models", pronunciation = "Pronunciation", troubleshooting = "Troubleshooting"
    var id: Self { self }
    var title: String { rawValue }
    var systemImage: String {
        switch self { case .general: "gearshape"; case .document: "doc.text"; case .models: "shippingbox"; case .pronunciation: "text.word.spacing"; case .troubleshooting: "stethoscope" }
    }
    var help: String {
        switch self { case .general: "Appearance and completion alerts"; case .document: "Choose what text is read and how printed words are joined"; case .models: "Speech models, storage and setup"; case .pronunciation: "Shared word pronunciations and live voice previews"; case .troubleshooting: "Debug logs and helper diagnostics" }
    }
}

struct DirectoryRow: View {
    let model: IntakeModel
    let label: String
    let selection: DirectorySelection?
    let role: DirectoryRole

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).appFont(.caption).foregroundStyle(.secondary)
                Text(selection?.displayPath ?? "Choose a folder…")
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    .help(selection?.displayPath ?? "No folder selected")
                if let error = selection?.error {
                    Label(error, systemImage: "exclamationmark.triangle").appFont(.callout).foregroundStyle(.red)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let url = selection?.url {
                Button("Reveal \(role.rawValue) folder in Finder", systemImage: "folder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path) }
                    .labelStyle(.iconOnly).help("Reveal \(label.lowercased()) in Finder")
            }
            Button("Browse…") { model.browse(role) }
                .disabled(model.busy || (role == .workspace && (model.isPreparingModel || model.debugToolsBusy)))
                .help("Browse for \(role.rawValue) folder")
        }
    }
}

struct PreparationProgressView: View {
    let model: IntakeModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.preparationStatus.isEmpty { Text(model.preparationStatus).textSelection(.enabled) }
            if let value = model.preparationProgress {
                ProgressView(value: Double(value.completedBytes), total: Double(max(1, value.totalBytes))) {
                    Text("\(ByteCountFormatter.string(fromByteCount: value.completedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: value.totalBytes, countStyle: .file))")
                }
            } else if model.isPreparingModel { ProgressView(model.preparationIsCheck ? "Checking speech setup…" : "Installing speech model…").controlSize(.small) }
        }
    }
}

struct LibroSettingsView: View {
    @Bindable var model: IntakeModel
    @Binding var textSize: AppTextSize

    var body: some View {
        VStack(spacing: 0) {
            SettingsNavigation(selection: $model.settingsTab).padding(12)
            Divider()
            Group {
                switch model.settingsTab {
                case .general: general
                case .document: document
                case .models: models
                case .pronunciation:
                    PronunciationSettingsView(preview: model.pronunciationPreview, configuration: model.pronunciationConfiguration,
                        unavailableReason: model.pronunciationUnavailableReason, beforePreview: { model.stopPlayback() })
                case .troubleshooting: troubleshooting
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(minWidth: 560, idealWidth: 640, minHeight: 540, idealHeight: 620)
            .task { await model.refreshNotificationStatus() }
    }

    private var general: some View {
        Form {
            AppearanceSettingsSection(textSize: $textSize)
            Section {
                Text(model.notificationStatus ?? "Notification permission is requested when you first generate audio.")
                    .appFont(.secondary)
            } header: {
                SettingsSectionHeader(title: "Completion alerts", explanation: "Send one private notification after each completed batch.")
            }
        }.formStyle(.grouped)
    }

    private var document: some View {
        Form {
            Section {
                Text("These choices affect new previews and future batches. Original documents and finished recordings stay unchanged.")
                    .appFont(.secondary).foregroundStyle(.secondary)
                NarrationOptionsControls(options: $model.narrationOptions, showsExamples: true)
            } header: {
                SettingsSectionHeader(title: "Text to read", explanation: "Choose which marked sections are spoken and how split PDF words are joined. Preview a document to check its narration.")
            }
            ImageDescriptionSettingsSection(enabled: $model.describeImages,
                additionalHelp: "Applies to the next batch. The current batch keeps its settings.", showsExample: true)
                .disabled(model.isGenerating || model.isPreparingModel)
        }.formStyle(.grouped)
    }

    private var models: some View {
        VStack(spacing: 0) {
            SpeechModelSettingsHeader(status: model.speechSetupStatus,
                validating: model.speechSetupValidating, canRepair: model.canManageSpeechSetup,
                repair: model.installSpeechRuntime,
                explanation: "Manage the selected voice model and its local storage.")
                .padding(.horizontal, 16).padding(.top, 12)
            SpeechSetupRequiredHeader(model: model.settings.model,
                isPresented: model.speechSetupHeaderPresented,
                activity: model.isPreparingModel ? .installing : nil,
                progress: model.isPreparingModel && !model.preparationIsCheck ? model.preparationProgress : nil,
                canDownload: model.canManageSpeechSetup,
                detail: model.speechSetupFailureDetail,
                download: model.installSpeechRuntime, cancel: model.cancel)
            Form {
                Section {
                    ModelStorageSettings(root: model.workspace?.url ?? NativeModelStorage.defaultRoot,
                        canManage: model.canManageSpeechSetup, revision: model.modelStorageRevision,
                        choose: { model.browse(.workspace) }, useDefault: model.useDefaultModelStorage,
                        changed: { model.modelStorageRevision += 1 }, maintenance: model.modelStorage)
                } header: { SettingsSectionHeader(title: "Downloaded models", explanation: "Manage cached models and choose a storage location.") }
            }.formStyle(.grouped)
        }
    }

    private var troubleshooting: some View {
        Form {
            Section {
                Toggle("Enable debug logging", isOn: $model.debugLogging)
                    .disabled(model.isGenerating || model.isPreparingModel)
                if let url = model.debugLogURL {
                    Text(url.path).appFont(.caption).textSelection(.enabled)
                    ViewThatFits(in: .horizontal) {
                        HStack { logActions(url) }
                        VStack(alignment: .leading) { logActions(url) }
                    }
                }
                if let message = model.debugLogStatus { Text(message).appFont(.secondary).textSelection(.enabled) }
            } header: {
                SettingsSectionHeader(title: "Debug logging", explanation: "Keep local diagnostics, which may contain private text and paths. Nothing is uploaded. Copy or clear logs while idle.")
            }
            Section {
                HStack {
                    Button("Check Embedded Helper") { model.probe() }
                        .disabled(model.busy || model.debugToolsBusy || model.hasOwnedProbe || model.isGenerating || model.isPreparingModel)
                    if model.hasOwnedProbe { ProgressView().controlSize(.small); Button("Cancel Check") { model.cancelIntake() } }
                }
                if !model.probeStatus.isEmpty { Text(model.probeStatus).textSelection(.enabled) }
            } header: {
                SettingsSectionHeader(title: "Diagnostics", explanation: "Check the bundled speech engine. Model setup is validated automatically.")
            }
        }.formStyle(.grouped)
    }

    @ViewBuilder private func logActions(_ url: URL) -> some View {
        Button("Copy Debug Log") { model.copyDebugLog() }.disabled(!model.canManageDebugLog)
        Button("Clear Log") { model.clearDebugLog() }.disabled(!model.canManageDebugLog)
        Button("Open Debug Log") { NSWorkspace.shared.open(url) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}

