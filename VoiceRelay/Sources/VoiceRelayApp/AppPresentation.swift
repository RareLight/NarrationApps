import SwiftUI
import AppPresentation
import AppKit
import Observation
import VoiceRelayCore

enum QueueSelectionID: Hashable {
    case episode(String)
    case preparation(String)
}

/// Result of the explicit Test Connection action; editing delivery settings resets it.
enum DeliveryTestResult: Equatable {
    case untested
    case success
    case foldersPending
    case failure(String)
}

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case articles = "Articles"
    case uploads = "Uploads"
    case savedAudio = "Server Audio"
    var id: Self { self }
    var systemImage: String {
        switch self {
        case .articles: "doc.text"
        case .uploads: "tray.and.arrow.up"
        case .savedAudio: "waveform"
        }
    }
}

enum PublishingReadiness: Equatable {
    case needsSetup, configured, turnedOff, needsAttention, notChecked, checking
    var title: String {
        switch self {
        case .needsSetup: "Publishing needs setup"
        case .configured: "Publishing configured"
        case .turnedOff: "Publishing is turned off"
        case .needsAttention: "Publishing needs attention"
        case .notChecked: "Publishing has not been checked"
        case .checking: "Checking Publishing…"
        }
    }
    var detail: String {
        switch self {
        case .needsSetup: "Configure your podcast connection to listen in your podcast app. You can still generate audio."
        case .configured: "Configuration is present; write permission and public access are verified separately."
        case .turnedOff: "Enable Publishing when you want new episodes in your podcast app."
        case .needsAttention: "Review pending transfers and verification issues in Uploads, or check Publishing settings."
        case .notChecked: "The password has not been checked this session. Review Publishing to verify the connection."
        case .checking: "Checking your password and existing server audio."
        }
    }
    var action: String {
        switch self {
        case .needsSetup: "Set Up Publishing…"
        case .needsAttention: "Review Publishing…"
        default: "Publishing Settings…"
        }
    }
}

struct GenerateAudioControl: View {
    @Bindable var model: AppModel
    var body: some View {
        if model.processingSpeech {
            Button { model.stopQueue() } label: {
                Label(model.cancelling ? "Stopping…" : "Stop", systemImage: "stop.fill")
            }.disabled(!model.canStopProcessing)
                .help("Stop generation; unfinished article returns to Ready")
        } else {
            Button { model.runQueue() } label: { Label("Generate Audio", systemImage: "waveform") }
                .buttonStyle(.borderedProminent).disabled(!model.canGenerateAudio)
                .help(model.generationDisabledReason ?? "Generate all Ready articles, regardless of selection or filters")
        }
    }
}

struct WorkspaceReadinessView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        if model.libraryReviewRequired {
            notice("Review the restored library", detail: "Processing, publishing and cleanup wait until you finish the library review.",
                   symbol: "exclamationmark.triangle", action: "Review Library…", pane: .troubleshooting)
        } else {
            if !model.preview && (!model.speechRuntimeAvailable || model.runtimeBusy) {
                notice(model.runtimeBusy ? "Speech setup is in progress" : "Speech setup required",
                    detail: model.runtimeBusy ? "Wait for setup, or cancel it in General." : "Install the speech model or check speech setup in General before generating audio.",
                    symbol: "gearshape", action: "Open General", pane: .general)
            }
            if model.publishingReadiness == .checking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(PublishingReadiness.checking.title)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(alignment: .bottom) { Divider() }
            } else if let readiness = model.publishingSettingsNotice {
                notice(readiness.title, detail: model.deliveryError ?? readiness.detail,
                    symbol: readiness == .needsAttention ? "exclamationmark.triangle" : "gearshape",
                    action: readiness.action, pane: .delivery)
            }
            if model.uploadsNeedAttention {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Uploads need attention", systemImage: "exclamationmark.triangle").appFont(.headline)
                    Text("Review the affected files and their verification details in Uploads.").appFont(.secondary).foregroundStyle(.secondary)
                    if model.workspaceSection != .uploads {
                        Button("Review Uploads") { model.workspaceSection = .uploads }.disabled(model.preview || model.stopping)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(alignment: .bottom) { Divider() }
            }
        }
    }
    private func notice(_ title: String, detail: String, symbol: String, action: String, pane: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).appFont(.headline)
            Text(detail).appFont(.secondary).foregroundStyle(.secondary)
            Button(action) {
                model.settingsSection = pane
                WindowPresence.shared.prepareToOpen(); openSettings()
            }.disabled(model.preview || model.stopping)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(alignment: .bottom) { Divider() }
    }
}

struct WorkspaceActivityView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.showsProcessingProgress { ProcessingSummary(model: model) }
            if model.deliveryBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Publishing… · \(model.deliveryPendingCount) server operations pending").monospacedDigit()
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
    }
}

extension Stage {
    var friendlyLabel: String {
        switch self {
        case .discovered, .fetching: "Preparing article"
        case .extracted: "Preparing audio"
        case .synthesizing: "Generating audio"
        case .encoding, .encoded: "Finishing audio"
        case .published: "Audio generated"
        case .expired: "Audio expired"
        }
    }
}

struct TextSizeCommands: Commands {
    @Bindable var model: AppModel
    var body: some Commands {
        AppTextSizeCommands(size: Binding(get: { model.textSize }, set: { model.textSize = $0 }))
    }
}

struct ArticleOriginMetadata: Equatable {
    let host: String?
    let savedAt: Date?
    var savedDateText: String? { savedAt.map { "Saved \($0.formatted(date: .abbreviated, time: .omitted))" } }
}

/// Shared identity line for All Articles, Queue/preparing rows and Server Audio.
struct ArticleOriginLine: View {
    let metadata: ArticleOriginMetadata
    var body: some View {
        if metadata.host != nil || metadata.savedAt != nil {
            HStack(spacing: 6) {
                if let host = metadata.host { Text(host) }
                if let date = metadata.savedDateText { Text(date) }
            }.appFont(.secondary).foregroundStyle(.secondary)
        }
    }
}

/// Match visible fields locally using Foundation's locale-aware search.
enum LibraryTextSearch {
    static func isSearching(_ query: String) -> Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    static func matches(_ query: String, fields: [String?]) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let text = fields.compactMap { $0 }
        return terms.allSatisfy { term in text.contains { $0.localizedStandardContains(term) } }
    }
}

extension UploadItem {
    var sentBytesText: String? {
        guard phase.active, progress?.fraction != nil, let sent = progress?.sentBytes, let total = progress?.totalBytes else { return nil }
        return "\(ByteCountFormatter.string(fromByteCount: sent, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) sent"
    }
}

enum AppHelpTopic: String, Codable, CaseIterable, Identifiable {
    case publishing, libraryBackup
    var id: Self { self }
    var title: String {
        switch self {
        case .publishing: "Publishing and Uploads"
        case .libraryBackup: "Library Backup and Restore"
        }
    }
    var sections: [AppHelpSection] {
        switch self {
        case .publishing: [
            AppHelpSection(title: "Connect your podcast", text: "In Publishing settings, enter the WebDAV Feed folder and the Public folder that serves the same files. VoiceRelay creates feed.xml and audio/ under that folder. Choose a square Podcast Cover for the show; episode pictures still come from their articles. Copy the Subscription URL into your podcast app. Test Connection checks folder access; confirm public playback in your podcast app separately."),
            AppHelpSection(title: "Save your password", text: "Use your provider’s upload username and password or app password. Click Save Password after editing. The password stays in device-local Keychain and background publishing can use it after your first login following a reboot, including while the screen is locked. Re-save a password from an older build once to update its access policy; macOS may request authorization for that Save. Opening Settings never reads the password. Replacing or clearing a password may need separate approval."),
            AppHelpSection(title: "Watch pending uploads", text: "Publishing runs automatically while enabled and VoiceRelay is running. Uploads shows pending transfers and verification issues. An item clears after its audio and feed entry are confirmed, unless local cleanup needs attention. Fully sent bytes alone do not confirm publication. Use Retry Uploads after resolving an error; other items can continue."),
            AppHelpSection(title: "Remove a copy", text: "Uploads × discards the local copy and cancels its pending generation job, keeping server audio and saved article text. It will not automatically regenerate. Add the article to Queue to request it again. Server Audio × removes the episode from the feed and deletes its audio, including a matching local copy. Saved article text is kept. Files that cannot be safely removed stay listed."),
            AppHelpSection(title: "Existing server episodes", text: "VoiceRelay checks for matching server audio before generating or uploading again. It verifies complete copies and prefers longer valid audio at comparable voice and speed; ties and uncertain variants keep the server copy. For persistent errors, enable debug logging in Troubleshooting and copy the log.")
        ]
        case .libraryBackup: [
            AppHelpSection(title: "What a backup contains", text: "A library backup contains saved article text, Reading List inventory, Queue, episode history and publishing records. It includes private article URLs and server paths; keep it private. Passwords, preferences, audio, speech models and temporary chunks are excluded."),
            AppHelpSection(title: "Restore safely", text: "Stop processing and wait for uploads and additions to finish. Choose Restore Library in Troubleshooting. VoiceRelay validates the backup, keeps the previous library for recovery and turns off automatic processing and publishing. Restoring does not change Safari or contact the server."),
            AppHelpSection(title: "Finish your review", text: "Review Articles, Uploads, Server Audio and Publishing settings, then choose Finish Library Review. Until then, local cleanup and server changes are blocked, including after relaunch. Finishing review does not turn automation back on; enable it when ready. Missing pending audio can be regenerated from saved text.")
        ]
        }
    }
}
struct AppHelpSection: Identifiable {
    let title: String
    let text: String
    var id: String { title }
}
struct AppHelpView: View {
    let topic: AppHelpTopic
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(topic.title).appFont(.title2)
                ForEach(topic.sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title).appFont(.headline)
                        Text(section.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.appFont(.body).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }.navigationTitle(topic.title)
    }
}

struct SectionHelpHeader: View {
    let title: String
    var explanation: String?
    var helpTopic: AppHelpTopic? = nil
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        SettingsSectionHeader(title: title, explanation: explanation, moreHelp: helpTopic.map { topic in
            { WindowPresence.shared.prepareToOpen(); openWindow(value: topic) }
        })
    }
}

@MainActor @Observable
final class NoticeDismissalState {
    private var dismissed: Set<String> = []
    private static func slot(_ message: String, _ key: String) -> String { "\(key)\u{1F}\(message)" }
    func isVisible(message: String, key: String) -> Bool { !dismissed.contains(Self.slot(message, key)) }
    func dismiss(message: String, key: String) { dismissed.insert(Self.slot(message, key)) }
    func reset(key: String) { dismissed = dismissed.filter { !$0.hasPrefix("\(key)\u{1F}") } }
}

typealias InlineNotice = SettingsNotice

struct ProcessingSummary: View {
    let model: AppModel
    var body: some View {
        if model.showsProcessingProgress {
            if let batch = model.batchProgress {
                BatchProgressView(progress: batch, cancelling: model.cancelling, pendingOverride: model.pendingAdds.count)
            } else if model.progress != nil {
                VStack(alignment: .leading, spacing: 5) {
                    if let fraction = model.processingFraction { ProgressView(value: fraction) }
                    else { ProgressView() }
                    Text(model.processingStatusLine).monospacedDigit()
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.processingStatusLine)
                }
            }
        }
    }
}

struct WorkspaceView: View {
    @Bindable var model: AppModel
    private var section: WorkspaceSection { model.workspaceSection ?? .articles }
    var body: some View {
        NavigationSplitView {
            List(selection: $model.workspaceSection) {
                ForEach(WorkspaceSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.systemImage).tag(section)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 240)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 480)
        .appFont(.body)
        .disabled(model.libraryMaintenanceBusy)
        .onAppear { model.refreshLibrary() }
    }
    private var detail: some View {
        VStack(spacing: 0) {
            if section != .articles { WorkspaceReadinessView(model: model) }
            if let error = model.workspaceError, model.notices.isVisible(message: error, key: "global") {
                InlineNotice(message: error) { model.notices.dismiss(message: error, key: "global") }
                    .padding([.horizontal, .top])
            }
            if let warning = model.audioCleanupError, warning != model.workspaceError,
               model.notices.isVisible(message: warning, key: "audio") {
                InlineNotice(message: warning) { model.notices.dismiss(message: warning, key: "audio") }
                    .padding([.horizontal, .top])
            }
            switch section {
            case .articles: ArticlesView(model: model)
            case .uploads: UploadsView(model: model)
            case .savedAudio: LibraryView(model: model)
            }
            if model.showsWorkspaceActivity {
                Divider()
                WorkspaceActivityView(model: model)
            }
        }
        .navigationTitle(section == .articles && model.articleScope == .queue ? "Articles — Queue" : section.rawValue)
    }
}

struct SelectionManagementControl: View {
    let selectionCount: Int
    let resetTitle: String
    let canReset: Bool
    let canRemove: Bool
    let resetHelp: String
    let removeHelp: String
    let onReset: () -> Void
    let onRemove: () -> Void
    var usesBulkRemoval: Bool { selectionCount > 1 }
    var body: some View {
        Button(usesBulkRemoval ? "Remove Selections" : resetTitle, role: .destructive) {
            usesBulkRemoval ? onRemove() : onReset()
        }
        .frame(minWidth: 128)
        .disabled(usesBulkRemoval ? !canRemove : !canReset)
        .help(usesBulkRemoval ? removeHelp : resetHelp)
    }
}

struct RowRemovalButton: View {
    let accessibilityLabel: String
    let help: String
    let isEnabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "xmark") }
            .buttonStyle(.borderless)
            .disabled(!isEnabled)
            .accessibilityLabel(accessibilityLabel)
            .help(help)
    }
}

/// Shared by all scenes; reading Help never accesses application data or starts work.
struct AppHelpCommands: Commands {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .help) {
            ForEach(AppHelpTopic.allCases) { topic in
                Button(topic.title) {
                    WindowPresence.shared.prepareToOpen(); openWindow(value: topic)
                }.disabled(model.preview || model.stopping)
            }
        }
    }
}

struct LibraryCommands: Commands {
    @Bindable var model: AppModel
    @FocusedValue(\.libraryListActions) private var selection
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var body: some Commands {
        CommandMenu("Articles") {
            Button("Add to Queue") { selection?.add() }.disabled(selection?.canAdd != true)
            Button("Preview Article") { selection?.preview() }.disabled(selection?.canPreview != true)
            Button("Remove Selections") { selection?.remove() }.disabled(selection?.canRemove != true)
            Divider()
            Button("Generate Audio") {
                model.workspaceSection = .articles; model.articleScope = .queue
                WindowPresence.shared.prepareToOpen(); openWindow(id: "articles")
                model.runQueue()
            }.disabled(!model.canGenerateAudio).keyboardShortcut("g", modifiers: [.command, .shift])
            Button(model.cancelling ? "Stopping…" : "Stop") { model.stopQueue() }
                .disabled(!model.canStopProcessing).keyboardShortcut(".", modifiers: .command)
            Button("Upload New Items") { model.uploadNewItems() }.disabled(!model.canUploadNewItems)
            Divider()
            Button("Publishing Settings…") {
                model.settingsSection = .delivery
                WindowPresence.shared.prepareToOpen(); openSettings()
            }.disabled(model.preview || model.stopping)
        }
    }
}

struct BatchProgressView: View {
    let progress: QueueBatchProgress
    var cancelling = false
    var pendingOverride: Int? = nil
    var body: some View {
        let pending = pendingOverride ?? progress.pendingPreparations
        VStack(alignment: .leading, spacing: 5) {
            if let fraction = progress.displayFraction, progress.totalChunks + progress.totalArticles > 0 {
                ProgressView(value: min(1, max(0, fraction)))
            } else { ProgressView() }
            Text("\(phase) · \(progress.completedArticles)/\(progress.totalArticles) articles complete")
                .monospacedDigit()
            if pending > 0 {
                Text("Preparing \(pending) additional articles…").appFont(.secondary).monospacedDigit()
            }
        }
    }
    private var phase: String {
        if cancelling { return "Stopping…" }
        if progress.stage == .published && progress.completedArticles < progress.totalArticles {
            return "Verifying generated audio"
        }
        return progress.stage.friendlyLabel
    }
}

enum AudioStateFilter: String, CaseIterable, Identifiable {
    case all = "All Items", waiting = "Awaiting Upload", active = "Transferring / Verifying"
    case publication = "Awaiting Publication", published = "Published", attention = "Needs Attention"
    case verification = "Failed Verification", removing = "Pending Removal", discarded = "Local Upload Removed"
    var id: Self { self }
    static var outbox: [Self] { [.all, .waiting, .active, .publication, .attention, .verification] }
    func includes(_ phase: UploadPhase) -> Bool {
        switch self {
        case .all: true
        case .discarded: phase == .discarded
        case .waiting: phase == .waiting
        case .active: phase.active
        case .publication: phase == .publishing
        case .published: phase == .published
        case .attention: phase.needsAttention
        case .verification: phase == .verificationFailed || phase == .localConflict
        case .removing: phase == .removing || phase == .removalFailed
        }
    }
}

struct AudioStateFilterControl: View {
    @Binding var selection: AudioStateFilter
    let options: [AudioStateFilter]
    let items: [UploadItem]
    var body: some View {
        Picker("Filter", selection: $selection) {
            ForEach(options) { filter in
                Text("\(filter.rawValue) (\(items.filter { filter.includes($0.phase) }.count))").tag(filter)
            }
        }.pickerStyle(.menu).help("Filter by status")
    }
}

struct AudioVerificationIndicator: View {
    let item: UploadItem
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(item.phase.title, systemImage: symbol)
                .appFont(.secondary)
                .foregroundStyle(item.phase.needsAttention ? Color.orange : item.phase == .published ? Color.green : Color.secondary)
            if let detail = item.detail { Text(detail).appFont(.secondary).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }
    private var symbol: String {
        if item.phase.needsAttention { return "exclamationmark.triangle" }
        if item.phase == .published { return "checkmark.icloud" }
        return item.phase.active ? "arrow.up.circle" : "clock"
    }
}

struct UploadsView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            if model.deliveryBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.uploadProgress.isEmpty ? "Reconciling server and local records…" : "Publishing pending items…")
                        .appFont(.secondary)
                    Spacer()
                }.padding(12)
                Divider()
            }
            if model.visibleUploads.isEmpty {
                ContentUnavailableView(model.uploadItems.isEmpty ? "No Pending Uploads" : "No Matching Uploads",
                    systemImage: "tray.and.arrow.up", description: Text(model.uploadItems.isEmpty
                        ? "Verified, published episodes clear from this outbox automatically."
                        : "Try another search or state filter."))
            } else {
                List(model.visibleUploads) { item in
                    HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.episode.title).appFont(.headline).lineLimit(2)
                        ArticleOriginLine(metadata: model.savedAudioOrigin(item.episode))
                        AudioVerificationIndicator(item: item)
                        if let meta = model.savedAudioMeta(item.episode) { Text(meta).appFont(.secondary).foregroundStyle(.secondary) }
                        if item.phase.active {
                            if let fraction = item.progress?.fraction {
                                ProgressView(value: fraction)
                                if let text = item.sentBytesText {
                                    Text(text)
                                        .appFont(.secondary).monospacedDigit().foregroundStyle(.secondary)
                                }
                            } else { ProgressView().controlSize(.small) }
                        }
                    }
                    Spacer(minLength: 8)
                    RowRemovalButton(accessibilityLabel: "Remove \(item.episode.title) local upload",
                        help: "Delete local copy; keep server audio",
                        isEnabled: model.canDiscardLocalUpload(item)) { model.discardLocalUpload(item) }
                    }.padding(.vertical, 4)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                AudioStateFilterControl(selection: $model.uploadsFilter, options: AudioStateFilter.outbox, items: model.uploadItems)
            }
            if !model.uploadItems.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.retryUploads() } label: {
                        Label(model.uploadsNeedAttention ? "Retry Uploads" : "Upload New Items", systemImage: "icloud.and.arrow.up")
                    }
                        .disabled(!model.canRetryUploads).help("Retry pending publishing and verification")
                }
            }
        }
        .searchable(text: $model.uploadsSearchText, placement: .toolbar, prompt: "Search Uploads")
        .task {
            guard !model.preview else { return }
            while !Task.isCancelled, !model.stopping {
                model.refreshLibrary()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

struct LibraryView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var confirmingReset = false
    @State private var capturedResetIDs: [String] = []
    var body: some View {
        Group {
            if model.visibleServerAudio.isEmpty {
                ContentUnavailableView(model.savedEpisodes.isEmpty ? "No Server Audio" : "No Matching Episodes", systemImage: "waveform",
                                       description: Text(model.savedEpisodes.isEmpty ? "Add selected articles to the queue, then choose Generate Audio." : "Try another search or state filter."))
            } else {
                List(selection: $model.savedAudioSelection) {
                    ForEach(model.visibleServerAudio, id: \.id) { episode in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(episode.title).appFont(.headline).lineLimit(2)
                            ArticleOriginLine(metadata: model.savedAudioOrigin(episode))
                            let meta = model.savedAudioMeta(episode)
                            let removal = model.savedAudioRemovalStatus(episode)
                            Text(removal.map { "\($0)\(meta.map { " · " + $0 } ?? "")" }
                                 ?? meta ?? "Speech ready").appFont(.secondary).foregroundStyle(.secondary)
                            if removal == nil {
                                AudioVerificationIndicator(item: model.audioState(episode))
                            }
                        }
                        Spacer()
                        if episode.settings.temporaryAudio != true && episode.localAudioReleased != true {
                        Button("Show in Finder") { reveal(episode) }.disabled(model.preview)
                            .buttonStyle(.borderless).help("Show local audio in Finder")
                        }
                        RowRemovalButton(accessibilityLabel: "Delete \(episode.title) audio",
                            help: "Remove episode and delete its audio",
                            isEnabled: model.canRemoveSavedAudio(episode)) {
                            model.removeSavedAudio(ids: [episode.id])
                        }
                    }
                    .tag(episode.id)
                    }
                }
            }
        }
        .searchable(text: $model.serverAudioSearchText, placement: .toolbar, prompt: "Search Server Audio")
        .onChange(of: model.serverAudioSearchText) {
            model.savedAudioSelection.formIntersection(Set(model.visibleServerAudio.map(\.id)))
        }
        .onChange(of: model.serverAudioFilter) {
            model.savedAudioSelection.formIntersection(Set(model.visibleServerAudio.map(\.id)))
        }
        .onDeleteCommand { removeSelection() }
        .focusedValue(\.libraryListActions, LibraryListActions(
            canRemove: canRemoveSelection, remove: { removeSelection() }))
        .task {
            guard !model.preview else { return }
            while !Task.isCancelled, !model.stopping {
                model.refreshLibrary()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .toolbar {
            ToolbarItem {
                AudioStateFilterControl(selection: $model.serverAudioFilter, options: AudioStateFilter.allCases, items: model.savedEpisodes.map(model.audioState))
            }
            ToolbarItem {
                Menu {
                    Button("Publishing Settings…") {
                        model.settingsSection = .delivery
                        WindowPresence.shared.prepareToOpen(); openSettings()
                    }
                    if model.savedAudioSelection.count < 2 {
                        Divider()
                        selectionManagement
                    }
                } label: { Label("Actions", systemImage: "ellipsis") }
            }
            if model.showsUploadNewItems {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.uploadNewItems() } label: {
                        Label(model.deliveryBusy ? "Uploading…" : "Upload New Items", systemImage: "icloud.and.arrow.up")
                    }
                    .disabled(!model.canUploadNewItems)
                    .help("Upload new episodes")
                }
            }
            if model.savedAudioSelection.count > 1 {
                ToolbarItem(placement: .secondaryAction) { selectionManagement }
            }
        }
        .confirmationDialog("Remove all server audio?", isPresented: $confirmingReset) {
            Button("Reset Server Audio", role: .destructive) {
                let ids = capturedResetIDs
                capturedResetIDs = []
                model.removeSavedAudio(ids: ids)
            }
            Button("Cancel", role: .cancel) { capturedResetIDs = [] }
        } message: {
            Text("Remove the episodes and server audio for all \(capturedResetIDs.count) shown items and remove them from the feed? Saved article text and Reading List entries are kept.")
        }
    }
    private var selectionManagement: SelectionManagementControl {
        SelectionManagementControl(selectionCount: model.savedAudioSelection.count,
            resetTitle: "Reset Server Audio…", canReset: !model.visibleServerAudio.filter(model.canRemoveSavedAudio).isEmpty,
            canRemove: model.visibleServerAudio.contains { model.savedAudioSelection.contains($0.id) && model.canRemoveSavedAudio($0) },
            resetHelp: "Remove all shown episodes and their audio",
            removeHelp: "Remove selected episodes and their audio",
            onReset: {
                capturedResetIDs = model.visibleServerAudio.filter(model.canRemoveSavedAudio).map(\.id)
                confirmingReset = true
            },
            onRemove: { model.removeSavedAudio(ids: model.visibleServerAudio.filter { model.savedAudioSelection.contains($0.id) }.map(\.id)) })
    }
    private var canRemoveSelection: Bool {
        !model.savedAudioSelection.isEmpty && model.visibleServerAudio.contains {
            model.savedAudioSelection.contains($0.id) && model.canRemoveSavedAudio($0)
        }
    }
    private func removeSelection() {
        guard canRemoveSelection else { return }
        model.removeSavedAudio(ids: model.visibleServerAudio.filter { model.savedAudioSelection.contains($0.id) }.map(\.id))
    }
    private func reveal(_ episode: Episode) {
        let file = episode.settings.audio.appendingPathComponent(episode.id + ".m4a")
        if FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        else { model.error = "The temporary audio file is unavailable; published episodes remain on the server." }
    }
}

#if DEBUG
private struct UploadPreviewEpisode: Encodable {
    let id: String, title: String
    let stage: Stage
    let settings: PrototypeProfile
}
@MainActor private func uploadPreviewModel(active: Bool = false) -> AppModel {
    let model = AppModel(preview: true)
    var profile = PrototypeProfile.fixture(at: URL(fileURLWithPath: "/synthetic")); profile.temporaryAudio = true
    let seed = UploadPreviewEpisode(id: "synthetic-upload", title: "How the coast changes with the seasons", stage: .published, settings: profile)
    guard let data = try? JSONEncoder().encode(seed), var episode = try? JSONDecoder().decode(Episode.self, from: data) else { return model }
    episode.originalSourceHost = "articles.example"; episode.readingListSavedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
    if active {
        model.deliveryBusy = true
        model.uploadProgress[episode.id] = UploadProgress(episode: episode, phase: .transferring, sentBytes: 750_000, totalBytes: 1_000_000)
    } else {
        episode.delivery = DeliveryState(status: .failed, remotePath: "audio/synthetic-upload.m4a", lastError: "The remote bytes could not be verified. The local audio is retained for retry.")
        episode.delivery?.verificationFailed = true
    }
    model.savedEpisodes = [episode]; model.workspaceSection = .uploads
    return model
}
#Preview("Uploads — inert verification issue") { UploadsView(model: uploadPreviewModel()).frame(width: 720, height: 480) }
#Preview("Uploads — inert transfer progress") { UploadsView(model: uploadPreviewModel(active: true)).frame(width: 720, height: 480) }
#Preview("Uploads — inert empty outbox") { UploadsView(model: AppModel(preview: true)).frame(width: 720, height: 480) }
#Preview("Server Audio — inert errors filter") {
    let model = uploadPreviewModel(); model.serverAudioFilter = .attention
    return LibraryView(model: model).frame(width: 720, height: 480)
}
#Preview("Workspace — inert empty") { WorkspaceView(model: AppModel(preview: true)) }
#Preview("Workspace — inert unified articles") {
    let model = AppModel(preview: true)
    let entries = (1...3).map { index in
        ReadingListEntry(id: "synthetic-\(index)", safariID: "synthetic-\(index)",
            url: URL(string: "https://articles.example/\(index)")!, title: "A synthetic article \(index)",
            addedAt: Date(timeIntervalSinceReferenceDate: Double(index * 86_400)))
    }
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: entries, skippedEntries: 0))
    model.queueItems = [SpeechQueueItem(id: "synthetic-job", title: entries[1].title,
        sourceEntryID: entries[1].id, sourceHost: "articles.example")]
    model.articleSelection = [entries[0].id]
    return WorkspaceView(model: model)
}
#Preview("Workspace — inert restored library review") {
    let model = AppModel(preview: true)
    model.libraryReviewRequired = true
    return WorkspaceView(model: model)
}
#Preview("Workspace — inert Publishing attention") {
    let model = AppModel(preview: true)
    model.deliverySettings.enabled = true
    model.deliverySettings.feedFolderURL = URL(string: "https://upload.example/podcast/")
    model.deliverySettings.publicFolderURL = URL(string: "https://podcast.example/")
    model.deliveryPasswordChecked = true; model.deliveryPasswordStored = true
    model.deliveryError = "Synthetic permission failure"
    return WorkspaceView(model: model)
}
#Preview("Workspace — inert queue processing") {
    let model = AppModel(preview: true)
    model.running = true
    model.processingSpeech = true
    model.workspaceSection = .articles; model.articleScope = .queue
    model.queueItems = [SpeechQueueItem(id: "00000000-0000-0000-0000-000000000001", title: "A synthetic queued article", sourceHost: "articles.example"),
                       SpeechQueueItem(id: "00000000-0000-0000-0000-000000000002", title: "A synthetic interrupted article", state: .running, attempts: 1, sourceHost: "journal.example")]
    model.batchProgress = QueueBatchProgress(stage: .encoding, completedChunks: 5, totalChunks: 12, completedArticles: 0, totalArticles: 2, currentArticleIndex: 1)
    return WorkspaceView(model: model)
}
#Preview("Workspace — inert queue failure") {
    let model = AppModel(preview: true)
    model.workspaceSection = .articles; model.articleScope = .queue
    model.queueItems = [SpeechQueueItem(id: "00000000-0000-0000-0000-000000000001", title: "A synthetic failed article", state: .failed, attempts: 1, lastError: "Synthetic feed failure")]
    model.error = "Synthetic feed failure"
    return WorkspaceView(model: model)
}
#Preview("Server Audio — inert empty library") { LibraryView(model: AppModel(preview: true)) }
#Preview("Server Audio — inert delivery states") {
    let model = AppModel(preview: true)
    model.deliverySettings.enabled = true
    model.deliverySettings.feedFolderURL = URL(string: "https://upload.example/podcast/")
    model.deliverySettings.publicFolderURL = URL(string: "https://podcast.example/")
    model.deliveryPublicationSettingsHash = try? model.deliverySettings.publicationHash()
    let settings = PrototypeProfile.fixture(at: URL(fileURLWithPath: "/synthetic/Articles"))
    if let bytes = try? JSONEncoder().encode(settings), let profile = try? JSONSerialization.jsonObject(with: bytes) {
        for (index, state) in [DeliveryPublicationStatus.notUploaded, .awaitingUpload, .uploaded, .published, .failed].enumerated() {
            let id = "00000000-0000-0000-0000-00000000000\(index)", hash = "synthetic-copy-\(index)"
            let record: [String: Any] = ["id": "00000000-0000-0000-0000-00000000000\(index)",
                "title": "A synthetic saved article \(index + 1)", "stage": Stage.published.rawValue,
                "originalSourceHost": "articles.example",
                "readingListSavedAt": Double(86_400 * (index + 1)),
                "audioHash": hash, "settings": profile]
            if let data = try? JSONSerialization.data(withJSONObject: record),
               let episode = try? JSONDecoder().decode(Episode.self, from: data) { model.savedEpisodes.append(episode) }
            model.deliveryPublicationStates[id] = state
            model.deliveryPublicationAudioHashes[id] = hash
        }
    }
    return LibraryView(model: model)
}
#endif

#Preview("Help — publishing and uploads") { AppHelpView(topic: .publishing).frame(width: 560, height: 500) }
#Preview("Help — library backup and restore") { AppHelpView(topic: .libraryBackup).frame(width: 560, height: 500) }
