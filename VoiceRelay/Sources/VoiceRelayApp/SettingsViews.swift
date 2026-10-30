import AppPresentation
import PronunciationUI
import NarrationUI
import NarrationCore
import NativeSpeech
import SwiftUI
import AppKit
import Observation
import VoiceRelayCore

struct ConfigurationView: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            AppearanceSettingsSection(textSize: $model.textSize)
            Section {
                StartupControls(model: model)
            } header: {
                SectionHelpHeader(title: "Startup", explanation: "Start in the menu bar after login. On for new configurations.")
            }
            Section {
                NarrationOptionsControls(options: $model.preferences.effectiveNarrationOptions)
            } header: {
                SectionHelpHeader(title: "Document Narration", explanation: "Choose what to read in newly queued articles. Existing jobs keep their settings.")
            }.disabled(model.preview || model.stopping)
            ImageDescriptionSettingsSection(enabled: $model.describeArticleImages,
                additionalHelp: "Applies to newly added articles. Existing queued articles keep their prepared text. Web images may be fetched from public sites to create descriptions.")
                .disabled(model.preview || model.stopping)
            Section {
                Toggle("Publish timed transcripts", isOn: $model.preferences.timedTranscriptsEnabled)
            } header: {
                SectionHelpHeader(title: "Episode transcripts", explanation: "Publish timed narration text for compatible podcast apps. On for new articles; existing jobs stay unchanged.")
            }.disabled(model.preview || model.stopping)
            Section {
                Toggle("Generate missing titles using Apple Intelligence", isOn: $model.generateMissingTitles)
            } header: {
                SectionHelpHeader(title: "Article titles", explanation: "Use on-device Apple Intelligence when no useful headline is found. New articles only; generated titles may be inaccurate.")
            }.disabled(model.preview || model.stopping)
            Section {
                LabeledContent("Source", value: model.sourceReview.plist?.lastPathComponent ?? "Not chosen")
                    .help(model.sourceReview.plist?.path ?? "No Reading List source chosen")
                LabeledContent("Last checked", value: model.sourceReview.lastSyncedAt?.formatted(date: .omitted, time: .standard) ?? "Not checked this session")
                if let error = model.sourceReview.error, model.notices.isVisible(message: error, key: "source") {
                    InlineNotice(message: error) { model.notices.dismiss(message: error, key: "source") }
                }
                Button("Choose Reading List…") { model.sourceReview.selectPlist() }
                    .disabled(model.running || model.sourceReview.busy || model.sourceReview.maintenanceSuspended || model.preview)
                Toggle("Add new articles to Queue automatically", isOn: $model.autoAdmitEnabled)
                    .disabled(model.preview || model.stopping)
                Toggle("Process queued articles automatically", isOn: $model.autoProcessEnabled)
                    .disabled(model.preview || model.stopping)
                Toggle("Try archived copies when articles fail", isOn: $model.useArchivedArticles)
                    .disabled(model.preview || model.stopping)
            } header: {
                SectionHelpHeader(title: "Reading List",
                    explanation: "Checks Safari every five minutes without changing it. Web image descriptions may fetch public images; archive recovery sends eligible URLs to Archive.ph or Wayback.")
            }
        }.formStyle(.grouped)
    }
}

struct VoiceModelSettingsView: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section {
                ScrollView(.horizontal) {
                    SpeechModelControls(settings: $model.preferences.modelSelection,
                        models: SpeechModel.allCases.filter { $0 != .soprano },
                        storageRoot: model.runtimeProject, storageRevision: model.modelStorageRevision,
                        maintenance: model.modelStorage,
                        downloading: model.runtimeBusy && model.runtimeInstalling,
                        canDownload: model.canManageSpeechRuntime,
                        controlsEnabled: !model.running && !model.runtimeBusy && !model.modelStorage.isBusy,
                        download: model.installSpeechRuntime,
                        samplePlaying: model.voiceSamplePlayer.playingID != nil || model.pronunciationPreview.hasOwnedWork,
                        canPlaySample: model.canPlayVoiceSample, playSample: model.playVoiceSample)
                }.fixedSize(horizontal: false, vertical: true)
                if let error = model.voiceSamplePlayer.error ?? model.pronunciationPreview.error {
                    InlineNotice(message: error)
                }
            } header: {
                SectionHelpHeader(title: "Voice Model", explanation: "Choose the voice for newly queued articles. Existing jobs keep their settings.")
            }
            Section {
                ModelStorageSettings(root: model.runtimeProject, canManage: model.canManageSpeechRuntime,
                    revision: model.modelStorageRevision, choose: model.chooseModelStorage,
                    useDefault: model.useDefaultModelStorage,
                    changed: { model.runtimeVerificationFailed = false; model.runtimeTestResult = .untested; model.maybeAutoProcess() },
                    maintenance: model.modelStorage)
            } header: { SectionHelpHeader(title: "Downloaded models", explanation: "Manage cached models and choose a storage location.") }
            speechSetup
        }.formStyle(.grouped)
    }
    private var speechSetup: some View {
        Section {
            SpeechRuntimeTestIndicator(model: model)
            if model.runtimeBusy {
                ProgressView().controlSize(.small)
                Button("Cancel", action: model.cancelRuntimeSetup)
            } else {
                Button("Check Speech Setup", action: model.checkSpeechRuntime).disabled(!model.canManageSpeechRuntime)
            }
        } header: { SectionHelpHeader(title: "Speech setup", explanation: NarrationSettingsHelp.speechSetup) }
    }
}

/// Launch-only setup uses the same cancellable installation as Voice Model settings.
struct SpeechRuntimeOnboardingView: View {
    @Bindable var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        SpeechSetupOnboardingView(status: model.speechSetupStatus,
            activity: model.runtimeBusy ? (model.runtimeInstalling ? .installing : .checking) : nil,
            canInstall: model.canManageSpeechRuntime, install: model.installSpeechRuntime,
            check: model.checkSpeechRuntime, chooseFolder: model.chooseModelStorage,
            cancel: model.cancelRuntimeSetup, notNow: { dismissWindow() })
    }
}

struct StartupControls: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Start VoiceRelay at login", isOn: Binding(
                get: { model.launchAtLoginEnabled }, set: { model.setLaunchAtLogin($0) }))
                .disabled(!model.canChangeLoginItem)
            if model.loginItemBusy { ProgressView().controlSize(.small).accessibilityLabel("Updating startup setting") }
            if model.loginItemStatus == .requiresApproval {
                Text("Allow VoiceRelay in Login Items to finish enabling automatic startup.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Login Items Settings") { model.openLoginItemSettings() }
                    .disabled(!model.canChangeLoginItem)
            }
            if model.loginItemStatus == .notFound {
                Text("VoiceRelay’s login item is unavailable. Use the installed, signed app.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.loginItemError { InlineNotice(message: error) }
        }.onAppear { model.refreshLoginItemStatus() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.refreshLoginItemStatus() }
            }
    }
}

struct SpeechRuntimeTestIndicator: View {
    @Bindable var model: AppModel
    var body: some View {
        if !model.runtimeBusy { SpeechSetupStatusView(status: model.speechSetupStatus) }
    }
}

struct DeliveryPaneView: View {
    @Bindable var model: AppModel
    @State private var feedFolderText: String
    @State private var publicFolderText: String
    @FocusState private var focusedURL: URLField?
    private enum URLField: Hashable { case feed, published }
    init(model: AppModel) {
        self.model = model
        _feedFolderText = State(initialValue: model.deliverySettings.feedFolderURL?.absoluteString ?? "")
        _publicFolderText = State(initialValue: model.deliverySettings.publicFolderURL?.absoluteString ?? "")
    }
    @discardableResult private func commitURLs() -> Bool {
        guard model.updateDeliveryURLs(feedFolder: feedFolderText, publicFolder: publicFolderText) else { return false }
        feedFolderText = model.deliverySettings.feedFolderURL?.absoluteString ?? ""
        publicFolderText = model.deliverySettings.publicFolderURL?.absoluteString ?? ""
        return true
    }
    private var draftSubscriptionURL: URL? {
        (try? DeliveryURL.folder(publicFolderText))?.appendingPathComponent("feed.xml")
    }
    private var usernameBinding: Binding<String> {
        Binding(get: { model.deliverySettings.username ?? "" },
                set: {
                    let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.deliverySettings.username = trimmed.isEmpty ? nil : trimmed
                })
    }
    private var canSavePassword: Bool {
        !model.deliveryPassword.isEmpty && (try? DeliveryURL.folder(feedFolderText))?.host != nil
    }
    var body: some View {
        Form {
            Section {
                Toggle("Publish a private podcast feed", isOn: Binding(
                    get: { model.deliverySettings.enabled },
                    set: { enabled in if !enabled || commitURLs() { model.deliverySettings.enabled = enabled } }))
            } header: {
                SectionHelpHeader(title: "Publishing",
                    explanation: "Uploads finished audio and updates your podcast feed while publishing is enabled and the app runs.")
            }
            Section {
                TextField("Feed folder URL", text: $feedFolderText)
                    .focused($focusedURL, equals: .feed)
                    .onSubmit { commitURLs() }
                    .help("Upload folder for feed.xml and audio/")
                TextField("Username", text: usernameBinding)
                    .help("Your WebDAV login username")
                SecureField("Password", text: $model.deliveryPassword)
                    .help("Click Save Password after editing")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { credentialActions; credentialPresence }
                    VStack(alignment: .leading, spacing: 8) { credentialActions; credentialPresence }
                }

            } header: {
                SectionHelpHeader(title: "Upload destination",
                    explanation: "Feed folder holds feed.xml and audio/. Save the password in Keychain for background publishing. Saving may require authorization; re-save older credentials once.", helpTopic: .publishing)
            }
            Section {
                TextField("Public folder URL", text: $publicFolderText)
                    .focused($focusedURL, equals: .published)
                    .onSubmit { commitURLs() }
                    .help("Public address serving your uploaded files")
                VStack(alignment: .leading, spacing: 8) {
                    Text("Subscription URL").appFont(.headline)
                    Text(draftSubscriptionURL?.absoluteString ?? "Enter a public folder URL")
                        .textSelection(.enabled).appFont(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Copy", systemImage: "doc.on.doc") {
                        if commitURLs() { model.copyDeliverySubscriptionURL() }
                    }.disabled(draftSubscriptionURL == nil || model.preview)
                }
                TextField("Channel title", text: $model.deliverySettings.channelTitle)
                TextField("Channel description", text: $model.deliverySettings.channelDescription)
                CoverArtworkPicker(title: "Podcast Cover", url: model.podcastCoverURL,
                    selected: model.deliverySettings.podcastCoverDigest != nil,
                    choose: model.choosePodcastCover, remove: model.removePodcastCover,
                    failure: { model.podcastCoverError = $0 })
                    .disabled(model.preview || model.coverImporting || model.libraryMaintenanceBusy)
                    .help("Square JPEG or PNG, at least 1400 × 1400, without transparency.")
                if let error = model.podcastCoverError { InlineNotice(message: error) { model.podcastCoverError = nil } }
            } header: {
                SectionHelpHeader(title: "Public feed",
                    explanation: "Public folder must serve the same files as Feed folder. Copy the Subscription URL into your podcast app.", helpTopic: .publishing)
            }
            Section {
                LabeledContent("Pending uploads", value: "\(model.deliveryPendingCount)")
                LabeledContent("Last upload", value: model.deliveryStatus ?? "Not run yet")
                if let error = model.deliveryError, model.notices.isVisible(message: error, key: "delivery") {
                    InlineNotice(message: error) { model.notices.dismiss(message: error, key: "delivery") }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Button(model.deliveryTesting ? "Testing…" : "Test Connection") { if commitURLs() { model.testDeliveryConnection() } }
                        .disabled(model.deliveryTesting || model.preview || model.stopping || model.deliveryCredentialBusy)
                    testIndicator
                }
            } header: {
                SectionHelpHeader(title: "Status",
                    explanation: "Test Connection checks upload folders, not write access or public playback. Uploads shows pending work and verification issues.", helpTopic: .publishing)
            }
        }
        .formStyle(.grouped)
        .disabled(model.stopping)
        .onAppear { model.refreshDeliveryCredentialState() }
        .onChange(of: feedFolderText) { _, value in
            if value != (model.deliverySettings.feedFolderURL?.absoluteString ?? "") { model.cancelDeliveryTest() }
        }
        .onChange(of: publicFolderText) { _, value in
            if value != (model.deliverySettings.publicFolderURL?.absoluteString ?? "") { model.cancelDeliveryTest() }
        }
        .onChange(of: focusedURL) { old, _ in if old != nil { commitURLs() } }
        .onDisappear { commitURLs(); model.cancelDeliveryTest() }
    }
    private var credentialActions: some View {
        HStack(spacing: 8) {
                    Button("Save Password") { if commitURLs() { model.saveDeliveryPassword() } }
                        .disabled(!canSavePassword || model.deliveryCredentialBusy)
                        .help("Save in Keychain")
                    Button("Clear") { if commitURLs() { model.clearDeliveryPassword() } }
                        .disabled((try? DeliveryURL.folder(feedFolderText))?.host == nil || model.preview || model.deliveryCredentialBusy)
        }
    }
    @ViewBuilder private var credentialPresence: some View {
                    if model.deliveryPasswordStored {
                        Label("Stored in Keychain", systemImage: "key.fill").foregroundStyle(.secondary)
                    } else if !model.deliveryPasswordChecked, model.deliverySettings.feedFolderURL?.host != nil {
                        Text(model.deliveryBusy || model.deliveryTesting ? "Checking password…" : "Password not checked").foregroundStyle(.secondary)
                    }
    }
    @ViewBuilder private var testIndicator: some View {
        switch model.deliveryTestResult {
        case .untested:
            if model.deliveryTesting { ProgressView().controlSize(.small) }
            else { Text("Not tested").foregroundStyle(.secondary) }
        case .success:
            Label("Folders verified", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .foldersPending:
            Label("Connected; folders created on upload", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill").foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum SettingsSection: String, SettingsPane {
    case general = "General"
    case voiceModel = "Voice Model"
    case pronunciation = "Pronunciation"
    case delivery = "Publishing"
    case troubleshooting = "Troubleshooting"
    var id: Self { self }
    var title: String { rawValue }
    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .voiceModel: "waveform"
        case .pronunciation: "text.word.spacing"
        case .delivery: "antenna.radiowaves.left.and.right"
        case .troubleshooting: "stethoscope"
        }
    }
    var help: String {
        switch self {
        case .general: "Appearance, narration, Reading List and automation"
        case .voiceModel: "Models, voices, samples and downloads"
        case .pronunciation: "Shared word pronunciations and live voice previews"
        case .delivery: "Podcast connection, publishing and subscription URL"
        case .troubleshooting: "Library backup and logs"
        }
    }
}

struct SettingsView: View {
    static let windowWidth: CGFloat = 540
    static let windowHeight: CGFloat = 680
    static let minWindowWidth: CGFloat = 360
    static let minWindowHeight: CGFloat = 540
    @Bindable var model: AppModel
    private let initialSection: SettingsSection?
    private var section: SettingsSection { model.settingsSection }
    init(model: AppModel, initialSection: SettingsSection? = nil) {
        self.model = model; self.initialSection = initialSection
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                SettingsNavigation(selection: $model.settingsSection).padding(.horizontal, 12)
            }
            .padding(.vertical, 12)
            Divider()
            Group {
                switch section {
                case .general:
                    ConfigurationView(model: model).padding(.horizontal, 8)
                case .voiceModel:
                    VoiceModelSettingsView(model: model).padding(.horizontal, 8)
                case .pronunciation:
                    PronunciationSettingsView(preview: model.pronunciationPreview, configuration: model.pronunciationConfiguration,
                        unavailableReason: model.pronunciationUnavailableReason,
                        editor: model.pronunciationIsInert ? .init(inertEntries: []) : .init(), beforePreview: { model.voiceSamplePlayer.stop() })
                case .delivery:
                    DeliveryPaneView(model: model).padding(.horizontal, 8)
                case .troubleshooting:
                    TroubleshootingView(model: model).padding(.horizontal, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { if let initialSection { model.settingsSection = initialSection } }
        .appFont(.body)
        .frame(minWidth: Self.minWindowWidth, idealWidth: Self.windowWidth, maxWidth: .infinity,
               minHeight: Self.minWindowHeight, idealHeight: Self.windowHeight, maxHeight: .infinity)
    }
}


#if DEBUG
#Preview("Settings — inert defaults") { SettingsView(model: AppModel(preview: true)) }
#Preview("Voice Model — verified speech runtime") {
    let storage = ManagedSpeechStorage(audioDirectory: URL(fileURLWithPath: "/synthetic/audio"),
        stateRoot: URL(fileURLWithPath: "/synthetic/state"), temporaryRoot: URL(fileURLWithPath: "/synthetic/scratch"))
    let model = AppModel(preview: true, storage: storage)
    model.runtimeTestResult = .success
    return VoiceModelSettingsView(model: model).frame(width: 500, height: 620)
}
#Preview("General — speech verification failed") {
    let model = AppModel(preview: true)
    model.runtimeTestResult = .failure("Speech setup or verification failed. Check the required tools and retry.")
    return VoiceModelSettingsView(model: model).frame(width: 500, height: 620)
}
#Preview("Settings — inert Publishing") { SettingsView(model: AppModel(preview: true), initialSection: .delivery) }
#Preview("Settings — inert UK English voices") {
    let model = AppModel(preview: true)
    model.preferences = SpeechPreferences(voice: .george)
    return SettingsView(model: model)
}
#Preview("Settings — inert troubleshooting") { SettingsView(model: AppModel(preview: true), initialSection: .troubleshooting) }
#Preview("Publishing — inert automatic reconciliation issue") {
    let model = AppModel(preview: true)
    model.deliveryError = "Server reconciliation: 1 item needs attention; other items continued."
    return SettingsView(model: model, initialSection: .delivery)
}

#endif

#if DEBUG
#Preview("Settings — large text at minimum window") {
    SettingsView(model: AppModel(preview: true)).appTextSizing(AppTextSize(percent: 200))
        .frame(width: 360, height: 540)
}
#endif

#if DEBUG
#Preview("Speech onboarding — inert first launch") {
    SpeechRuntimeOnboardingView(model: AppModel(preview: true))
}
#Preview("Speech onboarding — inert installation") {
    let model = AppModel(preview: true)
    model.runtimeBusy = true; model.runtimeInstalling = true
    return SpeechRuntimeOnboardingView(model: model)
}
#Preview("Speech onboarding — inert retry, large text") {
    let model = AppModel(preview: true)
    model.runtimeTestResult = .failure("The model download could not finish. Check your connection and retry.")
    return SpeechRuntimeOnboardingView(model: model).appTextSizing(AppTextSize(percent: 200))
}
#endif
