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
    var catalog = ReadingListCatalog()
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
            let result = try await withTaskCancellationHandler { try await readTask.value } onCancel: { readTask.cancel() }
            try Task.checkCancellation()
            guard !stopping, !maintenanceSuspended, generation == sourceGeneration, plist == file else { return true }
            let current = try await coordinator.catalog(stateRoot: stateRoot)
            try Task.checkCancellation()
            guard !stopping, !maintenanceSuspended, generation == sourceGeneration, plist == file else { return true }
            var proposed = current
            proposed.reconcile(result); proposed.excludedIDs = []
            let removed = current.entries.filter { !proposed.currentIDs.contains($0.id) }
            if proposed.entries != current.entries || proposed.currentIDs != current.currentIDs {
                let saved = try await coordinator.reconcile(result, stateRoot: stateRoot)
                guard generation == sourceGeneration, plist == file else { return true }
                // Once committed, inventory reflects the saved result even if article selection changed.
                catalog = saved; onCatalogChange(removed)
            } else { catalog = proposed }
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
    func load(_ url: URL, profile: PrototypeProfile? = nil, settings: SpeechSettings = .init(), options: NarrationOptions = .init(), sourceTitle: String? = nil) {
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
                    let dictionary = try PronunciationStore().load().dictionary
                    return try await ArticleSourceLoader(limits: limits, useArchives: archives,
                        describeImages: descriptions, speechSettings: capturedSettings, pronunciations: dictionary, narrationOptions: capturedOptions,
                        sourceTitle: sourceTitle, generateMissingTitles: generateTitles).load(url, chunkLimit: limit)
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
    func showSaved(_ saved: ReviewedSource, profile: PrototypeProfile? = nil, settings: SpeechSettings = .init(), options: NarrationOptions = .init()) async {
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
            try Task.checkCancellation()
            let dictionary = try PronunciationStore().load().dictionary
            return try Narration.prepare(document.article, limit: profile?.chunkMaxCharacters ?? 1800,
                pronunciations: dictionary, settings: capturedSettings, options: capturedOptions)
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
                    Text("Archived copy · \(copy.provider.label) · \(copy.capturedAt.formatted(date: .abbreviated, time: .omitted))")
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
    let url: URL
    let settings: SpeechSettings
    let profile: PrototypeProfile?
    let options: NarrationOptions
    let savedReview: ReviewedSource?
    let sourceTitle: String?
    @State private var model: ArticlePreviewModel
    @Environment(\.dismiss) private var dismiss
    init(url: URL, inert: Bool = false, review: ReviewedSource? = nil, settings: SpeechSettings = .init(), profile: PrototypeProfile? = nil, options: NarrationOptions = .init(), sourceTitle: String? = nil) {
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
            if let savedReview { await model.showSaved(savedReview, profile: profile, settings: settings, options: options) }
            else { model.load(url, profile: profile, settings: settings, options: options, sourceTitle: sourceTitle) }
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

enum ArticleScope: String, CaseIterable, Identifiable {
    case all = "All Articles", queue = "Queue"
    var id: Self { self }
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
    var queueSummary: String? {
        guard jobs.count > 1 else { return nil }
        let failures = jobs.filter { $0.state == .failed || $0.state == .paused }.count
        return "\(jobs.count) queue entries\(failures > 0 ? " · \(failures) need retry" : "")"
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
        var rows = sourceReview.catalog.entries.map { entry in
            ArticleLibraryRow(id: .source(entry.id), title: sourceReview.catalog.displayTitle(for: entry), host: entry.url.host,
                savedAt: entry.addedAt, source: entry,
                jobs: jobsBySource[entry.id] ?? [],
                preparationID: pendingAdds[entry.id] == nil ? nil : entry.id,
                retained: !sourceReview.catalog.currentIDs.contains(entry.id))
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
    var unfilteredArticleRows: [ArticleLibraryRow] { articleScope == .all ? allArticleRows : queuedArticleRows }
    var articleWebsiteSelection: ArticleWebsiteFilter {
        get { articleScope == .all ? articlesWebsiteFilter : queueWebsiteFilter }
        set { if articleScope == .all { articlesWebsiteFilter = newValue } else { queueWebsiteFilter = newValue } }
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
        get { articleScope == .all ? articlesSearchText : queueSearchText }
        set { if articleScope == .all { articlesSearchText = newValue } else { queueSearchText = newValue } }
    }
    var visibleArticleRows: [ArticleLibraryRow] { visibleArticleRows(in: unfilteredArticleRows) }
    func visibleArticleRows(in rows: [ArticleLibraryRow]) -> [ArticleLibraryRow] {
        rows.filter { articleWebsiteSelection.includes($0) && matchesArticleSearch($0, query: articleSearchQuery) }
    }
    func matchesArticleSearch(_ row: ArticleLibraryRow, query: String) -> Bool {
        guard LibraryTextSearch.isSearching(query) else { return true }
        var fields: [String?] = [row.title, row.host,
            ArticleOriginMetadata(host: row.host, savedAt: row.savedAt).savedDateText,
            row.retained ? "Retained; absent from Reading List" : nil, row.queueSummary,
            row.preparationID != nil ? "Preparing" : nil]
        if row.jobs.count == 1, let job = row.jobs.first {
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
            if articleScope == .queue { return articleListSelection }
            return articleListSelection.intersection(Set(allArticleRows.map(\.id)))
        }
        set {
            if articleScope == .queue {
                queueSelection = Set(newValue.compactMap { if case .retained(let id) = $0 { id } else { nil } })
            } else {
                articleSelection = Set(newValue.compactMap { if case .source(let id) = $0 { id } else { nil } })
                retainedArticleSelection = Set(newValue.compactMap { if case .retained(let id) = $0 { id } else { nil } })
            }
        }
    }
    /// Reading the native List binding must never sort or filter the library.
    var articleListSelection: Set<ArticleRowID> {
        if articleScope == .queue { return Set(queueSelection.map { .retained($0) }) }
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
        if articleScope == .all { queueSelection = previous.subtracting(ids) }
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
    var canAdd: Bool = false
    var canRemove: Bool = false
    var preview: () -> Void = {}
    var add: () -> Void = {}
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
        let projection = ArticleListProjection(rows: rows, visibleRows: model.visibleArticleRows(in: rows))
        VStack(spacing: 0) {
            HStack {
                Picker("Articles scope", selection: $model.articleScope) {
                    Text("All Articles").tag(ArticleScope.all)
                    Text("Queue (\(model.queueItems.count + model.pendingAdds.count))").tag(ArticleScope.queue)
                }.pickerStyle(.segmented).frame(maxWidth: 292)
                Spacer(minLength: 12)
                let websiteCounts = model.websiteCounts(for: rows)
                Picker("Filter", selection: $model.articleWebsiteSelection) {
                    ForEach(ArticleWebsiteFilter.dateOptions) { filter in
                        Text("\(filter.title) (\(websiteCounts[filter, default: 0]))").tag(filter)
                    }
                    Divider()
                    ForEach(model.websiteOptions(counts: websiteCounts)) { filter in
                        Text("\(filter.title) (\(websiteCounts[filter, default: 0]))").tag(filter)
                    }
                }.pickerStyle(.menu).frame(maxWidth: 260)
                    .help("Filter by saved date or website")
                Text(model.articleScope == .all ? "Newest saved first" : "Processing order")
                    .appFont(.secondary).foregroundStyle(.secondary)
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
            ArticleSelectionList(model: model, projection: projection)
                .overlay { if projection.visibleRows.isEmpty { emptyContent } }
        }
        .searchable(text: $model.articleSearchQuery, placement: .toolbar, prompt: "Search Articles")
        .onAppear {
            model.sourceReview.loadCatalog()
            model.sourceReview.requestSourceSync()
            model.sourceReview.startAutomaticSynchronization()
            model.refreshLibrary()
        }
    }
    @ViewBuilder private var sourceNotices: some View {
        if let error = model.sourceReview.error, model.notices.isVisible(message: error, key: "source") {
            InlineNotice(message: error) { model.notices.dismiss(message: error, key: "source") }
                .padding([.horizontal, .top])
        }
        ForEach(model.enqueueIssues, id: \.self) { issue in
            if model.notices.isVisible(message: issue, key: "enqueue") {
                InlineNotice(message: issue) { model.notices.dismiss(message: issue, key: "enqueue") }
                    .padding([.horizontal, .top])
            }
        }
    }
    private var emptyContent: some View {
        ContentUnavailableView {
            Label(model.articleWebsiteSelection != .all || LibraryTextSearch.isSearching(model.articleSearchQuery) ? "No Matching Articles" : model.articleScope == .queue ? "Queue Is Empty" : "No Articles", systemImage: "doc.text")
        } description: {
            Text(LibraryTextSearch.isSearching(model.articleSearchQuery) ? "Try another search or filter." : model.articleWebsiteSelection.isDateFilter ? "No articles were saved in this period." : model.articleWebsiteSelection != .all ? "No items match this website in the current scope." : model.articleScope == .queue ? "Add articles from All Articles, or let automatic processing admit new entries."
                 : model.sourceReview.plist != nil ? "No articles found in the selected Reading List."
                 : "Choose a Reading List source in General. VoiceRelay checks it automatically while running.")
        } actions: {
            if LibraryTextSearch.isSearching(model.articleSearchQuery) {
                Button("Clear Search") { model.articleSearchQuery = "" }
            }
            if model.articleWebsiteSelection != .all {
                Button(model.articleWebsiteSelection.isDateFilter ? "Show All Articles" : "Show All Websites") { model.articleWebsiteSelection = .all }
            } else if model.articleScope == .queue {
                Button("Go to All Articles") { model.articleScope = .all }
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
    @State private var confirmingReset = false
    @State private var renamingArticle: SpeechQueueItem?
    @State private var titleDraft = ""

    var body: some View {
        let selected = projection.selectedRows(model.articleListSelection)
        let eligible = selected.filter { $0.jobs.isEmpty && $0.preparationID == nil }.compactMap(\.source)
        let canAdd = model.articleScope == .all && model.canAddArticles(eligible)
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
            canPreview: canPreview, canAdd: canAdd, canRemove: canRemove,
            preview: { model.previewUnifiedSelection(openWindow: openWindow) },
            add: { model.addSelectedToQueue() }, remove: { model.removeUnifiedSelection() }))
        .toolbar {
            if model.articleScope == .all {
                ToolbarItem {
                    Button { model.addSelectedToQueue() } label: {
                        Label("Add to Queue (\(eligible.count))", systemImage: "plus")
                    }.disabled(!canAdd)
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    Button("Preview Article") { model.previewUnifiedSelection(openWindow: openWindow) }
                        .disabled(!canPreview)
                    if model.articleScope == .queue {
                        SelectionManagementControl(selectionCount: queueIDs.count,
                            resetTitle: "Reset Queue…", canReset: model.canResetQueue,
                            canRemove: canRemove,
                            resetHelp: "Clear Queue; keep articles and audio",
                            removeHelp: "Remove from Queue; keep text and audio",
                            onReset: { confirmingReset = true }, onRemove: { model.removeUnifiedSelection() })
                    }
                    Divider()
                    Button("Publishing Settings…") { showSettings(.delivery) }
                    Button("Settings…") { showSettings(.general) }
                } label: { Label("Actions", systemImage: "ellipsis") }
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) { GenerateAudioControl(model: model) }
        }
        .confirmationDialog("Reset queue?", isPresented: $confirmingReset) {
            Button("Reset Queue", role: .destructive) { model.resetQueue() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove all queued items? Reading List entries, saved article text and existing audio files will be kept.")
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).appFont(.headline).lineLimit(2)
                ArticleOriginLine(metadata: ArticleOriginMetadata(host: row.host, savedAt: row.savedAt))
                if row.retained { Text("Retained; absent from Reading List").appFont(.secondary).foregroundStyle(.secondary) }
                if row.jobs.count > 1 {
                    let failures = row.jobs.filter { $0.state == .failed || $0.state == .paused }.count
                    Label(row.queueSummary ?? "", systemImage: failures > 0 ? "exclamationmark.triangle" : "list.bullet")
                        .appFont(.secondary).foregroundStyle(.secondary)
                } else if let job = row.jobs.first {
                    Label(model.articleJobStatus(job), systemImage: symbol(job))
                        .appFont(.secondary).foregroundStyle(job.state == .failed ? Color.orange : Color.secondary)
                    if let message = job.lastError,
                       model.notices.isVisible(message: message, key: "queue:\(job.id):\(job.attempts):\(job.state)") {
                        InlineNotice(message: message) {
                            model.notices.dismiss(message: message, key: "queue:\(job.id):\(job.attempts):\(job.state)")
                        }
                    }
                }
                if row.preparationID != nil {
                    Label("Preparing…", systemImage: "clock").appFont(.secondary).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if row.jobs.count > 1 {
                Button("Show Queue") { model.articleScope = .queue }
            } else if let job = row.jobs.first {
                jobActions(job)
            } else if let id = row.preparationID {
                RowRemovalButton(accessibilityLabel: "Remove \(row.title) preparation", help: "Cancel preparation; keep Reading List entry",
                    isEnabled: model.canRemoveQueueIDs([.preparation(id)])) { model.removePreparation(id) }
            }
        }
    }
    @ViewBuilder private func jobActions(_ job: SpeechQueueItem) -> some View {
        let current = job.state == .running && model.processingSpeech
        let mutating = model.mutatingQueueEntries.contains(.episode(job.id))
        if [.paused, .failed, .running].contains(job.state) {
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
        case .queued, .completed: "checkmark.circle"
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
    model.articleScope = .queue
    return ArticlesView(model: model)
}
#Preview("Queue — global encoding progress") {
    let model = AppModel(preview: true)
    model.batchProgress = QueueBatchProgress(stage: .encoding, completedChunks: 5, totalChunks: 12, completedArticles: 0, totalArticles: 2)
    model.articleScope = .queue
    return ArticlesView(model: model)
}
#endif

#if DEBUG
#Preview("Articles — accessibility text, inert") {
    ArticlesView(model: AppModel(preview: true)).appTextSizing(AppTextSize())
        .dynamicTypeSize(.accessibility3).frame(width: 980, height: 640)
}
#endif
