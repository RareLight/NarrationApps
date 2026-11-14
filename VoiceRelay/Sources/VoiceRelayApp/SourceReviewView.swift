import Pronunciation
import NarrationUI
import NarrationCore
import AppPresentation
import SwiftUI
import AppKit
import Observation
import VoiceRelayCore

@MainActor @Observable
final class SourceReviewModel {
    var catalog = ReadingListCatalog() {
        didSet {
            let inventoryChanged = oldValue.entries != catalog.entries || oldValue.currentIDs != catalog.currentIDs
            if inventoryChanged {
                catalogRevision = UUID()
                articleSourceKeys = Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.id, FixtureCoordinator.articleSourceKey($0.url)) })
            }
            if inventoryChanged || !catalog.hasSameDuplicateEvidence(as: oldValue) { duplicateStatuses = catalog.duplicateStatuses }
        }
    }
    @ObservationIgnored private(set) var catalogRevision = UUID()
    private(set) var articleSourceKeys: [String: String] = [:]
    private(set) var duplicateStatuses = ReadingListCatalog().duplicateStatuses
    var plist: URL?
    var status = "Saved articles load automatically once a Reading List source is chosen."
    var error: String?
    var busy = false
    private(set) var maintenanceSuspended = false
    var preview = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private let coordinator: FixtureCoordinator
    @ObservationIgnored private var catalogLoaded = false
    @ObservationIgnored private var stopping = false
    @ObservationIgnored var onCatalogChange: ([ReadingListEntry]) -> Void = { _ in }
    @ObservationIgnored var onContextChange: () -> Void = {}
    @ObservationIgnored private let stateRootOverride: URL?
    @ObservationIgnored private let snapshotReader: @Sendable (URL) async throws -> ReadingListSnapshot
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var autoSyncTask: Task<Void, Never>?
    @ObservationIgnored private var immediateSyncTask: Task<Void, Never>?
    @ObservationIgnored private var sourceReadTask: Task<ReadingListSnapshot, Error>?
    private var autoReading = false
    @ObservationIgnored private var sourceCommitWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var syncRequested = false
    @ObservationIgnored private var sourceGeneration = 0
    static let syncInterval: Duration = .seconds(300)
    @ObservationIgnored private let waitForNextSync: @Sendable (Duration) async throws -> Void
    var synchronizing: Bool { busy || autoReading }
    var lastSyncedAt: Date?
    private var stateRoot: URL { stateRootOverride ?? AppStorage.managedLibrary }

    init(preview: Bool = false, coordinator: FixtureCoordinator = FixtureCoordinator(),
         stateRoot: URL? = nil, plist: URL? = nil,
         defaults: UserDefaults = .standard,
         waitForNextSync: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         snapshotReader: (@Sendable (URL) async throws -> ReadingListSnapshot)? = nil) {
        self.coordinator = coordinator
        self.defaults = defaults
        self.waitForNextSync = waitForNextSync
        self.preview = preview
        stateRootOverride = stateRoot
        self.snapshotReader = snapshotReader ?? { url in
            let child = Task.detached { try ReadingList.read(url) }
            return try await withTaskCancellationHandler { try await child.value } onCancel: { child.cancel() }
        }
        if let plist { self.plist = plist }
        else if !preview, stateRoot == nil {
            self.plist = Self.preferredPlist(savedPath: defaults.string(forKey: "readingListSource"))
        }
    }
    static func preferredPlist(savedPath: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let path = savedPath, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: path)
        }
        return home.appendingPathComponent("Library/Safari/Bookmarks.plist")
    }
    func loadCatalog() {
        guard !preview, !busy, !catalogLoaded, !maintenanceSuspended, !stopping else { return }
        let request = UUID(); requestID = request; busy = true
        task = Task {
            defer { if requestID == request { busy = false; task = nil } }
            do {
                let saved = try await coordinator.catalog(stateRoot: stateRoot)
                try Task.checkCancellation(); guard requestID == request else { return }
                catalog = saved; catalogLoaded = true
                if !saved.entries.isEmpty { status = "Saved articles loaded; the chosen source is checked automatically." }
            } catch { if requestID == request { self.error = safe(error) } }
        }
    }

    var sourcePickerURL: URL { plist ?? Self.preferredPlist(savedPath: nil) }
    func selectPlist() {
        guard !preview, !busy, !maintenanceSuspended, !stopping else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "Choose a Reading List property-list file (read-only)"
        panel.directoryURL = sourcePickerURL.deletingLastPathComponent()
        panel.nameFieldStringValue = sourcePickerURL.lastPathComponent
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { setSource(url) }
    }
    func setSource(_ url: URL) {
        guard !preview, !maintenanceSuspended, !stopping else { return }
        guard url != plist else { onContextChange(); requestSourceSync(); return }
        sourceGeneration += 1
        sourceReadTask?.cancel()
        plist = url; error = nil; lastSyncedAt = nil
        if stateRootOverride == nil { defaults.set(url.path, forKey: "readingListSource") }
        onContextChange()
        requestSourceSync()
    }
    func startAutomaticSynchronization() {
        guard !preview, !stopping, autoSyncTask == nil else { return }
        autoSyncTask = Task { [weak self] in
            guard let self else { return }
            loadCatalog()
            while let read = task { await read.value }
            await refreshSource()
            while !Task.isCancelled, !stopping {
                do { try await waitForNextSync(Self.syncInterval) } catch { break }
                await refreshSource()
            }
        }
    }
    func requestSourceSync() {
        guard !preview, !maintenanceSuspended, !stopping else { return }
        syncRequested = true
        guard immediateSyncTask == nil else { return }
        immediateSyncTask = Task { [weak self] in
            guard let self else { return }
            defer { immediateSyncTask = nil }
            while syncRequested, !stopping {
                syncRequested = false
                while busy, let read = task { await read.value }
                // The reader task finishes before catalog reconciliation. Awaiting its
                // completed value in a tight loop can starve the main-actor commit.
                while autoReading, !stopping, !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
                }
                if stopping || Task.isCancelled { break }
                _ = await synchronizeOnce()
            }
        }
    }
    /// Used by the native pull gesture: wait for the coalesced read and commit so
    /// the system refresh indicator covers the entire operation.
    @discardableResult func refreshSource() async -> Bool {
        let previous = lastSyncedAt
        requestSourceSync()
        await immediateSyncTask?.value
        return lastSyncedAt != previous && error == nil && !stopping && !Task.isCancelled
    }
    @discardableResult
    func synchronizeOnce() async -> Bool {
        guard !preview, !maintenanceSuspended, !stopping, !busy, !autoReading else { return false }
        guard let file = plist else {
            if catalog.entries.isEmpty { status = "Choose a Reading List source in Settings to load articles." }
            return true
        }
        autoReading = true
        defer {
            autoReading = false; sourceReadTask = nil
            let waiters = sourceCommitWaiters; sourceCommitWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        let generation = sourceGeneration
        let readTask = Task { try await snapshotReader(file) }
        sourceReadTask = readTask
        do {
            let firstRead = lastSyncedAt == nil
            let result = try await withTaskCancellationHandler { try await readTask.value } onCancel: { readTask.cancel() }
            try Task.checkCancellation()
            guard !stopping, !maintenanceSuspended, generation == sourceGeneration, plist == file else { return true }
            let current = try await coordinator.catalog(stateRoot: stateRoot)
            try Task.checkCancellation()
            guard !stopping, !maintenanceSuspended, generation == sourceGeneration, plist == file else { return true }
            var proposed = current
            proposed.reconcile(result); proposed.excludedIDs = []
            let currentURLs = Set(proposed.entries.map(\.url))
            let removed = current.entries.filter { !currentURLs.contains($0.url) }
            if proposed.entries != current.entries || proposed.currentIDs != current.currentIDs {
                let saved = try await coordinator.reconcile(result, stateRoot: stateRoot)
                guard generation == sourceGeneration, plist == file else { return true }
                // Once committed, inventory reflects the saved result even if article selection changed.
                catalog = saved; onCatalogChange(removed)
            } else {
                catalog = proposed
                if firstRead { onCatalogChange([]) }
            }
            catalogLoaded = true; error = nil; lastSyncedAt = Date()
            status = "\(result.entries.count) current entries; \(result.skippedEntries) unsupported entries skipped."
            onContextChange()
        } catch is CancellationError {
        } catch {
            guard generation == sourceGeneration, plist == file else { return true }
            self.error = safe(error)
        }
        return true
    }
    /// Prevent a source commit from crossing an atomic library replacement.
    func suspendForLibraryReplacement() async {
        maintenanceSuspended = true; sourceGeneration += 1; syncRequested = false
        let current = task, immediate = immediateSyncTask, read = sourceReadTask
        current?.cancel(); immediate?.cancel(); read?.cancel()
        await current?.value; await immediate?.value
        _ = try? await read?.value
        // A direct synchronizeOnce caller owns the commit after its reader completes.
        await waitForSourceCommit()
        lastSyncedAt = nil
    }
    private func waitForSourceCommit() async {
        await withCheckedContinuation { continuation in
            if autoReading { sourceCommitWaiters.append(continuation) }
            else { continuation.resume() }
        }
    }
    func reloadAfterLibraryReplacement() async throws {
        let saved = try await coordinator.catalog(stateRoot: stateRoot)
        try Task.checkCancellation()
        catalog = saved; catalogLoaded = true; error = nil
        status = "Restored articles loaded. Review the library before enabling automation."
    }
    func finishLibraryReplacement() { maintenanceSuspended = false }
    func cancel() { task?.cancel() }
    func stop() async {
        stopping = true
        sourceGeneration += 1
        let current = task, auto = autoSyncTask, immediate = immediateSyncTask, read = sourceReadTask
        current?.cancel(); auto?.cancel(); immediate?.cancel(); read?.cancel()
        await current?.value; await auto?.value; await immediate?.value
        _ = try? await read?.value
        await waitForSourceCommit()
    }
    private func safe(_ error: any Error) -> String {
        if error is SourceFetchError || error is RelayError || error is ArticleRecoveryError { return error.localizedDescription }
        return "Source review failed; inspect the selected source and retry."
    }
}

/// Backing model for the standalone Article Preview window; one fetch per open window.
@MainActor @Observable
final class ArticlePreviewModel {
    var review: ReviewedSource?
    var status = "Loading article…"
    var error: String?
    var busy = false
    var title: String? { review?.document?.article.title }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let inert: Bool
    init(inert: Bool = false, review: ReviewedSource? = nil) {
        self.inert = inert
        if let review { self.review = review; status = review.issue == nil ? "Article ready." : "Source needs inspection." }
    }
    func load(_ url: URL, profile: PrototypeProfile? = nil, settings: SpeechSettings = .init(), options: NarrationOptions = .init(), sourceTitle: String? = nil,
              hostAdmission: SpeechHostAdmission? = nil, cpuExecutor: (any NarrationCPUExecutor)? = nil) {
        guard !inert, review == nil, !busy else { return }
        busy = true; error = nil; status = "Loading article…"
        task = Task {
            defer { busy = false; task = nil }
            do {
                let limits = try FetchLimits(maximumBytes: profile?.maxArticleBytes ?? 10_000_000,
                                            timeout: Double(profile?.httpTimeoutSeconds ?? 30))
                let limit = profile?.chunkMaxCharacters ?? 1800
                let archives = UserDefaults.standard.bool(forKey: "useArchivedArticles")
                let descriptions = UserDefaults.standard.object(forKey: "describeArticleImages") as? Bool ?? true
                let generateTitles = UserDefaults.standard.bool(forKey: "generateMissingTitles")
                let capturedOptions = profile.map { $0.narrationOptions ?? .init() } ?? options
                let capturedSettings = profile.map { SpeechSettings(voice: $0.voice ?? settings.voice, speed: Float($0.backendSettings["speed"]?.numericValue ?? Double(settings.speed))) } ?? settings
                let work = Task.detached {
                    try await NarrationPreparationWork.$executor.withValue(cpuExecutor) {
                        let dictionary = try await NarrationPreparationWork.run { try PronunciationStore().load().dictionary }
                        return try await ArticleSourceLoader(limits: limits, useArchives: archives,
                            describeImages: descriptions, speechSettings: capturedSettings, pronunciations: dictionary, narrationOptions: capturedOptions,
                            sourceTitle: sourceTitle, generateMissingTitles: generateTitles, hostAdmission: hostAdmission).load(url, chunkLimit: limit)
                    }
                }
                let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                review = result
                status = result.issue == nil ? (result.page.archivedCopy == nil ? "Article ready." : "Archived article ready.") : "Source needs inspection."
            } catch is CancellationError { status = "Loading cancelled." }
            catch { self.error = safe(error); status = "Article needs attention." }
        }
    }
    func cancel() { task?.cancel() }
    func showSaved(_ saved: ReviewedSource, profile: PrototypeProfile? = nil, settings: SpeechSettings = .init(), options: NarrationOptions = .init(), cpuExecutor: (any NarrationCPUExecutor)? = nil) async {
        task?.cancel()
        if let task { await task.value }
        guard !Task.isCancelled else { return }
        review = saved; status = "Saved article ready."; error = nil
        guard !inert, let document = saved.document else { return }
        busy = true
        defer { busy = false }
        let capturedSettings = profile.map { SpeechSettings(voice: $0.voice ?? settings.voice, speed: Float($0.backendSettings["speed"]?.numericValue ?? Double(settings.speed))) } ?? settings
        let capturedOptions = profile.map { $0.narrationOptions ?? .init() } ?? options
        let work = Task.detached {
            try await NarrationPreparationWork.$executor.withValue(cpuExecutor) {
                try await NarrationPreparationWork.run {
                    let dictionary = try PronunciationStore().load().dictionary
                    return try Narration.prepare(document.article, limit: profile?.chunkMaxCharacters ?? 1800,
                        pronunciations: dictionary, settings: capturedSettings, options: capturedOptions)
                }
            }
        }
        do {
            let narration = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            try Task.checkCancellation()
            review = .init(page: saved.page, document: document, narration: narration, issue: saved.issue)
        } catch is CancellationError {}
        catch { self.error = "The saved narration preview could not be prepared." }
    }
    private func safe(_ error: any Error) -> String {
        if error is SourceFetchError || error is RelayError || error is ArticleRecoveryError { return error.localizedDescription }
        return "Article preview failed; inspect the source and retry."
    }
}

/// Review-content rendering shared by the standalone preview window.
struct ArticlePreviewContent: View {
    let review: ReviewedSource?
    var placeholder = "Loading article…"
    @State private var dismissedIssue: String?
    var body: some View {
        ScrollViewReader { proxy in
        VStack(alignment: .leading, spacing: 12) {
            if let review {
                Text(review.document?.article.title ?? "Source inspection").appFont(.title2)
                if let origin = review.document?.article.titleOrigin {
                    Text(origin.label).appFont(.secondary).foregroundStyle(.secondary)
                }
                Text("Original: \(review.page.originalURL.absoluteString)\nFinal: \(review.page.finalURL.absoluteString)").appFont(.secondary).textSelection(.enabled)
                if let copy = review.page.archivedCopy {
                    Text("Archived copy · \(copy.provider.label) · \(AppDateFormatting.date(copy.capturedAt))")
                        .appFont(.secondary).foregroundStyle(.secondary)
                }
                if let message = review.issueMessage, dismissedIssue != message {
                    InlineNotice(message: message) { dismissedIssue = message }
                }
                if let document = review.document {
                    DocumentNavigationMenu(entries: document.article.outline ?? DocumentNavigation.headings(in: document.article.blocks)) { entry in
                        if let index = entry.blockIndex { proxy.scrollTo("article-source-\(index)", anchor: .top) }
                    }
                    Text("Semantic blocks").appFont(.headline)
                    ForEach(Array(document.article.blocks.enumerated()), id: \.offset) { index, block in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(index) · \(block.kind.rawValue)").appFont(.secondary).foregroundStyle(.secondary)
                            Text(block.text).textSelection(.enabled)
                            if block.imageDescriptionGenerated == true, let description = block.narrationText {
                                Text("Generated · " + description).appFont(.secondary).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }.id("article-source-\(index)")
                    }
                    ForEach(document.article.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                }
                if let narration = review.narration {
                    Text("Narration preview · \(narration.chunks.count) chunks").appFont(.headline)
                    ForEach(narration.chunks, id: \.index) { chunk in Text(chunk.text).textSelection(.enabled) }
                    ForEach(narration.notices, id: \.self) { Text($0).foregroundStyle(.orange) }
                }
            } else { Text(placeholder).foregroundStyle(.secondary) }
        }
        }
    }
}
struct ArticlePreviewView: View {
    let cpuExecutor: (any NarrationCPUExecutor)?
    let hostAdmission: SpeechHostAdmission?
    let url: URL
    let settings: SpeechSettings
    let profile: PrototypeProfile?
    let options: NarrationOptions
    let savedReview: ReviewedSource?
    let sourceTitle: String?
    @State private var model: ArticlePreviewModel
    @Environment(\.dismiss) private var dismiss
    init(url: URL, inert: Bool = false, review: ReviewedSource? = nil, settings: SpeechSettings = .init(), profile: PrototypeProfile? = nil, options: NarrationOptions = .init(), sourceTitle: String? = nil,
         hostAdmission: SpeechHostAdmission? = nil, cpuExecutor: (any NarrationCPUExecutor)? = nil) {
        self.hostAdmission = hostAdmission; self.cpuExecutor = cpuExecutor
        self.profile = profile; self.options = options
        self.savedReview = review; self.sourceTitle = sourceTitle
        self.url = url; self.settings = settings
        _model = State(initialValue: ArticlePreviewModel(inert: inert, review: review))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.busy { ProgressView().controlSize(.small) }
                if let error = model.error { InlineNotice(message: error) { model.error = nil } }
                ArticlePreviewContent(review: model.review, placeholder: model.status)
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
        }
        .appFont(.body)
        .navigationTitle(model.title ?? "Article Preview")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }.help("Close this article preview")
            }
        }
        .task(id: savedReview?.document?.article.title) {
            if let savedReview { await model.showSaved(savedReview, profile: profile, settings: settings, options: options, cpuExecutor: cpuExecutor) }
            else { model.load(url, profile: profile, settings: settings, options: options, sourceTitle: sourceTitle, hostAdmission: hostAdmission, cpuExecutor: cpuExecutor) }
        }
        .onDisappear { model.cancel() }
    }
}

struct TroubleshootingView: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            LibraryBackupControls(model: model)
            DeliveryDebugControls(model: model)
        }.formStyle(.grouped)
    }
}

struct DeliveryDebugControls: View {
    @Bindable var model: AppModel
    var body: some View {
        Section {
            Toggle("Enable debug logging", isOn: $model.debugLoggingEnabled).disabled(model.preview)
            HStack {
                Button("Copy Debug Log") { model.copyDebugLog() }.disabled(model.preview)
                Button("Clear Log") { model.deliveryDebugLog.clear() }.disabled(model.preview)
            }
        } header: {
            SectionHelpHeader(title: "Debug logging",
                explanation: "Keeps recent diagnostic events for this session. Credentials, URLs, article text and server responses are excluded.")
        }
    }
}

struct LibraryBackupControls: View {
    @Bindable var model: AppModel
    @State private var restoreURL: URL?
    @State private var restoreSummary: LibraryBackupSummary?
    @State private var confirmingRestore = false
    var body: some View {
        Section {
            HStack {
                Button("Back Up Library…") { model.chooseLibraryBackup() }
                Button("Restore Library…") { chooseRestore() }
                if model.libraryMaintenanceBusy { ProgressView().controlSize(.small) }
            }.disabled(!model.canManageLibrary)
            if model.libraryReviewRequired {
                Button("Finish Library Review") { model.finishLibraryReview() }.disabled(!model.canManageLibrary)
            }
            if let status = model.libraryBackupStatus { Text(status).appFont(.secondary) }
            if let error = model.libraryBackupError { InlineNotice(message: error) }
        } header: {
            SectionHelpHeader(title: "Library backup",
                explanation: "Backups include private article and server information, but no passwords or audio. Restore keeps the previous library and pauses automation until you finish reviewing.", helpTopic: .libraryBackup)
        }
        .confirmationDialog("Restore this library backup?", isPresented: $confirmingRestore) {
            Button("Restore Library", role: .destructive) {
                if let restoreURL { model.restoreLibrary(from: restoreURL) }
                restoreURL = nil; restoreSummary = nil
            }
        } message: {
            Text("Restore \(restoreSummary?.retainedArticles ?? 0) saved articles and \(restoreSummary?.episodes ?? 0) episode records? The current library will be retained for recovery. Automatic processing and delivery will be turned off until you review the restored state.")
        }
    }
    private func chooseRestore() {
        guard model.canManageLibrary else { return }
        let panel = NSOpenPanel(); panel.title = "Choose VoiceRelay Library Backup"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let summary = try await model.coordinator.inspectLibraryBackup(url)
                guard model.canManageLibrary else { return }
                restoreURL = url; restoreSummary = summary; confirmingRestore = true
            } catch {
                model.libraryBackupError = (error as? RelayError)?.localizedDescription ?? "This library backup is invalid or unsupported."
            }
        }
    }
}

@MainActor
enum ArticlePreviewNavigation {
    static func validated(_ url: URL) -> URL? { try? ArticleURL.validate(url) }
    static func open(_ url: URL, using action: OpenWindowAction, inert: Bool = false) {
        guard !inert, let validated = validated(url) else { return }
        WindowPresence.shared.prepareToOpen()
        action(value: validated)
    }
}

enum ArticleRowID: Hashable {
    case source(String)
    case retained(QueueSelectionID)
}

struct ArticleLibraryRow: Identifiable {
    let id: ArticleRowID
    let title: String
    let host: String?
    let savedAt: Date?
    let source: ReadingListEntry?
    var jobs: [SpeechQueueItem]
    let preparationID: String?
    let retained: Bool
    var inactiveDuplicate: Bool = false
    var narrationComplete: Bool = false
    var matchingAudioExists: Bool = false
    var preparationFailure: String? = nil
    /// Any idle, active Reading List article without matching completed audio can be
    /// regenerated explicitly — including rows whose saved audio the user deleted.
    var offersReprocessing: Bool {
        source != nil && !retained && !inactiveDuplicate && jobs.isEmpty
            && preparationID == nil && preparationFailure == nil
            && (narrationComplete || !matchingAudioExists)
    }
}

/// Foundation parses/IDNA-normalizes hosts. The www alias is a display policy only;
/// source identities remain untouched, and other publication subdomains stay separate.
enum ArticleWebsiteFilter: Hashable, Identifiable {
    case today, thisWeek, all, unknown, site(String)
    static let dateOptions: [Self] = [.today, .thisWeek]
    var isDateFilter: Bool { self == .today || self == .thisWeek }
    var id: Self { self }
    var title: String {
        switch self { case .today: "Today"; case .thisWeek: "This Week"; case .all: "All Websites"; case .unknown: "Unknown Website"; case .site(let host): host }
    }
    static func siteKey(_ origin: String?) -> String? {
        guard let origin = origin?.trimmingCharacters(in: .whitespacesAndNewlines), !origin.isEmpty,
              let components = URLComponents(string: origin.contains("://") ? origin : "https://" + origin),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil, components.password == nil,
              let url = components.url, var host = url.host(percentEncoded: true)?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }
    func includes(_ row: ArticleLibraryRow, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .today, .thisWeek:
            guard let saved = row.savedAt,
                  let interval = calendar.dateInterval(of: self == .today ? .day : .weekOfYear, for: now) else { return false }
            return saved >= interval.start && saved < interval.end
        case .all: return true
        case .unknown: return Self.siteKey(row.host) == nil
        case .site(let host): return Self.siteKey(row.host) == host
        }
    }
}

/// A fresh content projection, independent of selection. Selection lookups reuse
/// its identities and display order rather than rebuilding the source/job union.
struct ArticleListProjection {
    let visibleRows: [ArticleLibraryRow]
    let rowIDs: Set<ArticleRowID>
    private let visibleByID: [ArticleRowID: (index: Int, row: ArticleLibraryRow)]

    init(rows: [ArticleLibraryRow], visibleRows: [ArticleLibraryRow]) {
        self.visibleRows = visibleRows
        rowIDs = Set(rows.map(\.id))
        visibleByID = Dictionary(visibleRows.enumerated().map { ($0.element.id, (index: $0.offset, row: $0.element)) },
                                 uniquingKeysWith: { first, _ in first })
    }
    func selectedRows(_ selection: Set<ArticleRowID>) -> [ArticleLibraryRow] {
        selection.compactMap { visibleByID[$0] }.sorted { $0.index < $1.index }.map(\.row)
    }
}

extension AppModel {
    var pendingArticleRows: [ArticleLibraryRow] {
        let entries = sourceReview.catalog.entries.filter { pendingAdds[$0.id] != nil }
        let listed = Set(entries.map(\.id))
        return entries.map { entry in
            ArticleLibraryRow(id: .retained(.preparation(entry.id)), title: entry.title, host: entry.url.host,
                savedAt: entry.addedAt, source: entry, jobs: [], preparationID: entry.id, retained: false)
        } + pendingAdds.keys.filter { !listed.contains($0) }.sorted().map { id in
            ArticleLibraryRow(id: .retained(.preparation(id)), title: pendingAdds[id]!, host: nil,
                savedAt: nil, source: nil, jobs: [], preparationID: id, retained: true)
        }
    }
    var queuedArticleRows: [ArticleLibraryRow] {
        let entries = Dictionary(sourceReview.catalog.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return queueItems.map { item in
            let entry = item.sourceEntryID.flatMap { entries[$0] }
            return ArticleLibraryRow(id: .retained(.episode(item.id)), title: item.title,
                host: item.sourceHost ?? entry?.url.host, savedAt: queueSavedDates[item.id] ?? entry?.addedAt, source: entry,
                jobs: [item], preparationID: nil,
                retained: entry == nil || !sourceReview.catalog.currentIDs.contains(entry!.id))
        } + pendingArticleRows
    }
    var allArticleRows: [ArticleLibraryRow] {
        let jobsBySource = Dictionary(grouping: queueItems, by: \.sourceEntryID)
        let duplicates = sourceReview.duplicateStatuses
        let complete = completedArticleSourceKeys
        let groupsWithAudio = Set(duplicates.groups.compactMap { id, group in
            sourceReview.articleSourceKeys[id].map(complete.contains) == true ? group : nil
        })
        var rows = sourceReview.catalog.entries.map { entry in
            ArticleLibraryRow(id: .source(entry.id), title: sourceReview.catalog.displayTitle(for: entry), host: entry.url.host,
                savedAt: entry.addedAt, source: entry,
                jobs: jobsBySource[entry.id] ?? [],
                preparationID: pendingAdds[entry.id] == nil ? nil : entry.id,
                retained: !sourceReview.catalog.currentIDs.contains(entry.id),
                inactiveDuplicate: duplicates.inactive.contains(entry.id),
                narrationComplete: sourceReview.articleSourceKeys[entry.id].map(complete.contains) == true,
                matchingAudioExists: duplicates.groups[entry.id].map(groupsWithAudio.contains) == true,
                preparationFailure: articlePreparationFailures[entry.id])
        }
        let catalogIDs = Set(sourceReview.catalog.entries.map(\.id))
        var retainedSources: [String: Int] = [:]
        for row in queuedArticleRows {
            if let sourceID = row.jobs.first?.sourceEntryID, catalogIDs.contains(sourceID) { continue }
            if let preparationID = row.preparationID, catalogIDs.contains(preparationID) { continue }
            if let sourceID = row.jobs.first?.sourceEntryID, let index = retainedSources[sourceID] {
                rows[index].jobs += row.jobs
            } else {
                if let sourceID = row.jobs.first?.sourceEntryID { retainedSources[sourceID] = rows.count }
                rows.append(row)
            }
        }
        return rows.enumerated().sorted { left, right in
            switch (left.element.savedAt, right.element.savedAt) {
            case let (l?, r?) where l != r: l > r
            case (_?, nil): true
            case (nil, _?): false
            default: left.offset < right.offset
            }
        }.map(\.element)
    }
    var unfilteredArticleRows: [ArticleLibraryRow] { allArticleRows }
    var articleWebsiteSelection: ArticleWebsiteFilter {
        get { articlesWebsiteFilter }
        set { articlesWebsiteFilter = newValue }
    }
    var articleWebsiteCounts: [ArticleWebsiteFilter: Int] { websiteCounts(for: unfilteredArticleRows) }
    func websiteCounts(for rows: [ArticleLibraryRow]) -> [ArticleWebsiteFilter: Int] {
        var counts: [ArticleWebsiteFilter: Int] = [.all: rows.count]
        let now = Date(), calendar = Calendar.current
        for filter in ArticleWebsiteFilter.dateOptions {
            counts[filter] = rows.filter { filter.includes($0, now: now, calendar: calendar) }.count
        }
        for row in rows {
            let key = ArticleWebsiteFilter.siteKey(row.host).map { ArticleWebsiteFilter.site($0) } ?? .unknown
            counts[key, default: 0] += 1
        }
        return counts
    }
    var articleWebsiteOptions: [ArticleWebsiteFilter] { websiteOptions(counts: articleWebsiteCounts) }
    func websiteOptions(counts: [ArticleWebsiteFilter: Int]) -> [ArticleWebsiteFilter] {
        var options = Set(counts.keys).subtracting([.all, .today, .thisWeek])
        // Retain an empty selected website, so refresh never silently widens the filter.
        if articleWebsiteSelection != .all && !articleWebsiteSelection.isDateFilter { options.insert(articleWebsiteSelection) }
        return [.all] + options.sorted { left, right in
            let leftCount = counts[left, default: 0], rightCount = counts[right, default: 0]
            if leftCount != rightCount { return leftCount > rightCount }
            let order = left.title.localizedCaseInsensitiveCompare(right.title)
            return order == .orderedSame ? left.title < right.title : order == .orderedAscending
        }
    }
    var articleSearchQuery: String {
        get { articlesNeedAttentionOnly ? articleAttentionSearchText : articlesSearchText }
        set {
            if articlesNeedAttentionOnly { articleAttentionSearchText = newValue }
            else { articlesSearchText = newValue }
        }
    }
    func articleJobNeedsAttention(_ job: SpeechQueueItem) -> Bool {
        switch job.state {
        case .failed, .paused: true
        case .running: !processingSpeech
        case .queued, .completed: false
        }
    }
    func articlesNeedingAttention(in rows: [ArticleLibraryRow]) -> [ArticleLibraryRow] {
        rows.filter { $0.preparationFailure != nil || $0.jobs.contains(where: articleJobNeedsAttention) }
    }
    func showArticlesNeedingAttention() {
        articleAttentionSearchText = ""
        articlesNeedAttentionOnly = true
    }
    func articleJobSummary(_ row: ArticleLibraryRow) -> String? {
        guard row.jobs.count > 1 else { return nil }
        let failures = row.jobs.filter(articleJobNeedsAttention).count
        return "\(row.jobs.count) queue entries\(failures > 0 ? " · \(failures) need retry" : "")"
    }
    var visibleArticleRows: [ArticleLibraryRow] { visibleArticleRows(in: unfilteredArticleRows) }
    func visibleArticleRows(in rows: [ArticleLibraryRow]) -> [ArticleLibraryRow] {
        let candidates = articlesNeedAttentionOnly
            ? articlesNeedingAttention(in: rows)
            : rows.filter { articleWebsiteSelection.includes($0) }
        return matchingArticleSearch(in: candidates)
    }
    func matchingArticleSearch(in rows: [ArticleLibraryRow]) -> [ArticleLibraryRow] {
        let query = articleSearchQuery
        return rows.filter { matchesArticleSearch($0, query: query) }
    }
    func matchesArticleSearch(_ row: ArticleLibraryRow, query: String) -> Bool {
        guard LibraryTextSearch.isSearching(query) else { return true }
        let origin = ArticleOriginMetadata(host: row.host, savedAt: row.savedAt)
        var fields: [String?] = [row.title, row.host,
            origin.savedDateText, origin.displayText(),
            row.retained ? "Retained; absent from Reading List" : nil, articleJobSummary(row),
            row.preparationID != nil ? "Preparing" : nil, row.preparationFailure,
            row.narrationComplete ? "Narration Complete" : row.matchingAudioExists ? "Matching audio exists" : nil]
        for job in row.jobs {
            fields.append(articleJobStatus(job))
            if let message = job.lastError, notices.isVisible(message: message, key: "queue:\(job.id):\(job.attempts):\(job.state)") { fields.append(message) }
        }
        return LibraryTextSearch.matches(query, fields: fields)
    }
    func articleJobStatus(_ job: SpeechQueueItem) -> String {
        switch job.state {
        case .queued: "Ready"
        case .failed, .paused: "Needs retry"
        case .running: processingSpeech ? "Processing audio" : "Interrupted; retry required"
        case .completed: "Audio generated; verifying"
        }
    }
    var unifiedArticleSelection: Set<ArticleRowID> {
        get {
            return articleListSelection.intersection(Set(allArticleRows.map(\.id)))
        }
        set {
            articleSelection = Set(newValue.compactMap { if case .source(let id) = $0 { id } else { nil } })
            retainedArticleSelection = Set(newValue.compactMap { if case .retained(let id) = $0 { id } else { nil } })
        }
    }
    /// Reading the native List binding must never sort or filter the library.
    var articleListSelection: Set<ArticleRowID> {
        return Set(articleSelection.map { ArticleRowID.source($0) })
            .union(retainedArticleSelection.map { .retained($0) })
    }
    var selectedUnifiedRows: [ArticleLibraryRow] {
        let selection = unifiedArticleSelection
        return visibleArticleRows.filter { selection.contains($0.id) }
    }
    var selectedUnifiedQueueIDs: Set<QueueSelectionID> {
        Set(selectedUnifiedRows.flatMap { row in
            row.jobs.map { QueueSelectionID.episode($0.id) }
                + (row.preparationID.map { [QueueSelectionID.preparation($0)] } ?? [])
        })
    }
    func canRemoveQueueIDs(_ ids: Set<QueueSelectionID>) -> Bool {
        !ids.isEmpty && !preview && !stopping && !libraryMaintenanceBusy && !libraryReviewRequired
            && !sourceReview.maintenanceSuspended
            && !ids.contains { mutatingQueueEntries.contains($0) }
            && !queueItems.contains { processingSpeech && $0.state == .running && ids.contains(.episode($0.id)) }
    }
    var canRemoveUnifiedSelection: Bool { !queueMutationBusy && canRemoveQueueIDs(selectedUnifiedQueueIDs) }
    func removeUnifiedSelection() {
        let ids = selectedUnifiedQueueIDs
        guard !queueMutationBusy, canRemoveQueueIDs(ids) else { return }
        let previous = queueSelection
        queueSelection = ids
        removeSelectedQueueItems()
        queueSelection = previous.subtracting(ids)
    }
    func previewArticleRow(_ row: ArticleLibraryRow, openWindow: OpenWindowAction) {
        if let item = row.jobs.first { previewQueueItem(item, openWindow: openWindow) }
        else if let entry = row.source {
            previewProfiles[entry.url] = nil
            previewReviews[entry.url] = nil
            previewSourceTitles[entry.url] = entry.title
            ArticlePreviewNavigation.open(entry.url, using: openWindow, inert: preview)
        }
    }
    var canPreviewUnifiedSelection: Bool {
        canPreviewArticleRows(selectedUnifiedRows)
    }
    func canPreviewArticleRows(_ rows: [ArticleLibraryRow]) -> Bool {
        !preview && !stopping && !libraryMaintenanceBusy && rows.count == 1
            && (rows[0].source != nil || !rows[0].jobs.isEmpty)
    }
    func previewUnifiedSelection(openWindow: OpenWindowAction) {
        guard canPreviewUnifiedSelection, let row = selectedUnifiedRows.first else { return }
        previewArticleRow(row, openWindow: openWindow)
    }
    func transferPreparationSelection(sourceID: String, episodeID: String) {
        if queueSelection.remove(.preparation(sourceID)) != nil { queueSelection.insert(.episode(episodeID)) }
        if retainedArticleSelection.remove(.preparation(sourceID)) != nil { retainedArticleSelection.insert(.episode(episodeID)) }
    }
}

struct LibraryListActions {
    var canPreview: Bool = false
    var canRemove: Bool = false
    var preview: () -> Void = {}
    var remove: () -> Void = {}
}
private struct LibraryListActionsKey: FocusedValueKey { typealias Value = LibraryListActions }
extension FocusedValues {
    var libraryListActions: LibraryListActions? {
        get { self[LibraryListActionsKey.self] }
        set { self[LibraryListActionsKey.self] = newValue }
    }
}

struct ArticlesView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        let rows = model.unfilteredArticleRows
        let attentionRows = model.articlesNeedingAttention(in: rows)
        let visibleRows = model.articlesNeedAttentionOnly
            ? model.matchingArticleSearch(in: attentionRows)
            : model.visibleArticleRows(in: rows)
        let projection = ArticleListProjection(rows: rows, visibleRows: visibleRows)
        VStack(spacing: 0) {
            HStack {
                let websiteCounts = model.websiteCounts(for: rows)
                Picker("Filter", selection: $model.articleWebsiteSelection) {
                    ForEach(ArticleWebsiteFilter.dateOptions) { filter in
                        Text("\(filter.title) (\(websiteCounts[filter, default: 0]))").tag(filter)
                    }
                    Divider()
                    ForEach(model.websiteOptions(counts: websiteCounts)) { filter in
                        Text("\(filter.title) (\(websiteCounts[filter, default: 0]))").tag(filter)
                    }
                }.pickerStyle(.menu).frame(maxWidth: 260).disabled(model.articlesNeedAttentionOnly)
                    .help("Filter by saved date or website")
                Spacer(minLength: 12)
            }.padding(12)
            Divider()
            WorkspaceReadinessView(model: model)
            if model.sourceReview.synchronizing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking Reading List…")
                    Spacer()
                }.padding([.horizontal, .top])
            }
            sourceNotices
            if model.articlesNeedAttentionOnly || !attentionRows.isEmpty {
                HStack(spacing: 12) {
                    if model.articlesNeedAttentionOnly {
                        Label("Needs Attention (\(attentionRows.count))", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Show All Articles") { model.articlesNeedAttentionOnly = false }
                    } else {
                        Button {
                            model.showArticlesNeedingAttention()
                        } label: {
                            Label("Needs Attention (\(attentionRows.count))", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Color.orange)
                        }.help("Show articles that need a retry")
                        Spacer()
                    }
                }.padding(.horizontal, 12).padding(.vertical, 8)
            }
            ArticleSelectionList(model: model, projection: projection)
                .overlay { if projection.visibleRows.isEmpty { emptyContent(hasAttention: !attentionRows.isEmpty) } }
        }
        .searchable(text: $model.articleSearchQuery, placement: .toolbar, prompt: "Search Articles")
    }
    @ViewBuilder private var sourceNotices: some View {
        if let error = model.sourceReview.error, model.notices.isVisible(message: error, key: "source") {
            InlineNotice(message: error) { model.notices.dismiss(message: error, key: "source") }
                .padding([.horizontal, .top])
        }
    }
    @ViewBuilder private func emptyContent(hasAttention: Bool) -> some View {
        if model.articlesNeedAttentionOnly {
            if hasAttention {
                ContentUnavailableView {
                    Label("No Matching Articles", systemImage: "magnifyingglass")
                } actions: {
                    Button("Clear Search") { model.articleSearchQuery = "" }
                }
            } else {
                ContentUnavailableView("No Articles Need Attention", systemImage: "checkmark.circle")
            }
        } else {
            regularEmptyContent
        }
    }
    private var regularEmptyContent: some View {
        ContentUnavailableView {
            Label(model.articleWebsiteSelection != .all || LibraryTextSearch.isSearching(model.articleSearchQuery) ? "No Matching Articles" : "No Articles", systemImage: "doc.text")
        } description: {
            Text(LibraryTextSearch.isSearching(model.articleSearchQuery) ? "Try another search or filter." : model.articleWebsiteSelection.isDateFilter ? "No articles were saved in this period." : model.articleWebsiteSelection != .all ? "No items match this website."
                 : model.sourceReview.plist != nil ? "No articles found in the selected Reading List."
                 : "Choose a Reading List source in General. VoiceRelay checks it automatically while running.")
        } actions: {
            if LibraryTextSearch.isSearching(model.articleSearchQuery) {
                Button("Clear Search") { model.articleSearchQuery = "" }
            }
            if model.articleWebsiteSelection != .all {
                Button(model.articleWebsiteSelection.isDateFilter ? "Show All Articles" : "Show All Websites") { model.articleWebsiteSelection = .all }
            } else {
                Button("Open General") { showSettings(.general) }.disabled(model.preview)
            }
        }
    }
    private func showSettings(_ section: SettingsSection) {
        model.settingsSection = section
        WindowPresence.shared.prepareToOpen(); openSettings()
    }
}

/// Selection-dependent actions live below the content projection's observation
/// boundary. A click updates native highlighting and these controls only.
struct ArticleSelectionList: View {
    @Bindable var model: AppModel
    let projection: ArticleListProjection
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var renamingArticle: SpeechQueueItem?
    @State private var titleDraft = ""

    var body: some View {
        let selected = projection.selectedRows(model.articleListSelection)
        let canPreview = model.canPreviewArticleRows(selected)
        let queueIDs = Set(selected.flatMap { row in
            row.jobs.map { QueueSelectionID.episode($0.id) }
                + (row.preparationID.map { [QueueSelectionID.preparation($0)] } ?? [])
        })
        let canRemove = !model.queueMutationBusy && model.canRemoveQueueIDs(queueIDs)
        List(selection: Binding(
            get: { model.articleListSelection.intersection(projection.rowIDs) },
            set: { model.unifiedArticleSelection = $0 })) {
            ForEach(projection.visibleRows) { row in
                ArticleLibraryRowView(model: model, row: row).tag(row.id)
            }
        }
        .contextMenu(forSelectionType: ArticleRowID.self) { ids in
            let rows = projection.selectedRows(ids)
            Button("Preview Article") {
                if let row = rows.first { model.previewArticleRow(row, openWindow: openWindow) }
            }.disabled(!model.canPreviewArticleRows(rows))
            if rows.count == 1, let item = rows.first?.jobs.first {
                Button("Edit Title…") { titleDraft = item.title; renamingArticle = item }
                    .disabled(!model.canRenameArticle(item))
            }
        } primaryAction: { ids in
            let rows = projection.selectedRows(ids)
            if model.canPreviewArticleRows(rows), let row = rows.first {
                model.previewArticleRow(row, openWindow: openWindow)
            }
        }
        .refreshable { await model.sourceReview.refreshSource() }
        .onDeleteCommand { model.removeUnifiedSelection() }
        .focusedValue(\.libraryListActions, LibraryListActions(
            canPreview: canPreview, canRemove: canRemove,
            preview: { model.previewUnifiedSelection(openWindow: openWindow) },
            remove: { model.removeUnifiedSelection() }))
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    Button("Preview Article") { model.previewUnifiedSelection(openWindow: openWindow) }
                        .disabled(!canPreview)
                    Divider()
                    Button("Publishing Settings…") { showSettings(.delivery) }
                    Button("Settings…") { showSettings(.general) }
                } label: { Label("Actions", systemImage: "ellipsis") }
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) { GenerateAudioControl(model: model) }
        }
        .alert("Edit article title", isPresented: Binding(get: { renamingArticle != nil }, set: { if !$0 { renamingArticle = nil } })) {
            TextField("Title", text: $titleDraft)
            Button("Save") {
                if let item = renamingArticle { model.renameArticle(item, title: titleDraft) }
                renamingArticle = nil
            }.disabled(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || titleDraft.count > 240
                || renamingArticle.map { !model.canRenameArticle($0) } ?? true)
            Button("Cancel", role: .cancel) { renamingArticle = nil }
        } message: { Text("Updates this queued article and its spoken introduction. Available before audio generation begins.") }
    }
    private func showSettings(_ section: SettingsSection) {
        model.settingsSection = section
        WindowPresence.shared.prepareToOpen(); openSettings()
    }
}

struct ArticleLibraryRowView: View {
    @Bindable var model: AppModel
    let row: ArticleLibraryRow
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).appFont(.headline).lineLimit(2)
                    .foregroundStyle(row.inactiveDuplicate ? Color.secondary : Color.primary)
                if row.inactiveDuplicate { Text("Inactive duplicate").appFont(.secondary).foregroundStyle(.secondary) }
                ArticleOriginLine(metadata: ArticleOriginMetadata(host: row.host, savedAt: row.savedAt))
                if row.retained { Text("Retained; absent from Reading List").appFont(.secondary).foregroundStyle(.secondary) }
                if let summary = model.articleJobSummary(row) {
                    Label { Text(summary) } icon: {
                        LibraryRowSymbol(systemName: row.jobs.contains(where: model.articleJobNeedsAttention) ? "exclamationmark.triangle" : "list.bullet")
                    }.appFont(.secondary).foregroundStyle(.secondary)
                } else if let job = row.jobs.first {
                    Label { Text(model.articleJobStatus(job)) } icon: { LibraryRowSymbol(systemName: symbol(job)) }
                        .appFont(.secondary).foregroundStyle(model.articleJobNeedsAttention(job) ? Color.orange : Color.secondary)
                }
                ForEach(row.jobs) { job in
                    if let message = job.lastError,
                       model.notices.isVisible(message: message, key: "queue:\(job.id):\(job.attempts):\(job.state)") {
                        InlineNotice(message: message) {
                            model.notices.dismiss(message: message, key: "queue:\(job.id):\(job.attempts):\(job.state)")
                        }
                    }
                }
                if let failure = row.preparationFailure {
                    Label { Text(failure) } icon: { LibraryRowSymbol(systemName: "exclamationmark.triangle") }
                        .appFont(.secondary).foregroundStyle(Color.orange)
                }
                if row.preparationID != nil {
                    Label { Text("Preparing…") } icon: { LibraryRowSymbol(systemName: "clock") }
                        .appFont(.secondary).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            LibraryRowActions {
                if row.preparationID == nil, row.jobs.isEmpty, !row.narrationComplete, !row.matchingAudioExists,
                   !row.inactiveDuplicate, !row.retained, row.source != nil,
                   row.preparationFailure == nil, !model.deliveryServerChecked {
                    LibraryRowSymbol(systemName: "clock").foregroundStyle(.secondary)
                        .help("Waiting for Publishing Check").accessibilityLabel("Waiting for Publishing Check")
                }
                if let entry = row.source, let failure = row.preparationFailure {
                    Button { model.retryArticlePreparation(entry) } label: {
                        LibraryRowSymbol(systemName: "arrow.clockwise").foregroundStyle(.orange)
                    }.buttonStyle(.borderless).disabled(!model.canAddArticles([entry]))
                        .help("Retry Preparation").accessibilityLabel("Retry Preparation for \(row.title)").accessibilityHint(failure)
                }
                if row.narrationComplete {
                    LibraryRowSymbol(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green).help("Narration Complete").accessibilityLabel("Narration Complete")
                } else if row.matchingAudioExists {
                    LibraryRowSymbol(systemName: "checkmark.circle").foregroundStyle(.green)
                        .help("Matching Audio Exists").accessibilityLabel("Matching Audio Exists")
                }
                if row.offersReprocessing {
                    Button { model.reprocessArticle(row) } label: {
                        LibraryRowSymbol(systemName: "arrow.clockwise").foregroundStyle(.blue)
                    }.buttonStyle(.borderless).disabled(!model.canReprocessArticle(row))
                        .help("Re-process Audio").accessibilityLabel("Re-process Audio for \(row.title)")
                }
                ForEach(row.jobs) { job in
                    jobActions(job)
                }
                if let id = row.preparationID {
                    RowRemovalButton(accessibilityLabel: "Remove \(row.title) preparation", help: "Cancel preparation; keep Reading List entry",
                        isEnabled: model.canRemoveQueueIDs([.preparation(id)])) { model.removePreparation(id) }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }
    @ViewBuilder private func jobActions(_ job: SpeechQueueItem) -> some View {
        let current = job.state == .running && model.processingSpeech
        let mutating = model.mutatingQueueEntries.contains(.episode(job.id))
        if model.articleJobNeedsAttention(job) {
            Button("Retry") { model.changeQueue(job.id, remove: false) }
                .disabled(model.preview || model.stopping || model.libraryReviewRequired || current || mutating)
                .help("Return article to Ready")
        }
        RowRemovalButton(accessibilityLabel: "Remove \(row.title) from Queue",
            help: current ? "Stop generating audio first" : "Remove queue membership; Reading List and saved text are kept",
            isEnabled: model.canRemoveQueueIDs([.episode(job.id)])) { model.changeQueue(job.id, remove: true) }
    }
    private func symbol(_ job: SpeechQueueItem) -> String {
        switch job.state {
        case .queued, .completed: "clock"
        case .failed, .paused: "exclamationmark.triangle"
        case .running: "play.circle"
        }
    }
}

#if DEBUG
@MainActor private func sourcePreview() -> SourceReviewModel {
    let model = SourceReviewModel(preview: true)
    let url = URL(string: "https://articles.example/synthetic")!
    let entry = ReadingListEntry(id: "synthetic", safariID: "synthetic", url: url, title: "Reading carefully — Café 日本語", addedAt: nil)
    model.catalog.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0))
    model.status = "Synthetic source review — no file or network actions"
    return model
}
private func syntheticReview(issue: SourceReviewIssue? = nil) -> ReviewedSource? {
    let url = URL(string: "https://articles.example/synthetic")!
    let html = "<html><title>Reading carefully</title><article><h1>Reading carefully</h1><p>" + String(repeating: "A synthetic article keeps previews private and preserves its original wording. ", count: 8) + "</p></article></html>"
    let page = FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html, contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
    if let issue { return ReviewedSource(page: page, document: nil, narration: nil, issue: issue) }
    return try? ReviewedSource.prepare(page, chunkLimit: 1800)
}
#Preview("Troubleshooting — delivery debug logging") {
    let model = AppModel(preview: true)
    model.debugLoggingEnabled = true
    return TroubleshootingView(model: model)
}
#Preview("Article preview — synthetic article") {
    ArticlePreviewView(url: URL(string: "https://articles.example/synthetic")!, inert: true, review: syntheticReview())
}
#Preview("Article preview — synthetic consent page") {
    ArticlePreviewView(url: URL(string: "https://articles.example/synthetic")!, inert: true, review: syntheticReview(issue: .consent))
}
#Preview("Articles — website filter") {
    let model = AppModel(preview: true)
    let entries = ["https://www.news.example/one", "http://news.example/two", "https://other.example/three"].enumerated().map { index, url in
        ReadingListEntry(id: String(index), safariID: String(index), url: URL(string: url)!,
            title: "Synthetic article \(index + 1)", addedAt: Date(timeIntervalSinceReferenceDate: Double(index)))
    }
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: entries, skippedEntries: 0))
    model.articlesWebsiteFilter = .site("news.example")
    return ArticlesView(model: model)
}
#Preview("Articles — inert multi-selection") {
    let model = AppModel(preview: true)
    let entries = ["one", "two"].enumerated().map { index, id in
        ReadingListEntry(id: id, safariID: id, url: URL(string: "https://articles.example/\(id)")!,
                         title: "Synthetic article \(id)", addedAt: Date(timeIntervalSinceReferenceDate: Double(index + 1) * 86_400))
    }
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: entries, skippedEntries: 0))
    model.articleSelection = Set(entries.map(\.id))
    return ArticlesView(model: model)
}
#Preview("Queue — inert waiting and interrupted") {
    let model = AppModel(preview: true)
    model.queueItems = [SpeechQueueItem(id: "00000000-0000-0000-0000-000000000001", title: "A synthetic queued article"),
                       SpeechQueueItem(id: "00000000-0000-0000-0000-000000000002", title: "A synthetic interrupted article", state: .running, attempts: 1)]
    return ArticlesView(model: model)
}
#Preview("Queue — global encoding progress") {
    let model = AppModel(preview: true)
    model.batchProgress = QueueBatchProgress(stage: .encoding, completedChunks: 5, totalChunks: 12, completedArticles: 0, totalArticles: 2)
    return ArticlesView(model: model)
}
#endif

#if DEBUG
#Preview("Articles — accessibility text, inert") {
    ArticlesView(model: AppModel(preview: true)).appTextSizing(AppTextSize())
        .dynamicTypeSize(.accessibility3).frame(width: 980, height: 640)
}
#endif
