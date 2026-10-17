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

enum SettingsTab: String, SettingsPane {
    case general = "General", models = "Models", pronunciation = "Pronunciation", troubleshooting = "Troubleshooting"
    var id: Self { self }
    var title: String { rawValue }
    var systemImage: String {
        switch self { case .general: "gearshape"; case .models: "shippingbox"; case .pronunciation: "text.word.spacing"; case .troubleshooting: "stethoscope" }
    }
    var help: String {
        switch self { case .general: "Appearance, narration and completion alerts"; case .models: "Speech models, storage and setup"; case .pronunciation: "Shared word pronunciations and live voice previews"; case .troubleshooting: "Debug logs and helper diagnostics" }
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
                NarrationOptionsControls(options: $model.narrationOptions)
            } header: {
                SettingsSectionHeader(title: "Document Narration", explanation: "Controls explicitly marked notes and auxiliary sections in future batches. Unclassified prose and bibliographies are retained. Preview shows the resulting narration.")
            }
            ImageDescriptionSettingsSection(enabled: $model.describeImages,
                additionalHelp: "Applies to the next batch. The current batch keeps its settings.")
                .disabled(model.isGenerating || model.isPreparingModel)
            Section {
                Text(model.notificationStatus ?? "Notification permission is requested when you first generate audio.")
                    .appFont(.secondary)
            } header: {
                SettingsSectionHeader(title: "Completion alerts", explanation: "Libro requests macOS notification permission when you first generate audio. One private summary follows each completed batch; cancelled batches do not send a success alert.")
            }
        }.formStyle(.grouped)
    }

    private var models: some View {
        Form {
            Section {
                DirectoryRow(model: model, label: "Libro workspace", selection: model.workspace, role: .workspace)
            } header: {
                SettingsSectionHeader(title: "Model storage", explanation: "Models, pronunciation assets, staging and local caches stay in this workspace, outside the app bundle. Existing compatible model files are reused read-only.")
            }
            Section {
                Picker(model.isGenerating ? "Next batch model" : "Model", selection: $model.settings.model) {
                    Text("Kokoro").tag(SpeechModel.kokoro)
                    Text("Soprano").tag(SpeechModel.soprano)
                }.disabled(model.isPreparingModel)
                Text(model.readiness).appFont(.secondary).textSelection(.enabled)
                SpeechSetupControls(activity: model.isPreparingModel ? (model.preparationIsCheck ? .checking : .installing) : nil,
                    status: model.speechSetupStatus, canManage: model.canManageSpeechSetup,
                    canCheck: model.workspace?.url != nil, disabledReason: model.speechSetupDisabledReason,
                    installMessage: "Download or verify the selected \(model.settings.model.rawValue.capitalized) model and its pronunciation assets in the Libro workspace? Generation uses local assets.",
                    install: model.installSpeechRuntime, check: model.checkSpeechSetup, cancel: model.cancel)
                if model.isPreparingModel || !model.preparationStatus.isEmpty { PreparationProgressView(model: model) }
                DisclosureGroup("Model details") {
                    let specification = NativePrimaryCatalog.specification(for: model.settings.model)
                    LabeledContent("Repository") { Text(specification.repository).textSelection(.enabled) }
                    LabeledContent("Pinned revision") { Text(specification.revision).textSelection(.enabled) }
                    Text("Native metadata and assets: models/.native/ in the selected workspace.")
                        .appFont(.caption).foregroundStyle(.secondary)
                }
            } header: { SettingsSectionHeader(title: "Speech setup", explanation: NarrationSettingsHelp.speechSetup) }
        }.formStyle(.grouped)
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
                SettingsSectionHeader(title: "Debug logging", explanation: "Records local worker diagnostics. Library messages may include document text or paths. Nothing is uploaded. Up to two 1 MB log files are retained in the selected Libro workspace. Enable before generating or setting up a model. Copy uses the current log; Clear removes both retained logs while processing is idle.")
            }
            Section {
                HStack {
                    Button("Check Embedded Helper") { model.probe() }
                        .disabled(model.busy || model.debugToolsBusy || model.hasOwnedProbe || model.isGenerating || model.isPreparingModel)
                    if model.hasOwnedProbe { ProgressView().controlSize(.small); Button("Cancel Check") { model.cancelIntake() } }
                }
                if !model.probeStatus.isEmpty { Text(model.probeStatus).textSelection(.enabled) }
            } header: {
                SettingsSectionHeader(title: "Diagnostics", explanation: "Checks that the bundled helper and Metal runtime can start. This does not load a speech model. Use Check Speech Setup in Models to check the selected model offline.")
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

