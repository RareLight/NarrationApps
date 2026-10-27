import NarrationCore
import AudioOutput
import Foundation

public enum FixtureBoundary: String, CaseIterable, Sendable {
    case chunkCommitted = "chunk-committed"
    case encoded = "encoded"
    case audioPlaced = "audio-placed"
    case episodeCommitted = "episode-committed"
    case feedReplaced = "feed-replaced"
}

public struct PipelineProgress: Sendable {
    public let stage: Stage
    public let completedChunks: Int
    public let totalChunks: Int
}

public enum FixtureResource {
    public static func html() throws -> Data {
        guard let url = Bundle.module.url(forResource: "article", withExtension: "html") else {
            throw RelayError.setup("Bundled synthetic article is missing.")
        }
        return try Data(contentsOf: url)
    }
}

struct ExtractionCheckpoint: Codable {
    let sourceHash: String
    let extractorVersion: String
    let narrationVersion: String
    let articleHash: String
    let narrationHash: String
    let cleanedHash: String
}

/// Durable approved text/provenance, independent of disposable processing files.
struct StoredExtraction: Codable {
    static let names = ["source.html", "article.json", "cleaned.html", "narration.json", "extraction-checkpoint.json"]
    let files: [String: Data]
    init(directory: URL) throws {
        files = try Dictionary(uniqueKeysWithValues: Self.names.map { ($0, try Data(contentsOf: directory.appendingPathComponent($0))) })
    }
    init(review: ReviewedSource, chunkLimit: Int) throws {
        guard review.issue == nil, let document = review.document else { throw RelayError.setup("Select a readable article before adding speech.") }
        let narration = try Narration.prepare(document.article, limit: chunkLimit)
        let article = try Files.json(document.article), plan = try Files.json(narration), cleaned = Data(document.cleanedHTML.utf8)
        let cp = ExtractionCheckpoint(sourceHash: Files.hash(review.page.bytes), extractorVersion: document.article.extractorVersion,
                                      narrationVersion: narration.version, articleHash: Files.hash(article),
                                      narrationHash: Files.hash(plan), cleanedHash: Files.hash(cleaned))
        files = [Self.names[0]: review.page.bytes, Self.names[1]: article, Self.names[2]: cleaned,
                 Self.names[3]: plan, Self.names[4]: try Files.json(cp)]
    }
    func review() throws -> ReviewedSource {
        guard Set(files.keys) == Set(Self.names), let checkpoint = files[Self.names[4]],
              let source = files[Self.names[0]], let articleData = files[Self.names[1]],
              let cleaned = files[Self.names[2]], let narrationData = files[Self.names[3]],
              let html = String(data: cleaned, encoding: .utf8) else {
            throw RelayError.artifact("Saved article snapshot is incomplete.")
        }
        let cp = try JSONDecoder().decode(ExtractionCheckpoint.self, from: checkpoint)
        guard Files.hash(source) == cp.sourceHash, Files.hash(articleData) == cp.articleHash,
              Files.hash(cleaned) == cp.cleanedHash, Files.hash(narrationData) == cp.narrationHash else {
            throw RelayError.artifact("Saved article snapshot integrity failed. Existing audio is preserved.")
        }
        let article = try JSONDecoder().decode(SemanticArticle.self, from: articleData)
        let narration = try JSONDecoder().decode(NarrationPlan.self, from: narrationData)
        let page = FetchedPage(originalURL: article.originalURL, finalURL: article.finalURL, bytes: source,
                               html: "", contentType: source.starts(with: Data("%PDF-".utf8)) ? "application/pdf" : "text/html", encoding: "saved-response", fetchedAt: .distantPast,
                               archivedCopy: article.archivedCopy)
        return ReviewedSource(page: page, document: ExtractedDocument(article: article, cleanedHTML: html), narration: narration, issue: nil)
    }
    func restore(to directory: URL) throws {
        _ = try review()
        for name in Self.names {
            let destination = directory.appendingPathComponent(name)
            guard !Files.hasSymlink(destination, below: directory) else { throw RelayError.setup("Temporary article storage contains an unexpected link.") }
            let data = files[name]!
            if FileManager.default.fileExists(atPath: destination.path) {
                guard try Files.hash(destination, description: "temporary article snapshot") == Files.hash(data) else { throw RelayError.artifact("Temporary article snapshot integrity failed.") }
            } else { try Files.write(data, to: destination) }
        }
    }
}

enum FixtureWorkspace {
    static let markerText = "VoiceRelay isolated speech workspace v1\n"
    static func prepare(root: URL, imported: PrototypeProfile?, articles: Bool = false) throws -> PrototypeProfile {
        let markerText = articles ? "VoiceRelay private article library v1\n" : Self.markerText
        guard root.isFileURL, root.path != "/", root.standardizedFileURL != FileManager.default.homeDirectoryForCurrentUser else {
            throw RelayError.setup("Select a dedicated fixture directory.")
        }
        if let imported {
            for live in [imported.database, imported.work, imported.audio, imported.feed, imported.safariPlist, imported.configurationURL].compactMap({ $0 }) {
                guard !Files.contains(root, live), !Files.contains(live, root) else {
                    throw RelayError.setup("Fixture directory overlaps configured live state, storage, source, or configuration.")
                }
            }
        }
        if root.path.hasPrefix("/Volumes/") && !FileManager.default.fileExists(atPath: root.deletingLastPathComponent().path) {
            throw RelayError.setup("Fixture destination's mounted storage is unavailable.")
        }
        let marker = root.appendingPathComponent(".voicerelay-fixture")
        let p = imported?.isolated(at: root) ?? PrototypeProfile.fixture(at: root)
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            let children = try fm.contentsOfDirectory(atPath: root.path)
            if !children.isEmpty {
                guard (try? String(contentsOf: marker, encoding: .utf8)) == markerText else {
                    throw RelayError.setup("Refusing a nonempty directory without the native fixture marker.")
                }
                guard [p.database.deletingLastPathComponent(), p.work, p.audio].allSatisfy({ fm.fileExists(atPath: $0.path) }) else {
                    throw RelayError.setup("Fixture storage is missing. Restore it before resuming; no destination was recreated.")
                }
            } else { try initialize(root: root, p: p, markerText: markerText) }
        } else { try initialize(root: root, p: p, markerText: markerText) }
        for path in [marker, p.database, p.work, p.audio, p.feed, root.appendingPathComponent(".media-staging")] {
            guard Files.contains(root, path), !Files.hasSymlink(path, below: root) else {
                throw RelayError.setup("Fixture paths must remain inside their dedicated workspace without symlinks.")
            }
        }
        try p.validate()
        for path in [root, p.work, p.audio] {
            let info = try fm.attributesOfFileSystem(forPath: path.path)
            guard let free = info[.systemFreeSize] as? NSNumber, free.int64Value >= Int64(p.minimumFreeBytes) else {
                throw RelayError.setup("Fixture storage has insufficient available space for the configured reserve.")
            }
        }
        return p
    }
    private static func initialize(root: URL, p: PrototypeProfile, markerText: String) throws {
        try Files.directory(root)
        try Files.directory(p.database.deletingLastPathComponent()); try Files.directory(p.work); try Files.directory(p.audio)
        // Only a dedicated empty/new workspace receives the fixture ownership marker.
        let marker = root.appendingPathComponent(".voicerelay-fixture")
        try Data(markerText.utf8).write(to: marker, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }
}

public actor FixtureCoordinator {
    public init() {}
    var beforeAudioProcessing: (@Sendable (SpeechTimingStage, URL) throws -> Void)?
    func setBeforeAudioProcessing(_ hook: (@Sendable (SpeechTimingStage, URL) throws -> Void)?) { beforeAudioProcessing = hook }
    var activeDrainRoots: Set<String> = []
    var activeDeliveryRoots: Set<String> = []
    var beforeEnqueueCommit: (@Sendable () -> Void)?
    func setBeforeEnqueueCommit(_ hook: (@Sendable () -> Void)?) { beforeEnqueueCommit = hook }
    var beforeOwnedAudioUnlink: (@Sendable (URL) -> Void)?
    func setBeforeOwnedAudioUnlink(_ hook: (@Sendable (URL) -> Void)?) { beforeOwnedAudioUnlink = hook }
    var beforeAudioRemovalLease: (@Sendable () -> Void)?
    func setBeforeAudioRemovalLease(_ hook: (@Sendable () -> Void)?) { beforeAudioRemovalLease = hook }
    var beforeDeliveryPreflight: (@Sendable () -> Void)?
    func setBeforeDeliveryPreflight(_ hook: (@Sendable () -> Void)?) { beforeDeliveryPreflight = hook }
    public func library(storage: ManagedSpeechStorage) throws -> [Episode] {
        try storage.validate()
        let p = storage.profile
        guard FileManager.default.fileExists(atPath: p.database.path) else { return [] }
        try storage.validateState()
        let episodes = try NativeStore(url: p.database, readOnly: true).episodes()
        for e in episodes {
            guard UUID(uuidString: e.id) != nil,
                  [e.settings.database, e.settings.work, e.settings.audio, e.settings.feed].allSatisfy(\.isFileURL),
                  Files.samePath(e.settings.database, p.database), Files.samePath(e.settings.feed, p.feed),
                  ["reviewed-article-speech", "speech-fixture"].contains(e.settings.backendSelector), e.settings.webdavURL == nil else {
                throw RelayError.setup("Saved articles do not match their private library.")
            }
            try ManagedSpeechStorage(audioDirectory: e.settings.audio, stateRoot: storage.stateRoot,
                                     temporaryRoot: storage.temporaryRoot).validate()
        }
        return episodes
    }
    public func articlePreviewProfile(articleID: String, stateRoot: URL = AppStorage.managedLibrary) throws -> PrototypeProfile {
        try ManagedSpeechStorage.validateLibrary(stateRoot: stateRoot)
        let database = PrototypeProfile.fixture(at: stateRoot).database
        guard UUID(uuidString: articleID) != nil, FileManager.default.fileExists(atPath: database.path),
              let record = try NativeStore(url: database, readOnly: true).query("SELECT record FROM episodes WHERE id=?", [articleID]).first?.first else {
            throw RelayError.setup("The queued article settings are unavailable. Reopen Articles and try again.")
        }
        return try JSONDecoder().decode(Episode.self, from: Data(record.utf8)).settings
    }
    public func articlePreviewURL(articleID: String, stateRoot: URL = AppStorage.managedLibrary) throws -> URL {
        try ManagedSpeechStorage.validateLibrary(stateRoot: stateRoot)
        let database = PrototypeProfile.fixture(at: stateRoot).database
        guard FileManager.default.fileExists(atPath: database.path), UUID(uuidString: articleID) != nil,
              let data = try NativeStore(url: database, readOnly: true).snapshot(articleID: articleID) else {
            throw RelayError.setup("The saved article text is unavailable. Double-click it in Articles to preview it.")
        }
        let url = try JSONDecoder().decode(StoredExtraction.self, from: data).review().page.originalURL
        try ArticleURL.validate(url)
        return url
    }
    public func savedArticlePreview(articleID: String, stateRoot: URL = AppStorage.managedLibrary) throws -> ReviewedSource {
        try ManagedSpeechStorage.validateLibrary(stateRoot: stateRoot)
        let database = PrototypeProfile.fixture(at: stateRoot).database
        guard UUID(uuidString: articleID) != nil, FileManager.default.fileExists(atPath: database.path),
              let data = try NativeStore(url: database, readOnly: true).snapshot(articleID: articleID) else {
            throw RelayError.setup("The saved article text is unavailable.")
        }
        return try JSONDecoder().decode(StoredExtraction.self, from: data).review()
    }
    public func resume(storage: ManagedSpeechStorage, articleID: String, backend: any TTSBackend,
                       delivery: DeliverySettings? = nil,
                       onProgress: @escaping @Sendable (PipelineProgress) -> Void = { _ in }) async throws -> FixtureResult {
        try await resumeWork(storage: storage, articleID: articleID, backend: backend, delivery: delivery, onProgress: onProgress)
    }
    func resumeWork(storage: ManagedSpeechStorage, articleID: String, backend: any TTSBackend,
                    delivery: DeliverySettings? = nil, context: SpeechArticleContext? = nil,
                    onProgress: @escaping @Sendable (PipelineProgress) -> Void) async throws -> FixtureResult {
        guard let e = try library(storage: storage).first(where: { $0.id == articleID }),
              let data = try NativeStore(url: storage.profile.database, readOnly: true).snapshot(articleID: e.id) else {
            throw RelayError.setup("The saved article text is unavailable. Select the article again before generating speech.")
        }
        let review = try JSONDecoder().decode(StoredExtraction.self, from: data).review()
        let captured = storage.temporaryAudio && (e.settings.temporaryAudio == true || e.localAudioReleased == true || e.stage != .published)
            ? storage : ManagedSpeechStorage(audioDirectory: e.settings.audio, stateRoot: storage.stateRoot,
                temporaryRoot: storage.temporaryRoot, temporaryAudio: e.settings.temporaryAudio == true)
        let voice = e.settings.voice ?? "af_heart", speed = e.settings.backendSettings["speed"]?.numericValue ?? 1
        guard !backend.identity.isMock, review.issue == nil, review.document != nil,
              review.narration?.chunks.isEmpty == false else {
            throw RelayError.setup("Review a readable article before requesting speech.")
        }
        try ArticleURL.validate(review.page.originalURL); try ArticleURL.validate(review.page.finalURL)
        return try await executeWork(root: captured.stateRoot, imported: nil, backend: backend,
            review: e.settings.backendSelector == "speech-fixture" ? nil : review, storage: captured,
            delivery: delivery, speechVoice: voice, speechSpeed: speed, context: context,
            interruptAfter: nil, onBoundary: { _ in }, onProgress: onProgress)
    }
    public func library(root: URL) throws -> [Episode] {
        guard root.isFileURL else { throw RelayError.setup("Article storage must be local.") }
        let p = PrototypeProfile.fixture(at: root)
        guard FileManager.default.fileExists(atPath: p.database.path) else { return [] }
        let marker = root.appendingPathComponent(".voicerelay-fixture")
        guard (try? String(contentsOf: marker, encoding: .utf8)) == "VoiceRelay private article library v1\n",
              [marker, p.database, p.work, p.audio, p.feed].allSatisfy({ Files.contains(root, $0) && !Files.hasSymlink($0, below: root) }) else {
            throw RelayError.setup("Article library ownership or storage is invalid.")
        }
        let episodes = try NativeStore(url: p.database, readOnly: true).episodes()
        guard episodes.allSatisfy({ e in
            UUID(uuidString: e.id) != nil
            && [e.settings.database, e.settings.work, e.settings.audio, e.settings.feed].allSatisfy(\.isFileURL)
            && Files.samePath(e.settings.database, p.database)
            && Files.samePath(e.settings.work, p.work) && Files.samePath(e.settings.audio, p.audio)
            && Files.samePath(e.settings.feed, p.feed) && e.settings.backendSelector == "reviewed-article-speech"
            && e.settings.webdavURL == nil
        }) else { throw RelayError.setup("Saved articles do not match their library storage.") }
        return episodes
    }
    public func resumeReviewed(root: URL, articleID: String, backend: any TTSBackend,
                               onProgress: @escaping @Sendable (PipelineProgress) -> Void = { _ in }) async throws -> FixtureResult {
        try Task.checkCancellation()
        guard let episode = try library(root: root).first(where: { $0.id == articleID }) else {
            throw RelayError.setup("Saved article is unavailable in this library.")
        }
        let folder = episode.settings.work.appendingPathComponent(episode.id)
        let paths = ["source.html", "article.json", "cleaned.html", "narration.json", "extraction-checkpoint.json"]
            .map { folder.appendingPathComponent($0) }
        guard paths.allSatisfy({ Files.contains(root, $0) && !Files.hasSymlink($0, below: root) }) else {
            throw RelayError.setup("Saved source paths are invalid.")
        }
        let cp = try JSONDecoder().decode(ExtractionCheckpoint.self, from: Data(contentsOf: paths[4]))
        guard try Files.hash(paths[0], description: "saved article source") == cp.sourceHash,
              try Files.hash(paths[1], description: "saved article text") == cp.articleHash,
              try Files.hash(paths[2], description: "saved cleaned article") == cp.cleanedHash,
              try Files.hash(paths[3], description: "saved narration") == cp.narrationHash else {
            throw RelayError.artifact("Saved article snapshot integrity failed. Existing audio is preserved.")
        }
        let article = try JSONDecoder().decode(SemanticArticle.self, from: Data(contentsOf: paths[1]))
        let narration = try JSONDecoder().decode(NarrationPlan.self, from: Data(contentsOf: paths[3]))
        let document = ExtractedDocument(article: article, cleanedHTML: try String(contentsOf: paths[2], encoding: .utf8))
        // Resumption uses the reviewed semantic snapshot and exact response bytes; no fetch/HTML decode.
        let page = FetchedPage(originalURL: article.originalURL, finalURL: article.finalURL,
                               bytes: try Data(contentsOf: paths[0]), html: "", contentType: article.extractorVersion == PDFArticleExtractor.version ? "application/pdf" : "text/html",
                               encoding: "saved-response", fetchedAt: .distantPast)
        let review = ReviewedSource(page: page, document: document, narration: narration, issue: nil)
        return try await runReviewed(root: root, review: review, backend: backend,
                                     voice: episode.settings.voice ?? "af_heart",
                                     speed: episode.settings.backendSettings["speed"]?.numericValue ?? 1, onProgress: onProgress)
    }
    public func runSpeech(root: URL, imported: PrototypeProfile? = nil, backend: any TTSBackend,
                          voice: String? = nil, speed: Double? = nil,
                          interruptAfter: FixtureBoundary? = nil,
                          storage: ManagedSpeechStorage? = nil,
                          delivery: DeliverySettings? = nil,
                          onBoundary: @escaping @Sendable (FixtureBoundary) -> Void = { _ in },
                          onProgress: @escaping @Sendable (PipelineProgress) -> Void = { _ in }) async throws -> FixtureResult {
        guard !backend.identity.isMock else { throw RelayError.setup("Speech checks require an explicitly selected real-speech provider.") }
        return try await executeWork(root: root, imported: imported, backend: backend,
                                     storage: storage, delivery: delivery,
                                     speechVoice: voice, speechSpeed: speed,
                                     interruptAfter: interruptAfter, onBoundary: onBoundary, onProgress: onProgress)
    }
    public func runReviewed(root: URL, review: ReviewedSource, backend: any TTSBackend,
                            voice: String = "af_heart", speed: Double = 1,
                            interruptAfter: FixtureBoundary? = nil,
                            storage: ManagedSpeechStorage? = nil,
                            delivery: DeliverySettings? = nil,
                            onProgress: @escaping @Sendable (PipelineProgress) -> Void = { _ in }) async throws -> FixtureResult {
        try Task.checkCancellation()
        guard !backend.identity.isMock, review.issue == nil, let document = review.document,
              let narration = review.narration, !narration.chunks.isEmpty,
              document.article.originalURL == review.page.originalURL,
              document.article.finalURL == review.page.finalURL else {
            throw RelayError.setup("Review a readable article before requesting speech.")
        }
        try ArticleURL.validate(review.page.originalURL); try ArticleURL.validate(review.page.finalURL)
        return try await executeWork(root: root, imported: nil, backend: backend, review: review,
                                     storage: storage, delivery: delivery,
                                     speechVoice: voice, speechSpeed: speed, interruptAfter: interruptAfter,
                                     onBoundary: { _ in }, onProgress: onProgress)
    }
    private func executeWork(root: URL, imported: PrototypeProfile?, backend: any TTSBackend, review: ReviewedSource? = nil,
                             storage: ManagedSpeechStorage? = nil, delivery: DeliverySettings? = nil,
                             speechVoice: String? = nil, speechSpeed: Double? = nil,
                             context: SpeechArticleContext? = nil, interruptAfter: FixtureBoundary?, onBoundary: @escaping @Sendable (FixtureBoundary) -> Void,
                             onProgress: @escaping @Sendable (PipelineProgress) -> Void) async throws -> FixtureResult {
        let audioObserver = beforeAudioProcessing
        let child = Task.detached(priority: .userInitiated) {
            try await Self.execute(root: root, imported: imported, backend: backend, review: review,
                             storage: storage, delivery: delivery, speechVoice: speechVoice, speechSpeed: speechSpeed,
                             context: context, audioObserver: audioObserver, interruptAfter: interruptAfter, onBoundary: onBoundary, onProgress: onProgress)
        }
        return try await withTaskCancellationHandler {
            try await child.value
        } onCancel: {
            if context?.finishAfterStop != true { child.cancel() }
        }
    }
    private nonisolated static func execute(root: URL, imported: PrototypeProfile?, backend: any TTSBackend, review: ReviewedSource? = nil,
                                            storage: ManagedSpeechStorage? = nil, delivery: DeliverySettings? = nil,
                                            speechVoice: String? = nil, speechSpeed: Double? = nil,
                                            context: SpeechArticleContext? = nil, audioObserver: (@Sendable (SpeechTimingStage, URL) throws -> Void)? = nil, interruptAfter: FixtureBoundary?, onBoundary: @Sendable (FixtureBoundary) -> Void,
                                            onProgress: @Sendable (PipelineProgress) -> Void) async throws -> FixtureResult {
        try Task.checkCancellation()
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        if let delivery { try delivery.validate() }
        guard speechVoice == nil || speechVoice!.range(of: "^[ab][fm]_[a-z0-9_]+$", options: .regularExpression) != nil,
              speechSpeed == nil || (speechSpeed!.isFinite && (0.25...4).contains(speechSpeed!)) else {
            throw RelayError.setup("Speech voice or speed is unsupported.")
        }
        if let storage {
            guard imported == nil, Files.samePath(root, storage.stateRoot) else { throw RelayError.setup("Managed speech storage does not match its private library.") }
        }
        var selected = try storage?.prepare() ?? FixtureWorkspace.prepare(root: root, imported: imported, articles: review != nil)
        selected.backendSelector = review == nil ? "speech-fixture" : "reviewed-article-speech"
        selected.voice = speechVoice ?? imported?.voice
        selected.backendSettings = imported?.backendSettings ?? [:]
        if let speechSpeed { selected.backendSettings["speed"] = .number(speechSpeed) }
        selected.channelTitle = review == nil ? "VoiceRelay Speech Fixture" : "VoiceRelay Articles"
        selected.channelDescription = "Private local speech; remote delivery disabled"
        try selected.validate()
        let lease: PipelineLease?
        if let context { try context.pipeline.ensureLease(selected.database); lease = nil }
        else { lease = try PipelineLease(database: selected.database) }
        defer { lease?.release(); context?.finishSpeech() }
        let diagnostics = context?.pipeline.diagnostics ?? SpeechDiagnostics(log: nil)
        let articleStart = ProcessInfo.processInfo.systemUptime
        defer { diagnostics.record(.article, seconds: ProcessInfo.processInfo.systemUptime - articleStart) }
        var finalizer: SpeechFinalizationPermit?
        defer { finalizer?.release() }
        func handoffSpeech() async throws {
            if let context, finalizer == nil {
                let waitStart = diagnostics.beginFinalizerWait(database: selected.database)
                finalizer = try await context.pipeline.finalization.acquire()
                diagnostics.endFinalizerWait(waitStart, database: selected.database)
                try Task.checkCancellation()
                context.beginFinalization(); context.finishSpeech()
            }
        }
        let store = try PipelineStore(databaseURL: selected.database)
        let sourceKey = review.map { "reviewed-url-v1-" + Files.hash(Data($0.page.originalURL.absoluteString.utf8)) }
            ?? "bundled-synthetic-article-v1"
        var e = try store.episode(sourceKey: sourceKey, settings: selected)
        if e.stage == .expired {
            guard e.manualAudioDeletionRequested != true else {
                throw RelayError.setup("Saved audio removal is unfinished. Reopen Saved Audio to finish it before regenerating.")
            }
            guard !FileManager.default.fileExists(atPath: e.settings.audio.appendingPathComponent(e.id + ".m4a").path) else {
                throw RelayError.setup("Audio expiry cleanup is unfinished. Restore folder access and reopen Saved Audio before generating again.")
            }
            e.encodedHash = nil; e.audioHash = nil; e.info = nil; e.synthesisFingerprint = nil; e.publicationDate = nil
        }
        if let storage {
            if e.settings.temporaryAudio == true || e.localAudioReleased == true, e.stage == .published,
               temporaryAudioIsMissing(e) {
                // A retained snapshot regenerates lost/released temporary output using
                // the same GUID and captured voice. Remote history is unchanged until commit.
                e.stage = .extracted
                e.encodedHash = nil; e.audioHash = nil; e.info = nil; e.synthesisFingerprint = nil
                e.localAudioReleased = nil; e.audioFinalizationComplete = nil; e.delivery = nil
            }
            if storage.temporaryAudio, e.stage != .published,
               !FileManager.default.fileExists(atPath: e.settings.audio.appendingPathComponent(e.id + ".m4a").path) {
                e.settings.audio = storage.audioDirectory
                e.settings.temporaryAudio = true
                e.audioVolumeID = nil
            }
            // Cleanup must not race a periodic drain while this item is being validated.
            e.audioFinalizationComplete = false
            // Existing placed files finish publication unchanged; new output uses temporary storage.
            _ = try ManagedSpeechStorage(audioDirectory: e.settings.audio, stateRoot: storage.stateRoot,
                                         temporaryRoot: storage.temporaryRoot, temporaryAudio: e.settings.temporaryAudio == true).prepare()
            let volumeID = (try? e.settings.audio.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
            if let stored = e.audioVolumeID, stored != volumeID {
                throw RelayError.setup("The original audio volume is unavailable. Reconnect it before resuming.")
            }
            if e.audioVolumeID == nil { e.audioVolumeID = volumeID }
            e.settings.work = selected.work
            // Encoding is an internal app policy, independent of captured voice/speed.
            // Preserve any already placed final file, including interrupted publication.
            if e.stage != .published && !FileManager.default.fileExists(atPath: e.settings.audio.appendingPathComponent(e.id + ".m4a").path) {
                e.settings.bitrate = selected.bitrate
            }
            selected.audio = e.settings.audio
            try store.save(e)
        }
        let p = e.settings // Capture relevant settings once; subsequent profile changes affect new work.
        guard Files.samePath(p.database, selected.database), Files.samePath(p.work, selected.work),
              Files.samePath(p.audio, selected.audio), Files.samePath(p.feed, selected.feed),
              p.backendSelector == selected.backendSelector, p.webdavURL == nil else {
            throw RelayError.setup("Saved fixture profile does not match this workspace. Moving/adopting state requires an explicit import.")
        }
        try p.validate()
        let directory = p.work.appendingPathComponent(e.id)
        guard Files.contains(p.work, directory), !Files.hasSymlink(directory, below: p.work) else {
            throw RelayError.setup("Episode work must remain inside its fixture without symlinks.")
        }
        try Files.directory(directory)
        let processor = AudioProcessor(settings: p, toolDirectory: directory, diagnostics: diagnostics, observer: context?.pipeline.audioObserver ?? audioObserver)
        func boundary(_ point: FixtureBoundary) throws {
            onBoundary(point)
            try Task.checkCancellation()
            if interruptAfter == point { throw RelayError.interrupted }
        }
        func progress(_ stage: Stage, _ done: Int = 0, _ total: Int = 0) {
            onProgress(PipelineProgress(stage: stage, completedChunks: done, totalChunks: total))
        }
        let source = directory.appendingPathComponent("source.html")
        let articleFile = directory.appendingPathComponent("article.json")
        let narrationFile = directory.appendingPathComponent("narration.json")
        let cleanedFile = directory.appendingPathComponent("cleaned.html")
        let extractionFile = directory.appendingPathComponent("extraction-checkpoint.json")
        let sourceBytes = try review?.page.bytes ?? FixtureResource.html(); let sourceHash = Files.hash(sourceBytes)
        let placedDestination = p.audio.appendingPathComponent(e.id + ".m4a")
        let preservingPlacedAudio = e.stage == .encoded && e.encodedHash != nil
            && !Files.hasSymlink(placedDestination, below: p.audio)
            && (try? Files.hash(placedDestination)) == e.encodedHash
            && (try? processor.probe(placedDestination, final: true)) != nil
        if storage != nil, let data = try store.snapshot(articleID: e.id) {
            let saved = try JSONDecoder().decode(StoredExtraction.self, from: data)
            let savedReview = try saved.review()
            if Files.hash(savedReview.page.bytes) == sourceHash { try saved.restore(to: directory) }
            else if e.stage == .published || preservingPlacedAudio { throw RelayError.setup("This article already has audio from a different source snapshot. Existing audio is preserved.") }
        }
        if review != nil, e.stage == .published || preservingPlacedAudio,
           let bytes = try? Data(contentsOf: extractionFile),
           let cp = try? JSONDecoder().decode(ExtractionCheckpoint.self, from: bytes), cp.sourceHash != sourceHash {
            throw RelayError.setup("This article already has audio from a different source snapshot. Existing audio is preserved.")
        }
        var article: SemanticArticle?
        var plan: NarrationPlan?
        if let bytes = try? Data(contentsOf: extractionFile),
           let cp = try? JSONDecoder().decode(ExtractionCheckpoint.self, from: bytes),
           cp.sourceHash == sourceHash,
           (e.stage == .published || preservingPlacedAudio || (cp.extractorVersion == (review?.document?.article.extractorVersion ?? ArticleExtractor.version)
                                      && cp.narrationVersion == ((backend as? any PreparedTTSBackend)?.narrationVersion ?? Narration.version(pronunciations: backend.pronunciations)))),
           (try? Files.hash(source)) == sourceHash, (try? Files.hash(articleFile)) == cp.articleHash,
           (try? Files.hash(narrationFile)) == cp.narrationHash, (try? Files.hash(cleanedFile)) == cp.cleanedHash {
            article = try? JSONDecoder().decode(SemanticArticle.self, from: Data(contentsOf: articleFile))
            plan = try? JSONDecoder().decode(NarrationPlan.self, from: Data(contentsOf: narrationFile))
        }
        if article == nil || plan == nil {
            guard e.stage != .published && !preservingPlacedAudio else { throw RelayError.artifact("Finished audio is preserved, but its semantic checkpoint needs inspection before publication can continue.") }
            e.stage = .fetching; try store.save(e); progress(.fetching)
            guard sourceBytes.count <= p.maxArticleBytes else {
                throw RelayError.extraction("Fixture HTML exceeds configured bounds or has an unsupported encoding.")
            }
            if (try? Files.hash(source)) != sourceHash { try Files.write(sourceBytes, to: source) }
            let document: ExtractedDocument
            if let reviewed = review?.document { document = reviewed }
            else {
                guard let html = String(data: sourceBytes, encoding: .utf8) else { throw RelayError.extraction("Saved article encoding is unsupported.") }
                let page = URL(string: "https://articles.example/fixture")!
                document = try ArticleExtractor.extract(html: html, originalURL: page, finalURL: page)
            }
            let native = backend as? any PreparedTTSBackend
            let purpose = native?.preparationPurpose ?? .preview
            let projection = try Narration.prepare(document.article, limit: p.chunkMaxCharacters,
                pronunciations: backend.pronunciations, settings: native?.speechSettings, purpose: purpose, options: p.narrationOptions ?? .init())
            if native != nil, let previous = context?.previous { try await previous.wait() }
            var narration = try native?.prepareNarration(projection) ?? projection
            if native != nil, let oldData = try? Data(contentsOf: narrationFile),
               let old = try? JSONDecoder().decode(NarrationPlan.self, from: oldData), old.version != narration.version {
                narration = NarrationPlan(version: narration.version, chunks: narration.chunks,
                    notices: narration.notices + ["Unfinished narration was prepared with the current speech pipeline. Completed and published audio is preserved."], omissions: narration.omissions)
            }
            try Files.write(try Files.json(document.article), to: articleFile)
            try Files.write(try Files.json(narration), to: narrationFile)
            try Files.write(Data(document.cleanedHTML.utf8), to: cleanedFile)
            let cp = ExtractionCheckpoint(sourceHash: sourceHash, extractorVersion: document.article.extractorVersion, narrationVersion: narration.version,
                                          articleHash: try Files.hash(articleFile, description: "prepared article text"),
                                          narrationHash: try Files.hash(narrationFile, description: "prepared narration"),
                                          cleanedHash: try Files.hash(cleanedFile, description: "cleaned article"))
            try Files.write(try Files.json(cp), to: extractionFile)
            if storage != nil { try store.saveSnapshot(articleID: e.id, data: Files.json(StoredExtraction(directory: directory))) }
            article = document.article; plan = narration; e.title = document.article.title
            e.encodedHash = nil; e.info = nil; e.stage = .extracted; try store.save(e)
        }
        guard let article, let plan else { throw RelayError.artifact("Extraction checkpoint is invalid.") }
        progress(e.stage, 0, plan.chunks.count)
        let encoded = directory.appendingPathComponent("episode.m4a")
        let destination = p.audio.appendingPathComponent(e.id + ".m4a")
        guard !Files.hasSymlink(destination, below: p.audio) else { throw RelayError.setup("The saved audio path contains an unexpected link.") }
        var syntheses = 0
        let inputFingerprint = Files.hash(try Files.json(EncodingFingerprint(backend: backend.identity,
            profile: p, extraction: article.extractorVersion, narration: plan, audioProcessing: AudioProcessor.encodingVersion)))
        if let previous = context?.previous { try await previous.wait() }
        if e.stage != .published {
            // Once an authenticated copy is in the final folder, finish its publication
            // unchanged rather than replacing it because an encoding policy changed.
            let placedAudioValid = e.stage == .encoded && e.encodedHash != nil
                && (try? Files.hash(destination)) == e.encodedHash
                && (try? processor.probe(destination, final: true)) != nil
            let encodedValid = placedAudioValid || (e.encodedHash != nil && (try? Files.hash(encoded)) == e.encodedHash
                && e.synthesisFingerprint == inputFingerprint
                && (try? processor.probe(encoded, final: true)) != nil)
            if !encodedValid {
                e.stage = .synthesizing; try store.save(e); progress(.synthesizing, 0, plan.chunks.count)
                var prepared = false
                var artifacts: [LosslessArtifact] = []
                var transcriptTexts: [String] = [], transcriptArtifactCounts: [Int] = []
                var pending: Task<ChunkCheckpoint, any Error>?
                var pendingIndex = 0
                func commitPending() async throws {
                    guard let task = pending else { return }
                    let cp = try await task.value
                    pending = nil
                    artifacts += NativeMLXBackend.assemblyArtifacts(for: cp.request, result: cp.result, gapSeconds: p.gapSeconds)
                    transcriptTexts.append(cp.request.preparedUtterance?.text ?? cp.request.text)
                    transcriptArtifactCounts.append(cp.result.artifacts.count)
                    try boundary(.chunkCommitted)
                    progress(.synthesizing, pendingIndex + 1, plan.chunks.count)
                }
                do {
                    for (position, chunk) in plan.chunks.enumerated() {
                        try Task.checkCancellation()
                        let chunkDirectory = directory.appendingPathComponent("chunk-\(chunk.index)")
                        guard Files.contains(directory, chunkDirectory), !Files.hasSymlink(chunkDirectory, below: directory) else {
                            throw RelayError.setup("Chunk work must remain inside its fixture without symlinks.")
                        }
                        try Files.directory(chunkDirectory)
                        func requestFor(_ chunk: NarrationChunk) -> SynthesisRequest {
                            SynthesisRequest(text: chunk.text, language: p.language, voice: p.voice, articleID: e.id,
                                chunkIndex: chunk.index, blockIndices: chunk.blockIndices, settings: p.backendSettings, preparedUtterance: chunk.preparedUtterance)
                        }
                        let request = requestFor(chunk)
                        let fingerprint = Files.hash(try Files.json(Fingerprint(request: request, backend: backend.identity,
                            extraction: ArticleExtractor.chunkFingerprintVersion(article.extractorVersion), narration: Narration.chunkFingerprintVersion(plan.version))))
                        var checkpoint = try store.chunk(articleID: e.id, index: chunk.index, fingerprint: fingerprint)
                        if let cp = checkpoint {
                            let valid = cp.hashes.count == cp.result.artifacts.count && !cp.hashes.isEmpty
                                && zip(cp.result.artifacts, cp.hashes).allSatisfy { (try? Files.hash($0.0.url)) == $0.1 }
                            if !valid || (try? processor.validate(cp.result, within: chunkDirectory)) == nil { checkpoint = nil }
                        }
                        if let cp = checkpoint {
                            try await commitPending()
                            artifacts += NativeMLXBackend.assemblyArtifacts(for: cp.request, result: cp.result, gapSeconds: p.gapSeconds)
                            transcriptTexts.append(cp.request.preparedUtterance?.text ?? cp.request.text)
                            transcriptArtifactCounts.append(cp.result.artifacts.count)
                            progress(.synthesizing, chunk.index + 1, plan.chunks.count)
                            continue
                        }
                        if !prepared { try backend.prepare(); prepared = true }
                        let result: SynthesisResult
                        do {
                            if let lookahead = backend as? any LookaheadTTSBackend {
                                let next = position + 1 < plan.chunks.count ? requestFor(plan.chunks[position + 1]) : nil
                                result = try lookahead.synthesize(request, directory: chunkDirectory, next: next)
                            } else { result = try backend.synthesize(request, directory: chunkDirectory) }
                        } catch is CancellationError { throw CancellationError() }
                        catch let error as RelayError { throw error }
                        catch { throw RelayError.artifact("Fixture backend failed; completed chunks are retained.") }
                        // One validation/checkpoint may overlap the next inference; it is
                        // always joined before another validation or any cleanup starts.
                        try await commitPending()
                        let articleID = e.id
                        pendingIndex = chunk.index
                        pending = Task.detached(priority: .userInitiated) {
                            try diagnostics.measure(.validation, chunk: chunk.index) { try processor.validate(result, within: chunkDirectory) }
                            let cp = ChunkCheckpoint(request: request, result: result,
                                hashes: try result.artifacts.map { try Files.hash($0.url, description: "generated speech chunk") })
                            try diagnostics.measure(.checkpoint, chunk: chunk.index) {
                                try store.saveChunk(articleID: articleID, index: chunk.index, fingerprint: fingerprint, checkpoint: cp)
                            }
                            return cp
                        }
                        syntheses += 1
                        if context == nil { try await commitPending() }
                    }
                    try await commitPending()
                } catch {
                    // Preserve a completed predecessor even when the next inference fails.
                    if let task = pending {
                        if error is CancellationError { task.cancel() }
                        _ = await task.result
                    }
                    throw error
                }
                try await handoffSpeech()
                e.stage = .encoding; try store.save(e); progress(.encoding, plan.chunks.count, plan.chunks.count)
                var timeline: [AudioOutput.AudioSegmentTiming] = []
                let (_, info) = try processor.encode(artifacts, in: directory) { timeline = $0 }
                e.info = info; e.encodedHash = try Files.hash(encoded, description: "encoded audio")
                e.transcript = p.publishTranscripts == true ? try EpisodeTranscript.make(texts: transcriptTexts,
                    artifactCounts: transcriptArtifactCounts, timeline: timeline, language: p.language, audioHash: e.encodedHash!) : nil
                e.transcriptReferences = nil
                e.synthesisFingerprint = inputFingerprint
            }
            try await handoffSpeech()
            let publicationSource = placedAudioValid ? destination : encoded
            try processor.decode(publicationSource)
            e.stage = .encoded
            if e.publicationDate == nil { e.publicationDate = Date() }
            try store.save(e); try boundary(.encoded)
            guard let encodedHash = e.encodedHash else { throw RelayError.artifact("Encoded checkpoint has no integrity record.") }
            try diagnostics.measure(.publication) {
                try processor.publish(publicationSource, destination: destination, expectedHash: encodedHash, inMediaDirectory: storage != nil)
            }
            try boundary(.audioPlaced)
            // Origin metadata is captured at the commit whether or not delivery is enabled.
            e.audioHash = encodedHash; e.stage = .published; e.localAudioReleased = nil
            e.localAudioDiscarded = nil; e.localCleanupNotice = nil
            e.author = article.author
            e.sourceHost = article.archivedCopy == nil ? (article.finalURL.host ?? article.originalURL.host) : article.originalURL.host
            e.originalSourceHost = article.originalURL.host
            e.sourceURL = article.archivedCopy == nil ? (article.canonicalURL ?? article.finalURL) : article.originalURL
            e.artworkURL = article.previewImageURL
            if let delivery {
                e.delivery = DeliveryState(status: .pending, remotePath: delivery.remoteMediaPath(e.id))
            }
            try store.save(e, pendingFeed: true); try boundary(.episodeCommitted)
        }
        try await handoffSpeech()
        guard let committedHash = e.audioHash, try Files.hash(destination, description: "saved audio") == committedHash else {
            throw RelayError.artifact("Published media integrity failed; previous feed is preserved.")
        }
        _ = try processor.probe(destination, final: true); try processor.decode(destination)
        if e.author == nil, e.sourceURL == nil {
            e.author = article.author
            e.sourceHost = article.archivedCopy == nil ? (article.finalURL.host ?? article.originalURL.host) : article.originalURL.host
            e.originalSourceHost = article.originalURL.host
            e.sourceURL = article.archivedCopy == nil ? (article.canonicalURL ?? article.finalURL) : article.originalURL
            e.artworkURL = article.previewImageURL
            try store.save(e)
        }
        if let delivery, e.delivery == nil {
            e.delivery = DeliveryState(status: .pending, remotePath: delivery.remoteMediaPath(e.id))
            try store.save(e)
        }
        if let delivery, e.delivery?.status == .pending {
            var ledger = try DeliveryLedger.load(stateRoot: root)
            ledger.remoteFeedPending = true
            ledger.settingsHash = Files.hash(try Files.json(delivery))
            try ledger.save(stateRoot: root)
        }
        let feed = try RSS.render(store.published(), settings: p)
        if (try? Data(contentsOf: p.feed)) != feed { try Files.write(feed, to: p.feed) }
        try boundary(.feedReplaced)
        try store.markFeed(Files.hash(feed)); progress(.published, plan.chunks.count, plan.chunks.count)
        if storage != nil {
            e.audioFinalizationComplete = true
            try store.save(e)
        }
        if storage != nil { try? FileManager.default.removeItem(at: directory) }
        return FixtureResult(episode: e, audioURL: destination, feedURL: p.feed, article: article, narration: plan,
                             synthesizedChunks: syntheses, localFeedCurrent: true,
                             remoteDelivery: delivery == nil ? "disabled" : (e.delivery?.status.rawValue ?? "pending"))
    }
}

private struct Fingerprint: Codable {
    let request: SynthesisRequest
    let backend: BackendIdentity
    let extraction: String
    let narration: String
}
private struct EncodingFingerprint: Codable {
    let backend: BackendIdentity
    let profile: PrototypeProfile
    let extraction: String
    let narration: NarrationPlan
    let audioProcessing: String
}
