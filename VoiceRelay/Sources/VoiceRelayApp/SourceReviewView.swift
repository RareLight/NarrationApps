import SwiftUI
import AppKit
import Observation
import VoiceRelayCore

@MainActor @Observable
final class SourceReviewModel {
    var catalog = ReadingListCatalog()
    var selection: String?
    var address = ""
    var plist: URL?
    var review: ReviewedSource?
    var status = "Refresh Reading List or enter one article URL."
    var error: String?
    var busy = false
    var savedFolder: URL?
    var preview = false
    @ObservationIgnored private var task: Task<Void, Never>?
    var selectedEntry: ReadingListEntry? { catalog.entries.first { $0.id == selection } }

    func selectPlist() {
        guard !preview, !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "Choose a Reading List property-list file (read-only)"
        if panel.runModal() == .OK { plist = panel.url }
    }
    func refresh(profile: PrototypeProfile?) {
        guard !preview, !busy else { return }
        let file = plist ?? profile?.safariPlist ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/Bookmarks.plist")
        plist = file; busy = true; error = nil; status = "Reading saved entries…"
        task = Task {
            defer { busy = false; task = nil }
            do {
                let result = try await Task.detached { try ReadingList.read(file) }.value
                try Task.checkCancellation()
                catalog.reconcile(result)
                status = "\(result.entries.count) current entries; \(result.skippedEntries) unsupported entries skipped."
            } catch is CancellationError { status = "Refresh cancelled; previous entries retained." }
            catch { self.error = error.localizedDescription; status = "Refresh failed; previous entries retained." }
        }
    }
    func fetch(_ url: URL, profile: PrototypeProfile?) {
        guard !preview, !busy else { return }
        busy = true; error = nil; review = nil; savedFolder = nil; status = "Fetching selected article…"
        task = Task {
            defer { busy = false; task = nil }
            do {
                let limits = try FetchLimits(maximumBytes: profile?.maxArticleBytes ?? 10_000_000,
                                            timeout: Double(profile?.httpTimeoutSeconds ?? 30))
                let page = try await PageFetcher(limits: limits).fetch(url)
                let limit = profile?.chunkMaxCharacters ?? 1800
                let result = try await Task.detached { try ReviewedSource.prepare(page, chunkLimit: limit) }.value
                try Task.checkCancellation(); review = result
                status = result.issue == nil ? "Article ready for review." : "Source needs inspection."
            } catch is CancellationError { status = "Fetch cancelled." }
            catch { self.error = safe(error); status = "Selected article needs attention." }
        }
    }
    func fetchAddress(profile: PrototypeProfile?) {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              (try? ArticleURL.validate(url)) != nil else { error = SourceFetchError.invalidURL.localizedDescription; return }
        fetch(url, profile: profile)
    }
    func fetchSelection(profile: PrototypeProfile?) {
        guard let entry = selectedEntry, !catalog.excludedIDs.contains(entry.id) else { return }
        fetch(entry.url, profile: profile)
    }
    func toggleExclusion() {
        guard let entry = selectedEntry, !busy else { return }
        if !catalog.excludedIDs.insert(entry.id).inserted { catalog.excludedIDs.remove(entry.id) }
    }
    func save(profile: PrototypeProfile?, fixtureRoot: URL?) {
        guard !preview, !busy, let review else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.title = "Choose an empty private source-review folder, separate from media"
        guard panel.runModal() == .OK, let root = panel.url else { return }
        busy = true; error = nil
        task = Task {
            defer { busy = false; task = nil }
            do {
                let export = Task.detached { try SourceReviewArchive.save(review, root: root, imported: profile,
                    excluding: [fixtureRoot].compactMap { $0 }) }
                savedFolder = try await withTaskCancellationHandler { try await export.value } onCancel: { export.cancel() }
                status = "Private snapshot saved."
            } catch is CancellationError { status = "Export cancelled; folders without response.json are incomplete." }
            catch { self.error = safe(error) }
        }
    }
    func cancel() { task?.cancel() }
    func stop() async { let current = task; current?.cancel(); await current?.value }
    private func safe(_ error: any Error) -> String {
        if error is SourceFetchError || error is RelayError { return error.localizedDescription }
        return "Source review failed; inspect the selected source and retry."
    }
}

struct SourceReviewView: View {
    @Bindable var model: SourceReviewModel
    var profile: PrototypeProfile?
    var fixtureRoot: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Articles").font(.title)
            Text("Read-only Reading List · Review one article at a time").foregroundStyle(.secondary)
            HStack {
                Button("Refresh Reading List") { model.refresh(profile: profile) }.disabled(model.busy)
                Button("Choose plist…") { model.selectPlist() }.disabled(model.busy)
                if model.busy { ProgressView().controlSize(.small); Button("Cancel") { model.cancel() } }
            }
            if let plist = model.plist { Text(plist.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                TextField("HTTP or HTTPS article URL", text: $model.address)
                    .onSubmit { model.fetchAddress(profile: profile) }
                Button("Review URL") { model.fetchAddress(profile: profile) }.disabled(model.busy || model.address.isEmpty)
            }
            Text(model.status).font(.callout)
            if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
            HSplitView {
                VStack(alignment: .leading) {
                    List(selection: $model.selection) {
                        ForEach(model.catalog.entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.title).lineLimit(2)
                                Text(entry.url.host ?? "Article").font(.caption).foregroundStyle(.secondary)
                                if model.catalog.excludedIDs.contains(entry.id) { Text("Excluded from review").font(.caption).foregroundStyle(.secondary) }
                                else if !model.catalog.currentIDs.contains(entry.id) { Text("Absent in latest refresh; retained").font(.caption).foregroundStyle(.secondary) }
                            }.tag(entry.id)
                        }
                    }
                    HStack {
                        Button("Review selected") { model.fetchSelection(profile: profile) }
                            .disabled(model.busy || model.selectedEntry == nil || model.selection.map { model.catalog.excludedIDs.contains($0) } == true)
                        Button(model.selection.map { model.catalog.excludedIDs.contains($0) } == true ? "Include" : "Exclude") { model.toggleExclusion() }
                            .disabled(model.busy || model.selectedEntry == nil)
                    }
                    Text("Discovery and exclusions stay in this review session. Refreshing does not start narration.").font(.caption).foregroundStyle(.secondary)
                }.frame(minWidth: 260, idealWidth: 300)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let review = model.review {
                            Text(review.document?.article.title ?? "Source inspection").font(.title2)
                            Text("Original: \(review.page.originalURL.absoluteString)\nFinal: \(review.page.finalURL.absoluteString)").font(.caption).textSelection(.enabled)
                            if let issue = review.issue { Label(issue.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                            if let document = review.document {
                                Text("Semantic blocks").font(.headline)
                                ForEach(Array(document.article.blocks.enumerated()), id: \.offset) { index, block in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("\(index) · \(block.kind.rawValue)").font(.caption).foregroundStyle(.secondary)
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
                            Button("Save private snapshot…") { model.save(profile: profile, fixtureRoot: fixtureRoot) }.disabled(model.busy)
                            if let folder = model.savedFolder { Text(folder.path).font(.caption).textSelection(.enabled) }
                        } else { Text("Select an entry or enter a URL, then review its extraction before speech.").foregroundStyle(.secondary) }
                    }.padding().frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 440)
            }
            Text("Snapshots contain private URLs and article text. Keep their folder separate from served media.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 820, minHeight: 640)
    }
}

#if DEBUG
@MainActor private func sourcePreview(issue: SourceReviewIssue? = nil) -> SourceReviewModel {
    let model = SourceReviewModel(); model.preview = true
    let url = URL(string: "https://articles.example/synthetic")!
    let entry = ReadingListEntry(id: "synthetic", safariID: "synthetic", url: url, title: "Reading carefully — Café 日本語", addedAt: nil)
    model.catalog.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0)); model.selection = entry.id
    let html = "<html><title>Reading carefully</title><article><h1>Reading carefully</h1><p>" + String(repeating: "A synthetic article keeps previews private and preserves its original wording. ", count: 8) + "</p></article></html>"
    let page = FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html, contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
    if let issue { model.review = ReviewedSource(page: page, document: nil, narration: nil, issue: issue) }
    else { model.review = try? ReviewedSource.prepare(page, chunkLimit: 1800) }
    model.status = "Synthetic source review — no file or network actions"
    return model
}
#Preview("Articles — synthetic review") { SourceReviewView(model: sourcePreview()) }
#Preview("Articles — synthetic consent page") { SourceReviewView(model: sourcePreview(issue: .consent)) }
#Preview("Articles — retained entries after permission failure") {
    let model = sourcePreview(); model.review = nil; model.error = "Synthetic file-access failure; previous entries retained."
    return SourceReviewView(model: model)
}
#endif
