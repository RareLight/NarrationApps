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

enum FixtureWorkspace {
    static let markerText = "VoiceRelay isolated fixture workspace v1\n"
    static func prepare(root: URL, imported: PrototypeProfile?, speech: Bool = false) throws -> PrototypeProfile {
        let markerText = speech ? "VoiceRelay isolated speech workspace v1\n" : Self.markerText
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
    public func run(root: URL, imported: PrototypeProfile? = nil,
                    backend: any TTSBackend = MockToneBackend(), interruptAfter: FixtureBoundary? = nil,
                    onBoundary: @Sendable (FixtureBoundary) -> Void = { _ in },
                    onProgress: @Sendable (PipelineProgress) -> Void = { _ in }) throws -> FixtureResult {
        try Task.checkCancellation()
        guard backend.identity.isMock else { throw RelayError.setup("This command accepts fixture backends only; live narration belongs to a later slice.") }
        return try execute(root: root, imported: imported, backend: backend, speech: false,
                           interruptAfter: interruptAfter, onBoundary: onBoundary, onProgress: onProgress)
    }
    public func runSpeech(root: URL, imported: PrototypeProfile? = nil, backend: any TTSBackend,
                          voice: String? = nil, speed: Double? = nil,
                          interruptAfter: FixtureBoundary? = nil,
                          onProgress: @Sendable (PipelineProgress) -> Void = { _ in }) throws -> FixtureResult {
        guard !backend.identity.isMock else { throw RelayError.setup("Speech checks require an explicitly selected real-speech provider.") }
        return try execute(root: root, imported: imported, backend: backend, speech: true,
                           speechVoice: voice, speechSpeed: speed,
                           interruptAfter: interruptAfter, onBoundary: { _ in }, onProgress: onProgress)
    }
    private func execute(root: URL, imported: PrototypeProfile?, backend: any TTSBackend, speech: Bool,
                         speechVoice: String? = nil, speechSpeed: Double? = nil,
                         interruptAfter: FixtureBoundary?, onBoundary: @Sendable (FixtureBoundary) -> Void,
                         onProgress: @Sendable (PipelineProgress) -> Void) throws -> FixtureResult {
        try Task.checkCancellation()
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        var selected = try FixtureWorkspace.prepare(root: root, imported: imported, speech: speech)
        if speech {
            selected.backendSelector = "speech-fixture"
            selected.voice = speechVoice ?? imported?.voice
            selected.backendSettings = imported?.backendSettings ?? [:]
            if let speechSpeed { selected.backendSettings["speed"] = .number(speechSpeed) }
            selected.channelTitle = "VoiceRelay Speech Fixture"
            selected.channelDescription = "Isolated synthetic article — real speech; remote delivery disabled"
            try selected.validate()
        }
        guard ToolRunner.locate(selected.ffmpeg) != nil, ToolRunner.locate(selected.ffprobe) != nil else {
            throw RelayError.setup("Install ffmpeg/ffprobe or select their executable paths in the imported profile.")
        }
        let store = try NativeStore(url: selected.database)
        var e = try store.episode(sourceKey: "bundled-synthetic-article-v1", settings: selected)
        let p = e.settings // Capture relevant settings once; subsequent profile changes affect new work.
        guard Files.samePath(p.database, selected.database), Files.samePath(p.work, selected.work),
              Files.samePath(p.audio, selected.audio), Files.samePath(p.feed, selected.feed),
              p.backendSelector == (speech ? "speech-fixture" : "mock"), p.webdavURL == nil else {
            throw RelayError.setup("Saved fixture profile does not match this workspace. Moving/adopting state requires an explicit import.")
        }
        let directory = p.work.appendingPathComponent(e.id)
        guard Files.contains(p.work, directory), !Files.hasSymlink(directory, below: p.work) else {
            throw RelayError.setup("Episode work must remain inside its fixture without symlinks.")
        }
        try Files.directory(directory)
        let processor = AudioProcessor(settings: p, toolDirectory: directory)
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
        let bundled = try FixtureResource.html(); let sourceHash = Files.hash(bundled)
        var article: SemanticArticle?
        var plan: NarrationPlan?
        if let bytes = try? Data(contentsOf: extractionFile),
           let cp = try? JSONDecoder().decode(ExtractionCheckpoint.self, from: bytes),
           cp.sourceHash == sourceHash,
           (e.stage == .published || (cp.extractorVersion == ArticleExtractor.version && cp.narrationVersion == Narration.version)),
           (try? Files.hash(source)) == sourceHash, (try? Files.hash(articleFile)) == cp.articleHash,
           (try? Files.hash(narrationFile)) == cp.narrationHash, (try? Files.hash(cleanedFile)) == cp.cleanedHash {
            article = try? JSONDecoder().decode(SemanticArticle.self, from: Data(contentsOf: articleFile))
            plan = try? JSONDecoder().decode(NarrationPlan.self, from: Data(contentsOf: narrationFile))
        }
        if article == nil || plan == nil {
            guard e.stage != .published else { throw RelayError.artifact("Published semantic checkpoint is damaged; inspect private artifacts before repair.") }
            e.stage = .fetching; try store.save(e); progress(.fetching)
            if (try? Files.hash(source)) != sourceHash { try Files.write(bundled, to: source) }
            guard let html = String(data: bundled, encoding: .utf8), bundled.count <= p.maxArticleBytes else {
                throw RelayError.extraction("Fixture HTML exceeds configured bounds or has an unsupported encoding.")
            }
            let page = URL(string: "https://articles.example/fixture")!
            let document = try ArticleExtractor.extract(html: html, originalURL: page, finalURL: page)
            let narration = try Narration.prepare(document.article, limit: p.chunkMaxCharacters)
            try Files.write(try Files.json(document.article), to: articleFile)
            try Files.write(try Files.json(narration), to: narrationFile)
            try Files.write(Data(document.cleanedHTML.utf8), to: cleanedFile)
            let cp = ExtractionCheckpoint(sourceHash: sourceHash, extractorVersion: ArticleExtractor.version, narrationVersion: Narration.version,
                                          articleHash: try Files.hash(articleFile), narrationHash: try Files.hash(narrationFile), cleanedHash: try Files.hash(cleanedFile))
            try Files.write(try Files.json(cp), to: extractionFile)
            article = document.article; plan = narration; e.title = document.article.title
            e.encodedHash = nil; e.info = nil; e.stage = .extracted; try store.save(e)
        }
        guard let article, let plan else { throw RelayError.artifact("Extraction checkpoint is invalid.") }
        progress(e.stage, 0, plan.chunks.count)
        let encoded = directory.appendingPathComponent("episode.m4a")
        let destination = p.audio.appendingPathComponent(e.id + ".m4a")
        var syntheses = 0
        let inputFingerprint = Files.hash(try Files.json(EncodingFingerprint(backend: backend.identity,
            profile: p, extraction: article.extractorVersion, narration: plan)))
        if e.stage != .published {
            let encodedValid = e.encodedHash != nil && (try? Files.hash(encoded)) == e.encodedHash
                && e.synthesisFingerprint == inputFingerprint
                && (try? processor.probe(encoded, final: true)) != nil
            if !encodedValid {
                e.stage = .synthesizing; try store.save(e); progress(.synthesizing, 0, plan.chunks.count)
                defer { backend.cancel() }; try backend.prepare()
                var artifacts: [LosslessArtifact] = []
                for chunk in plan.chunks {
                    try Task.checkCancellation()
                    let chunkDirectory = directory.appendingPathComponent("chunk-\(chunk.index)")
                    guard Files.contains(directory, chunkDirectory), !Files.hasSymlink(chunkDirectory, below: directory) else {
                        throw RelayError.setup("Chunk work must remain inside its fixture without symlinks.")
                    }
                    try Files.directory(chunkDirectory)
                    let request = SynthesisRequest(text: chunk.text, language: p.language, voice: p.voice, articleID: e.id,
                                                   chunkIndex: chunk.index, blockIndices: chunk.blockIndices, settings: p.backendSettings)
                    let fingerprint = Files.hash(try Files.json(Fingerprint(request: request, backend: backend.identity,
                                                                         extraction: article.extractorVersion, narration: plan.version)))
                    var checkpoint = try store.chunk(articleID: e.id, index: chunk.index, fingerprint: fingerprint)
                    if let cp = checkpoint {
                        let valid = cp.hashes.count == cp.result.artifacts.count && !cp.hashes.isEmpty
                            && zip(cp.result.artifacts, cp.hashes).allSatisfy { (try? Files.hash($0.0.url)) == $0.1 }
                        if !valid || (try? processor.validate(cp.result, within: chunkDirectory)) == nil { checkpoint = nil }
                    }
                    if checkpoint == nil {
                        let result: SynthesisResult
                        do { result = try backend.synthesize(request, directory: chunkDirectory) }
                        catch is CancellationError { throw CancellationError() }
                        catch let error as RelayError { throw error }
                        catch { throw RelayError.artifact("Fixture backend failed; completed chunks are retained.") }
                        try processor.validate(result, within: chunkDirectory)
                        let cp = ChunkCheckpoint(request: request, result: result, hashes: try result.artifacts.map { try Files.hash($0.url) })
                        try store.saveChunk(articleID: e.id, index: chunk.index, fingerprint: fingerprint, checkpoint: cp)
                        checkpoint = cp; syntheses += 1
                        try boundary(.chunkCommitted)
                    }
                    artifacts += checkpoint!.result.artifacts
                    progress(.synthesizing, chunk.index + 1, plan.chunks.count)
                }
                e.stage = .encoding; try store.save(e); progress(.encoding, plan.chunks.count, plan.chunks.count)
                let (_, info) = try processor.encode(artifacts, in: directory)
                e.info = info; e.encodedHash = try Files.hash(encoded)
                e.synthesisFingerprint = inputFingerprint
            }
            try processor.decode(encoded)
            e.stage = .encoded
            if e.publicationDate == nil { e.publicationDate = Date() }
            try store.save(e); try boundary(.encoded)
            guard let encodedHash = e.encodedHash else { throw RelayError.artifact("Encoded checkpoint has no integrity record.") }
            try processor.publish(encoded, destination: destination, expectedHash: encodedHash)
            try boundary(.audioPlaced)
            e.audioHash = encodedHash; e.stage = .published
            try store.save(e, pendingFeed: true); try boundary(.episodeCommitted)
        }
        guard let committedHash = e.audioHash, try Files.hash(destination) == committedHash else {
            throw RelayError.artifact("Published media integrity failed; previous feed is preserved.")
        }
        _ = try processor.probe(destination, final: true); try processor.decode(destination)
        let feed = try RSS.render(store.published(), settings: p)
        if (try? Data(contentsOf: p.feed)) != feed { try Files.write(feed, to: p.feed) }
        try boundary(.feedReplaced)
        try store.markFeed(Files.hash(feed)); progress(.published, plan.chunks.count, plan.chunks.count)
        return FixtureResult(episode: e, audioURL: destination, feedURL: p.feed, article: article, narration: plan,
                             synthesizedChunks: syntheses, localFeedCurrent: true, remoteDelivery: "disabled-fixture")
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
}
