import SwiftUI
import AppPresentation
import NarrationCore
import NativeSpeech
import UniformTypeIdentifiers

/// The same metadata and controls in both apps; no model or network work in body.
public struct SpeechModelControls: View {
    @Binding private var settings: SpeechSettings
    private let models: [SpeechModel]
    private let storageRoot: URL?
    private let storageRevision: Int
    @Bindable private var maintenance: ModelStorageMaintenance
    @State private var localStorage = SelectedModelStorage()
    @State private var showingDetails = false
    @Environment(\.appTextSize) private var textSize
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.scenePhase) private var scenePhase
    @State private var activationRevision = 0
    private let downloading: Bool
    private let canDownload: Bool
    private let controlsEnabled: Bool
    private let download: () -> Void
    private let samplePlaying: Bool
    private let canPlaySample: Bool
    private let playSample: () -> Void
    private let loadReferenceProfiles: @Sendable () async throws -> [ReferenceVoice]
    @State private var profiles: [ReferenceVoice] = []
    @State private var profilesLoaded = false
    @State private var importing = false
    @State private var importError: String?
    @State private var importTask: Task<Void, Never>?

    public init(settings: Binding<SpeechSettings>, models: [SpeechModel] = SpeechModel.allCases,
                storageRoot: URL?, storageRevision: Int = 0, maintenance: ModelStorageMaintenance,
                downloading: Bool = false, canDownload: Bool = true, controlsEnabled: Bool = true, download: @escaping () -> Void = {},
                samplePlaying: Bool = false, canPlaySample: Bool = true, playSample: @escaping () -> Void = {},
                loadReferenceProfiles: @escaping @Sendable () async throws -> [ReferenceVoice] = {
                    try await Task.detached { try ReferenceVoiceStore().profiles() }.value
                }) {
        _settings = settings; self.models = models
        self.storageRoot = storageRoot; self.storageRevision = storageRevision
        self.maintenance = maintenance
        self.downloading = downloading; self.canDownload = canDownload; self.controlsEnabled = controlsEnabled; self.download = download
        self.loadReferenceProfiles = loadReferenceProfiles
        self.samplePlaying = samplePlaying; self.canPlaySample = canPlaySample; self.playSample = playSample
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            Grid(alignment: .leading, horizontalSpacing: columnSpacing, verticalSpacing: rowSpacing) {
                GridRow {
                    controlLabel("Model")
                    Picker("Model", selection: Binding(get: { settings.model }, set: { settings = settings.switching(to: $0) })) {
                        ForEach(models, id: \.self) { Text(ModelGuidance.selectionLabel(for: $0)).tag($0) }
                    }.labelsHidden().frame(width: fieldWidth, alignment: .leading)
                    HStack(spacing: columnSpacing) {
                        storageAction
                        modelDetails
                    }
                }
                GridRow {
                    controlLabel("Voice")
                    voicePicker.labelsHidden().frame(width: fieldWidth, alignment: .leading)
                    metadataPlaceholder
                        .accessibilityHidden(true)
                }
            }.disabled(!controlsEnabled)
            parameterAndSampleRows($settings)
            if settings.model == .chatterbox {
                let unavailable = settings.voice != "default" && !profiles.contains { $0.id == settings.voice }
                if profilesLoaded && unavailable {
                    Text("Reimport the original WAV to restore this voice. Choosing another voice applies to future narration.")
                        .appFont(.caption).foregroundStyle(.secondary)
                }
                if let importError { Text(importError).foregroundStyle(.red).appFont(.caption) }
            }
            if let error = localStorage.selection == selectedStorage ? localStorage.error : nil {
                Text(error).foregroundStyle(.red).appFont(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(width: controlWidth, alignment: .topLeading)
        .task(id: refreshKey) {
            if !downloading, let selectedStorage { await localStorage.load(selectedStorage) }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { activationRevision += 1 } }
        .onChange(of: selectedStorage) { _, _ in showingDetails = false }
        .task(id: settings.model) {
            profilesLoaded = false
            if settings.model == .chatterbox {
                profiles = (try? await loadReferenceProfiles()) ?? []
                profilesLoaded = true
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.wav]) { result in
            guard case .success(let url) = result else { return }
            importError = nil
            importTask = Task {
                let work = Task.detached { try ReferenceVoiceStore().importRecording(url) }
                defer { importTask = nil }
                do {
                    let profile = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                    try Task.checkCancellation()
                    profiles = try ReferenceVoiceStore().profiles()
                    if settings.model == .chatterbox { settings.voice = profile.id }
                } catch is CancellationError {} catch { importError = error.localizedDescription }
            }
        }
        .onDisappear { importTask?.cancel() }
    }
    private var scale: CGFloat { max(1, AppTypography.scale(size: textSize, dynamic: dynamicType)) }
    private var fieldWidth: CGFloat { 180 * scale }
    private var controlWidth: CGFloat { 296 * scale }
    private var rowSpacing: CGFloat { 6 * scale }
    private var columnSpacing: CGFloat { 4 * scale }
    private func controlLabel(_ title: String) -> some View {
        Text(title).frame(width: 60 * scale, alignment: .leading).frame(minHeight: 28 * scale)
    }
    @ViewBuilder private var voicePicker: some View {
        if settings.model == .chatterbox {
            let unavailable = settings.voice != "default" && !profiles.contains { $0.id == settings.voice }
            Picker("Reference voice", selection: $settings.voice) {
                Text("Bundled default").tag("default")
                if unavailable { Text(profilesLoaded ? "Unavailable reference" : "Saved reference").tag(settings.voice) }
                ForEach(profiles) { Text($0.name).tag($0.id) }
            }
        } else {
            Picker("Voice", selection: Binding(get: { settings.model == .soprano ? "soprano" : settings.voice }, set: { settings.voice = $0 })) {
                ForEach(settings.model == .kokoro ? VoiceCatalogPresentation.ranked(NativePrimaryCatalog.specification(for: .kokoro).voices) : settings.model.presetVoices, id: \.self) { voice in
                    Text(settings.model == .kokoro ? (voice.hasPrefix("b") ? "UK · " : "US · ") + VoiceCatalogPresentation.displayName(voice) : voice.replacingOccurrences(of: "_", with: " ").capitalized).tag(voice)
                }
            }
        }
    }
    @ViewBuilder private func parameterAndSampleRows(_ selection: Binding<SpeechSettings>) -> some View {
        let selected = selection.wrappedValue
        Grid(alignment: .leading, horizontalSpacing: columnSpacing, verticalSpacing: rowSpacing) {
            if selected.model == .chatterbox {
                GridRow {
                    Button("Import reference voice…") { importing = true }
                        .disabled(!controlsEnabled || importTask != nil)
                        .frame(maxWidth: .infinity, minHeight: 28 * scale, alignment: .leading)
                        .gridCellColumns(3)
                }
            }
            if selected.model == .qwen3 {
                if let nativeLanguage = selected.model.nativeLanguage(for: selected.voice) {
                    GridRow {
                        controlLabel("Native").appFont(.caption).foregroundStyle(.secondary).help("Voice’s native language")
                        Text(nativeLanguage).appFont(.caption).foregroundStyle(.secondary)
                            .frame(width: fieldWidth, alignment: .leading)
                            .accessibilityLabel("Native language: " + nativeLanguage)
                        metadataPlaceholder
                    }
                }
                GridRow {
                    controlLabel("Language")
                    Picker("Narration language", selection: Binding(get: { selection.wrappedValue.effectiveLanguage }, set: { selection.wrappedValue.language = $0 })) {
                        ForEach(selected.model.languages, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(width: fieldWidth, alignment: .leading).disabled(!controlsEnabled)
                    metadataPlaceholder
                }
                GridRow {
                    controlLabel("Delivery")
                    TextField("Optional instruction", text: Binding(get: { selection.wrappedValue.styleInstruction ?? "" }, set: { selection.wrappedValue.styleInstruction = $0.isEmpty ? nil : String($0.prefix(128)) }))
                        .accessibilityLabel("Delivery instruction").disabled(!controlsEnabled)
                        .gridCellColumns(2)
                }
            }
            if selected.model == .kokoro {
                GridRow {
                    controlLabel("Speed")
                    SpeechSpeedControl(speed: Binding(get: { Double(selection.wrappedValue.speed) }, set: { selection.wrappedValue.speed = Float($0) }), showsLabel: false)
                        .frame(width: fieldWidth, alignment: .leading).disabled(!controlsEnabled)
                    metadataPlaceholder
                }
            }
            GridRow {
                VoiceSampleButton(playing: samplePlaying, action: playSample)
                    .disabled(!canPlaySample)
                    .frame(maxWidth: .infinity, minHeight: 28 * scale, alignment: .leading)
                    .gridCellColumns(3)
            }
        }.frame(width: controlWidth, alignment: .topLeading)
    }
    private var metadataPlaceholder: some View {
        Color.clear.frame(width: 48 * scale, height: 1).gridCellUnsizedAxes(.vertical)
            .accessibilityHidden(true)
    }
    private var modelDetails: some View {
        Button { showingDetails.toggle() } label: { Image(systemName: "info.circle") }
            .buttonStyle(.plain).frame(width: 22 * scale, height: 28 * scale).help("Model details")
            .accessibilityLabel("About " + settings.model.label)
            .popover(isPresented: $showingDetails) {
                let guide = ModelGuidance.guide(for: settings.model, language: settings.effectiveLanguage)
                VStack(alignment: .leading, spacing: 12) {
                    Text(settings.model.label).appFont(.headline)
                    Text(modelDescription).fixedSize(horizontal: false, vertical: true)
                    meter("Generation speed", value: guide.speed, label: ModelGuidance.speedLabel(guide.speed))
                    let quality = settings.voice.hasPrefix("reference:") ? nil : guide.quality
                    meter("Narration quality", value: quality, label: ModelGuidance.qualityLabel(quality))
                    if let currentEntry, !currentEntry.imported {
                        Button("Download missing files") {
                            guard canDownload, !downloading, !maintenance.isBusy else { return }
                            showingDetails = false
                            download()
                        }.disabled(!canDownload || downloading || maintenance.isBusy)
                            .help("Complete or repair this model’s download")
                    }
                }.appFont(.secondary).padding(16).frame(width: 380)
            }
    }
    private var selectedStorage: SelectedModelStorage.Selection? {
        storageRoot.map { .init(root: $0, model: settings.model) }
    }
    private struct RefreshKey: Equatable {
        let selection: SelectedModelStorage.Selection?
        let revision: Int
        let maintenanceRevision: Int
        let downloading: Bool
        let activationRevision: Int
    }
    private var refreshKey: RefreshKey {
        .init(selection: selectedStorage, revision: storageRevision, maintenanceRevision: maintenance.revision, downloading: downloading, activationRevision: activationRevision)
    }
    private var currentEntry: StoredSpeechModel? {
        localStorage.selection == selectedStorage ? localStorage.entry : nil
    }
    @ViewBuilder private var storageAction: some View {
        let action = localStorage.action(for: selectedStorage)
        if downloading || action == .checking {
            ProgressView().controlSize(.small).frame(width: 22 * scale, height: 28 * scale)
                .accessibilityLabel(downloading ? "Downloading model" : "Checking model storage")
        } else if action == .download || action == .unavailable {
            Button {
                guard canDownload, !maintenance.isBusy, !downloading else { return }
                download()
            } label: {
                Image(systemName: "arrow.down.circle")
            }.buttonStyle(.plain).frame(width: 22 * scale, height: 28 * scale)
                .disabled(!canDownload || maintenance.isBusy || action == .unavailable)
                .accessibilityLabel("Download " + settings.model.label)
                .help(action == .unavailable ? "Model storage unavailable" : "Download model")
        }
    }
    private var modelDescription: String {
        let summary = ModelGuidance.guide(for: settings.model, language: settings.effectiveLanguage).summary
        return summary + (settings.model.isLarge ? " Requires at least \(settings.model == .orpheus ? 24 : 16) GB RAM." : "")
    }
    private func meter(_ title: String, value: Int?, label: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { Text(title).frame(width: 110, alignment: .leading); bars(value); Text(label).frame(width: 65, alignment: .leading) }
            VStack(alignment: .leading) { HStack { Text(title); Spacer(); Text(label) }; bars(value) }
        }.appFont(.caption)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title).accessibilityValue(value.map { "\(label), \($0) of five" } ?? "Not rated")
    }
    private func bars(_ value: Int?) -> some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { index in
                Capsule().fill(index <= (value ?? 0) ? Color.accentColor : Color.secondary.opacity(0.25)).frame(height: 5)
            }
        }.frame(minWidth: 90, maxWidth: 210).accessibilityHidden(true)
    }
}
