import SwiftUI
import AppKit
import Observation
import VoiceRelayCore

struct ConfigurationView: View {
    @Bindable var model: AppModel
    @State private var confirmingInstallation = false
    var body: some View {
        Form {
            if !model.speechRuntimeAvailable { speechSetup }
            Section {
                Picker("Language & Region", selection: $model.preferences.languageRegion) {
                    ForEach(SpeechLanguageRegion.allCases) { region in Text(region.label).tag(region) }
                }
                Picker("Voice", selection: $model.preferences.voice) {
                    ForEach(model.preferences.languageRegion.voices) { voice in Text(voice.label).tag(voice) }
                }
                Stepper("Speed: \(model.preferences.speed, specifier: "%.2f")×", value: $model.preferences.speed, in: 0.75...1.5, step: 0.05)
            } header: {
                SectionHelpHeader(title: "Speech",
                    explanation: "Voice and speed apply to newly added articles. Queued articles keep their original settings.")
            }.disabled(model.running)
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
                    explanation: "Safari’s Bookmarks.plist is the default source, checked every five minutes and never modified. Choose another file if needed. Optional archive recovery sends eligible public article URLs to Archive.ph or Wayback; copies may be older.")
            }
            if model.speechRuntimeAvailable { speechSetup }
        }.formStyle(.grouped)
            .confirmationDialog("Install speech runtime?", isPresented: $confirmingInstallation) {
                Button("Install Speech Runtime") { model.installSpeechRuntime() }
            } message: {
                Text("Download the pinned Python environment, packages and Kokoro model into VoiceRelay’s private runtime folder? Existing installations remain active until this installation succeeds.")
            }
    }
    private var speechSetup: some View {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button(model.runtimeBusy && !model.runtimeInstalling ? "Checking…" : "Check Speech Runtime") { model.checkSpeechRuntime() }
                            .disabled(!model.canManageSpeechRuntime)
                            .help(model.runtimeControlDisabledReason ?? "Verify speech tools and model offline")
                        if model.runtimeBusy {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { model.cancelRuntimeSetup() }
                        }
                    }
                    SpeechRuntimeTestIndicator(model: model)
                    if let reason = model.runtimeControlDisabledReason, !model.preview, !model.runtimeBusy {
                        Text(reason).font(AppTypography.secondary).foregroundStyle(.secondary)
                    }
                }
                Button(model.runtimeBusy && model.runtimeInstalling ? "Installing…" : "Install Speech Runtime…") { confirmingInstallation = true }
                    .disabled(!model.canManageSpeechRuntime)
                    .help(model.runtimeControlDisabledReason ?? "Install speech tools and model")
            } header: {
                SectionHelpHeader(title: "Speech setup",
                    explanation: "Install downloads the speech tools and model; existing installations stay active until setup succeeds. Requires python3, uv, ffmpeg and ffprobe. Check works offline.")
            }
    }

}

struct SpeechRuntimeTestIndicator: View {
    @Bindable var model: AppModel
    var body: some View {
        if !model.runtimeBusy {
            switch model.runtimeTestResult {
            case .untested: Text("Not tested").foregroundStyle(.secondary)
            case .success: Label("Runtime verified", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .cancelled: Text("Cancelled; test again when ready").foregroundStyle(.secondary)
            case .failure(let message):
                Label(message, systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                    explanation: "Feed folder holds feed.xml and audio/. Save your upload password in Keychain; macOS may ask you to unlock it.", helpTopic: .publishing)
            }
            Section {
                TextField("Public folder URL", text: $publicFolderText)
                    .focused($focusedURL, equals: .published)
                    .onSubmit { commitURLs() }
                    .help("Public address serving your uploaded files")
                VStack(alignment: .leading, spacing: 8) {
                    Text("Subscription URL").font(.headline)
                    Text(draftSubscriptionURL?.absoluteString ?? "Enter a public folder URL")
                        .textSelection(.enabled).font(AppTypography.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Copy", systemImage: "doc.on.doc") {
                        if commitURLs() { model.copyDeliverySubscriptionURL() }
                    }.disabled(draftSubscriptionURL == nil || model.preview)
                }
                TextField("Channel title", text: $model.deliverySettings.channelTitle)
                TextField("Channel description", text: $model.deliverySettings.channelDescription)
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
                Button(model.deliveryBusy ? "Uploading…" : "Upload Now") { if commitURLs() { model.triggerDelivery(force: true) } }
                    .disabled(model.deliveryBusy || !model.deliverySettings.enabled || model.preview || model.stopping || model.deliveryCredentialBusy)
                    .help("Retry pending uploads now")
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

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case delivery = "Publishing"
    case troubleshooting = "Troubleshooting"
    var id: Self { self }
    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .delivery: "antenna.radiowaves.left.and.right"
        case .troubleshooting: "stethoscope"
        }
    }
    var help: String {
        switch self {
        case .general: "Speech, Reading List and automation"
        case .delivery: "Podcast connection, publishing and subscription URL"
        case .troubleshooting: "Library backup and logs"
        }
    }
}

struct SettingsPaneSelector: View {
    @Binding var selection: SettingsSection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var selectedTile
    @FocusState private var focusedPane: SettingsSection?
    @State private var keyboardNavigation = false
    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        if NSApp.currentEvent?.type == .keyDown {
                            keyboardNavigation = true
                        } else {
                            focusedPane = nil; keyboardNavigation = false
                        }
                        if reduceMotion { selection = section }
                        else { withAnimation(.smooth(duration: 0.2)) { selection = section } }
                    } label: {
                        paneLabel(section)
                    }
                    .buttonStyle(.plain)
                    .focused($focusedPane, equals: section)
                    .focusEffectDisabled()
                    .accessibilityLabel(section.rawValue)
                    .accessibilityAddTraits(selection == section ? .isSelected : [])
                    .help(section.help)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings panes")
        .frame(width: SettingsView.paneSelectorWidth, height: SettingsView.paneSelectorHeight)
        .onChange(of: focusedPane) { _, focused in
            if focused != nil, NSApp.currentEvent?.type == .keyDown { keyboardNavigation = true }
        }
    }
    @ViewBuilder private func paneLabel(_ section: SettingsSection) -> some View {
        let selected = selection == section
        let label = VStack(spacing: 4) {
            Image(systemName: section.systemImage).font(.system(size: SettingsView.paneSymbolSize))
            Text(section.rawValue).font(.system(size: SettingsView.paneLabelSize)).lineLimit(1)
        }
        .frame(width: (SettingsView.paneSelectorWidth - 8 * CGFloat(SettingsSection.allCases.count - 1))
               / CGFloat(SettingsSection.allCases.count), height: SettingsView.paneSelectorHeight)
        .contentShape(Rectangle())
        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        .overlay {
            if keyboardNavigation && focusedPane == section {
                RoundedRectangle(cornerRadius: 8).stroke(.tint, lineWidth: 1.5)
                    .padding(-2).allowsHitTesting(false)
            }
        }
        if selected {
            if reduceTransparency {
                label.background(.background, in: .rect(cornerRadius: 8))
            } else {
                label
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 8))
                    .glassEffectID("selected-settings-pane", in: selectedTile)
            }
        } else {
            label
        }
    }
}

struct SettingsView: View {
    static let windowWidth: CGFloat = 400
    static let windowHeight: CGFloat = 680
    static let minWindowWidth: CGFloat = 360
    static let minWindowHeight: CGFloat = 540
    static let paneSelectorWidth: CGFloat = 292 // 3 tiles × 92 + 2 × 8 spacing
    static let paneSelectorHeight: CGFloat = 46
    static let paneSymbolSize: CGFloat = 16
    static let paneLabelSize: CGFloat = 12
    @Bindable var model: AppModel
    private let initialSection: SettingsSection?
    private var section: SettingsSection { model.settingsSection }
    init(model: AppModel, initialSection: SettingsSection? = nil) {
        self.model = model; self.initialSection = initialSection
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                SettingsPaneSelector(selection: $model.settingsSection)
            }
            .padding(.vertical, 12)
            Divider()
            Group {
                switch section {
                case .general:
                    ConfigurationView(model: model).padding(.horizontal, 8)
                case .delivery:
                    DeliveryPaneView(model: model).padding(.horizontal, 8)
                case .troubleshooting:
                    TroubleshootingView(model: model).padding(.horizontal, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { if let initialSection { model.settingsSection = initialSection } }
        .font(AppTypography.body)
        .frame(minWidth: Self.minWindowWidth, idealWidth: Self.windowWidth, maxWidth: .infinity,
               minHeight: Self.minWindowHeight, idealHeight: Self.windowHeight, maxHeight: .infinity)
    }
}


#if DEBUG
#Preview("Settings — inert defaults") { SettingsView(model: AppModel(preview: true)) }
#Preview("General — verified speech runtime") {
    let storage = ManagedSpeechStorage(audioDirectory: URL(fileURLWithPath: "/synthetic/audio"),
        stateRoot: URL(fileURLWithPath: "/synthetic/state"), temporaryRoot: URL(fileURLWithPath: "/synthetic/scratch"))
    let model = AppModel(preview: true, storage: storage)
    model.runtimeTestResult = .success
    return ConfigurationView(model: model).frame(width: 400, height: 620)
}
#Preview("General — speech verification failed") {
    let model = AppModel(preview: true)
    model.runtimeTestResult = .failure("Speech setup or verification failed. Check the required tools and retry.")
    return ConfigurationView(model: model).frame(width: 400, height: 620)
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
