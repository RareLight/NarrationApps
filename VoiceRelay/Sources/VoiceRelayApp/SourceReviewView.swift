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
    var persistenceBusy = false
    var preview = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private let coordinator: FixtureCoordinator
    @ObservationIgnored private var catalogLoaded = false
    @ObservationIgnored private var stopping = false
    @ObservationIgnored var onCatalogChange: () -> Void = {}
    @ObservationIgnored var onContextChange: () -> Void = {}
    @ObservationIgnored private let stateRootOverride: URL?
    @ObservationIgnored private let snapshotReader: @Sendable (URL) async throws -> ReadingListSnapshot
    @ObservationIgnored private var autoSyncTask: Task<Void, Never>?
    @ObservationIgnored private var immediateSyncTask: Task<Void, Never>?
    @ObservationIgnored private var sourceReadTask: Task<ReadingListSnapshot, Error>?
    @ObservationIgnored private var autoReading = false
    @ObservationIgnored private var syncRequested = false
    @ObservationIgnored private var sourceGeneration = 0
    static let syncInterval: Duration = .seconds(30)
    private var stateRoot: URL { stateRootOverride ?? AppStorage.managedLibrary }

    init(preview: Bool = false, coordinator: FixtureCoordinator = FixtureCoordinator(),
         stateRoot: URL? = nil, plist: URL? = nil,
         snapshotReader: (@Sendable (URL) async throws -> ReadingListSnapshot)? = nil) {
        self.coordinator = coordinator
        self.preview = preview
        stateRootOverride = stateRoot
        self.snapshotReader = snapshotReader ?? { url in
            let child = Task.detached { try ReadingList.read(url) }
            return try await withTaskCancellationHandler { try await child.value } onCancel: { child.cancel() }
        }
        if let plist { self.plist = plist }
        else if !preview, stateRoot == nil,
                let path = UserDefaults.standard.string(forKey: "readingListSource") {
            self.plist = URL(fileURLWithPath: path)
        }
    }
    func loadCatalog() {
        guard !preview, !busy, !catalogLoaded, !stopping else { return }
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

    func selectPlist() {
        guard !preview, !busy, !persistenceBusy, !stopping else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "Choose a Reading List property-list file (read-only)"
        if panel.runModal() == .OK, let url = panel.url { setSource(url) }
    }
    func setSource(_ url: URL) {
        guard !preview, !stopping else { return }
        guard url != plist else { onContextChange(); requestSourceSync(); return }
        sourceGeneration += 1
        sourceReadTask?.cancel()
        plist = url; error = nil
        if stateRootOverride == nil { UserDefaults.standard.set(url.path, forKey: "readingListSource") }
        onContextChange()
        requestSourceSync()
    }
    func startAutomaticSynchronization() {
        guard !preview, !stopping, autoSyncTask == nil else { return }
        autoSyncTask = Task { [weak self] in
            guard let self else { return }
            loadCatalog()
            while let read = task { await read.value }
            _ = await synchronizeOnce()
            while !Task.isCancelled, !stopping {
                do { try await Task.sleep(for: Self.syncInterval) } catch { break }
                _ = await synchronizeOnce()
            }
        }
    }
    func requestSourceSync() {
        guard !preview, !stopping else { return }
        syncRequested = true
        guard immediateSyncTask == nil else { return }
        immediateSyncTask = Task { [weak self] in
            guard let self else { return }
            defer { immediateSyncTask = nil }
            while syncRequested, !stopping {
                syncRequested = false
                while busy, let read = task { await read.value }
                while autoReading, let read = sourceReadTask { _ = try? await read.value }
                if stopping { break }
                _ = await synchronizeOnce()
            }
        }
    }
    @discardableResult
    func synchronizeOnce() async -> Bool {
        guard !preview, !stopping, !busy, !autoReading else { return false }
        guard let file = plist else {
            if catalog.entries.isEmpty { status = "Choose a Reading List source in Settings to load articles." }
            return true
        }
        autoReading = true
        defer { autoReading = false; sourceReadTask = nil }
        let generation = sourceGeneration
        let readTask = Task { try await snapshotReader(file) }
        sourceReadTask = readTask
        do {
            let result = try await withTaskCancellationHandler { try await readTask.value } onCancel: { readTask.cancel() }
            try Task.checkCancellation()
            guard !stopping, generation == sourceGeneration, plist == file else { return true }
            let current = try await coordinator.catalog(stateRoot: stateRoot)
            try Task.checkCancellation()
            guard !stopping, generation == sourceGeneration, plist == file else { return true }
            var proposed = current
            proposed.reconcile(result); proposed.excludedIDs = []
            if proposed.entries != current.entries || proposed.currentIDs != current.currentIDs {
                let saved = try await coordinator.reconcile(result, stateRoot: stateRoot)
                guard generation == sourceGeneration, plist == file else { return true }
                // Once committed, inventory reflects the saved result even if article selection changed.
                catalog = saved; onCatalogChange()
            } else { catalog = proposed }
            catalogLoaded = true; error = nil
            status = "\(result.entries.count) current entries; \(result.skippedEntries) unsupported entries skipped."
            onContextChange()
        } catch is CancellationError {
        } catch {
            guard generation == sourceGeneration, plist == file else { return true }
            self.error = safe(error)
        }
        return true
    }
    func cancel() { task?.cancel() }
    func stop() async {
        stopping = true
        sourceGeneration += 1
        let current = task, auto = autoSyncTask, immediate = immediateSyncTask, read = sourceReadTask
        current?.cancel(); auto?.cancel(); immediate?.cancel(); read?.cancel()
        await current?.value; await auto?.value; await immediate?.value
        _ = try? await read?.value
    }
    private func safe(_ error: any Error) -> String {
        if error is SourceFetchError || error is RelayError { return error.localizedDescription }
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
    func load(_ url: URL, profile: PrototypeProfile? = nil) {
        guard !inert, !busy else { return }
        busy = true; error = nil; status = "Loading article…"
        task = Task {
            defer { busy = false; task = nil }
            do {
                let limits = try FetchLimits(maximumBytes: profile?.maxArticleBytes ?? 10_000_000,
                                            timeout: Double(profile?.httpTimeoutSeconds ?? 30))
                let page = try await PageFetcher(limits: limits).fetch(url)
                let limit = profile?.chunkMaxCharacters ?? 1800
                let extraction = Task.detached { try Task.checkCancellation(); return try ReviewedSource.prepare(page, chunkLimit: limit) }
                let result = try await withTaskCancellationHandler { try await extraction.value } onCancel: { extraction.cancel() }
                try Task.checkCancellation()
                review = result
                status = result.issue == nil ? "Article ready." : "Source needs inspection."
            } catch is CancellationError { status = "Loading cancelled." }
            catch { self.error = safe(error); status = "Article needs attention." }
        }
    }
    func cancel() { task?.cancel() }
    private func safe(_ error: any Error) -> String {
        if error is SourceFetchError || error is RelayError { return error.localizedDescription }
        return "Article preview failed; inspect the source and retry."
    }
}

/// Review-content rendering shared by the standalone preview window.
struct ArticlePreviewContent: View {
    let review: ReviewedSource?
    var placeholder = "Loading article…"
    @State private var dismissedIssue: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let review {
                Text(review.document?.article.title ?? "Source inspection").font(.title2)
                Text("Original: \(review.page.originalURL.absoluteString)\nFinal: \(review.page.finalURL.absoluteString)").font(AppTypography.secondary).textSelection(.enabled)
                if let issue = review.issue, dismissedIssue != issue.message {
                    InlineNotice(message: issue.message) { dismissedIssue = issue.message }
                }
                if let document = review.document {
                    Text("Semantic blocks").font(.headline)
                    ForEach(Array(document.article.blocks.enumerated()), id: \.offset) { index, block in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(index) · \(block.kind.rawValue)").font(AppTypography.secondary).foregroundStyle(.secondary)
                            Text(block.text).textSelection(.enabled)
                        }
                    }
                    ForEach(document.article.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                }
                if let narration = review.narration {
                    Text("Narration preview · \(narration.chunks.count) chunks").font(.headline)
                    ForEach(narration.chunks, id: \.index) { chunk in Text(chunk.text).textSelection(.enabled) }
                    ForEach(narration.notices, id: \.self) { Text($0).foregroundStyle(.orange) }
                }
            } else { Text(placeholder).foregroundStyle(.secondary) }
        }
    }
}

struct ArticlePreviewView: View {
    let url: URL
    @State private var model: ArticlePreviewModel
    @Environment(\.dismiss) private var dismiss
    init(url: URL, inert: Bool = false, review: ReviewedSource? = nil) {
        self.url = url
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
        .font(AppTypography.body)
        .navigationTitle(model.title ?? "Article Preview")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }.help("Close this article preview")
            }
        }
        .task { model.load(url) }
        .onDisappear { model.cancel() }
    }
}

struct SourceReviewView: View {
    @Bindable var model: SourceReviewModel
    var notices = NoticeDismissalState()
    var speechRunning = false
    var body: some View {
        Form {
            Section {
                LabeledContent("Source", value: model.plist?.path ?? "Not chosen")
                    .help(model.plist?.path ?? "No Reading List source chosen")
                    .textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
                Text(model.status).font(AppTypography.secondary)
                if let error = model.error, notices.isVisible(message: error, key: "source") {
                    InlineNotice(message: error) { notices.dismiss(message: error, key: "source") }
                }
                HStack {
                    Button("Choose Reading List…") { notices.reset(key: "source"); model.selectPlist() }
                        .disabled(model.busy || model.persistenceBusy || speechRunning)
                        .help("Choose a different Reading List property-list file (read-only)")
                    if model.busy { ProgressView().controlSize(.small); Button("Stop Loading") { model.cancel() }.help("Stop reading the Reading List") }
                }
            } header: {
                SectionHelpHeader(title: "Reading List",
                    explanation: "The chosen Reading List file is checked automatically while VoiceRelay runs; it is strictly read-only and nothing is written back. To preview a saved article, double-click it in Articles. Troubleshooting does not add to the queue or generate speech.")
            }
        }.formStyle(.grouped).onAppear { model.loadCatalog() }
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

struct ArticlesView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    private var blocked: Bool { model.sourceReview.busy || model.sourceReview.persistenceBusy || model.queueMutationBusy || model.preview || model.stopping }
    var body: some View {
        VStack(spacing: 0) {
            if model.sourceReview.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.sourceReview.status)
                }.padding([.horizontal, .top])
            }
            if let error = model.sourceReview.error,
               model.notices.isVisible(message: error, key: "source") {
                InlineNotice(message: error) { model.notices.dismiss(message: error, key: "source") }
                    .padding([.horizontal, .top])
            }
            ForEach(model.enqueueIssues, id: \.self) { issue in
                if model.notices.isVisible(message: issue, key: "enqueue") {
                    InlineNotice(message: issue) { model.notices.dismiss(message: issue, key: "enqueue") }
                        .padding([.horizontal, .top])
                }
            }
            if model.sourceReview.catalog.entries.isEmpty {
                ContentUnavailableView("No Articles", systemImage: "doc.text",
                                       description: Text("Choose a Reading List source in Settings to load articles."))
            } else {
                List(selection: $model.articleSelection) {
                    ForEach(model.sourceReview.catalog.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title).font(.headline).lineLimit(2)
                            HStack(spacing: 6) {
                                Text(entry.url.host ?? "Article")
                                if let added = entry.addedAt { Text("· Saved \(added.formatted(date: .abbreviated, time: .omitted))") }
                            }.font(AppTypography.secondary).foregroundStyle(.secondary)
                            if let item = model.queueItems.first(where: { $0.sourceEntryID == entry.id }) { Text(item.state.label).foregroundStyle(.secondary) }
                            if !model.sourceReview.catalog.currentIDs.contains(entry.id) { Text("Absent in latest check; retained").foregroundStyle(.secondary) }
                        }
                        .tag(entry.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { openPreview(entry.url) }
                        .contextMenu { Button("Preview Article") { openPreview(entry.url) } }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.addSelectedToQueue()
                } label: {
                    Label("Add to Queue (\(model.selectedArticles.count))", systemImage: "plus")
                }
                .disabled(blocked || model.selectedArticles.isEmpty)
                .help("Add the selected articles to the queue")
            }
        }
        .onAppear {
            model.sourceReview.loadCatalog()
            model.sourceReview.requestSourceSync()
            model.sourceReview.startAutomaticSynchronization()
            model.refreshLibrary()
        }
    }
    private func openPreview(_ url: URL) {
        ArticlePreviewNavigation.open(url, using: openWindow)
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
#Preview("Troubleshooting — source status") { SourceReviewView(model: sourcePreview()) }
#Preview("Troubleshooting — retained entries after permission failure") {
    let model = sourcePreview(); model.error = "Synthetic file-access failure; previous entries retained."
    return SourceReviewView(model: model)
}
#Preview("Article preview — synthetic article") {
    ArticlePreviewView(url: URL(string: "https://articles.example/synthetic")!, inert: true, review: syntheticReview())
}
#Preview("Article preview — synthetic consent page") {
    ArticlePreviewView(url: URL(string: "https://articles.example/synthetic")!, inert: true, review: syntheticReview(issue: .consent))
}
#Preview("Articles — inert multi-selection") {
    let model = AppModel(preview: true)
    let entries = ["one", "two"].map { ReadingListEntry(id: $0, safariID: $0, url: URL(string: "https://articles.example/\($0)")!, title: "Synthetic article \($0)", addedAt: nil) }
    model.sourceReview.catalog.reconcile(ReadingListSnapshot(entries: entries, skippedEntries: 0))
    model.articleSelection = Set(entries.map(\.id))
    return ArticlesView(model: model)
}
#endif
