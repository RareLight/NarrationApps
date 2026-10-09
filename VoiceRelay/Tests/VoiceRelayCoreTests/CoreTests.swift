import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Testing
import CSQLite
@testable import VoiceRelayCore

private func temporary() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("voicerelay-test-\(UUID().uuidString)")
    try Files.directory(url); return url
}

private func config(at root: URL, suffix: String = "") throws -> URL {
    let file = root.appendingPathComponent("config.toml")
    let text = """
    safari_plist = "~/Library/Safari/Bookmarks.plist"
    database_path = "live/state.sqlite3"
    working_directory = "live/work"
    audio_output_directory = "live/media"
    feed_path = "live/feed.xml"
    public_audio_base_url = "https://audio.invalid/podcast/"
    feed_url = "https://feed.invalid/feed.xml"
    channel_title = "Custom & Private"
    channel_description = "Preserve this description"
    default_tts_backend = "python_adapter:Backend"
    aac_bitrate = "48k"
    sample_rate = 22050
    loudness_lufs = -18
    segment_gap_seconds = 0.2
    chunk_max_chars = 140
    tts_config = { speed = 1.1, nested = { mode = "custom" } }
    \(suffix)
    """
    try text.write(to: file, atomically: true, encoding: .utf8); return file
}

@Test func audioEncodingDefaultsUse96kAndIgnoreLegacyLoudnessPolicy() throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let profile = PrototypeProfile.fixture(at: root)
    #expect(profile.bitrate == "96k")
    #expect(ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"),
        stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch")).profile.bitrate == "96k")
    let file = try config(at: root)
    let text = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "aac_bitrate = \"48k\"", with: "")
    try text.write(to: file, atomically: true, encoding: .utf8)
    let imported = try PrototypeProfile.load(file)
    #expect(imported.bitrate == "96k")
    #expect(imported.compatibilityNotices.contains { $0.contains("without normalization") })
    var historical = profile; historical.loudnessLUFS = -99
    try historical.validate() // Historical loudness metadata cannot impose an active policy.
}

@Test func audioEncodingPreservesOriginalLevelsDynamicsFloatSamplesAndGaps() throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    var profile = PrototypeProfile.fixture(at: root)
    profile.gapSeconds = 0.25; profile.loudnessLUFS = -10
    let processor = AudioProcessor(settings: profile, toolDirectory: root)
    var artifacts: [LosslessArtifact] = []
    for (index, amplitude) in [0.020001, 0.20001].enumerated() {
        let path = root.appendingPathComponent("input-\(index).wav")
        _ = try ToolRunner.run(profile.ffmpeg,
            ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i",
             "aevalsrc=\(amplitude)*sin(2*PI*440*t):s=24000:d=2", "-c:a", "pcm_f32le", path.path],
            timeout: 10, directory: root)
        artifacts.append(LosslessArtifact(url: path, sampleRate: 24000, channels: 1, format: "wav"))
    }
    let (encoded, info) = try processor.encode(artifacts, in: root)
    #expect(info.codec == "aac" && info.channels == 1 && info.sampleRate == 24000)
    #expect(abs(info.duration - 4.25) < 0.02)
    func floats(_ data: Data) -> [Double] {
        data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map {
                Double(Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self))))
            }
        }
    }
    let combined = floats(try Data(contentsOf: root.appendingPathComponent("combined.pcm")))
    #expect(combined.count == 24000 * 4 + 6000)
    #expect(combined[(24000 * 2)..<(24000 * 2 + 6000)].allSatisfy { $0 == 0 })
    let source = try ToolRunner.run(profile.ffmpeg,
        ["-nostdin", "-v", "error", "-i", artifacts[0].url.path, "-c:a", "pcm_f32le", "-f", "f32le", "-"],
        timeout: 10, directory: root)
    #expect(Array(combined.prefix(48000)) == floats(source))
    let decoded = floats(try ToolRunner.run(profile.ffmpeg,
        ["-nostdin", "-v", "error", "-xerror", "-i", encoded.path, "-c:a", "pcm_f32le", "-f", "f32le", "-"],
        timeout: 10, directory: root))
    func rms(_ seconds: Range<Double>) -> Double {
        let samples = decoded[Int(seconds.lowerBound * 24000)..<Int(seconds.upperBound * 24000)]
        return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count))
    }
    let quiet = rms(0.5..<1.5), loud = rms(2.75..<3.75)
    #expect(abs(20 * log10(quiet / (0.020001 / sqrt(2)))) < 0.5)
    #expect(abs(20 * log10(loud / (0.20001 / sqrt(2)))) < 0.5)
    #expect(abs(20 * log10(loud / quiet) - 20) < 0.5)
}

@Test(arguments: ["64k", "96k"], [FixtureBoundary.encoded, .audioPlaced])
func audioPolicyUpgradeReencodesLegacyScratchRetainsSpeechAndPreservesPlacedAudio(_ oldBitrate: String, _ boundary: FixtureBoundary) async throws {
    struct PreviousEncodingFingerprint: Encodable {
        let backend: BackendIdentity
        let profile: PrototypeProfile
        let extraction: String
        let narration: NarrationPlan
    }
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    try Files.directory(root.appendingPathComponent("audio"))
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"),
        stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator(), backend = SyntheticSpeechContractBackend("audio-policy")
    let review = try reviewedArticle()
    let item = try await coordinator.enqueue(review, storage: storage,
        preferences: SpeechPreferences(voice: .heart, speed: 1.25))
    do {
        _ = try await coordinator.runReviewed(root: storage.stateRoot, review: review, backend: backend,
            voice: "af_heart", speed: 1.25, interruptAfter: .encoded, storage: storage)
        Issue.record("Expected interruption")
    } catch { #expect(error as? RelayError == .interrupted) }
    var episode = try #require(await coordinator.library(storage: storage).first)
    episode.settings.bitrate = oldBitrate
    let directory = episode.settings.work.appendingPathComponent(item.id)
    let encoded = directory.appendingPathComponent("episode.m4a")
    // Authentic old encoded checkpoint: normalized signal and pre-policy fingerprint.
    _ = try ToolRunner.run(episode.settings.ffmpeg,
        ["-nostdin", "-v", "error", "-y", "-f", "f32le", "-ar", "24000", "-ac", "1", "-i",
         directory.appendingPathComponent("combined.pcm").path, "-af", "loudnorm=I=-16:TP=-1.5:LRA=11",
         "-c:a", "aac", "-profile:a", "aac_low", "-b:a", oldBitrate, "-ac", "1", "-ar", "24000", encoded.path],
        timeout: 10, directory: directory)
    let oldHash = try Files.hash(encoded)
    episode.encodedHash = oldHash
    episode.info = try AudioProcessor(settings: episode.settings, toolDirectory: directory).probe(encoded, final: true)
    episode.synthesisFingerprint = Files.hash(try Files.json(PreviousEncodingFingerprint(backend: backend.identity,
        profile: episode.settings, extraction: #require(review.document).article.extractorVersion,
        narration: #require(review.narration))))
    let oldFingerprint = episode.synthesisFingerprint
    let chunks: [[String]]
    do {
        let store = try NativeStore(url: storage.profile.database)
        try store.save(episode)
        chunks = try store.query("SELECT fingerprint,checkpoint FROM chunks ORDER BY chunk_index")
    }
    if boundary == .audioPlaced {
        try FileManager.default.copyItem(at: encoded, to: episode.settings.audio.appendingPathComponent(item.id + ".m4a"))
    }
    let result = try await coordinator.resume(storage: storage, articleID: item.id, backend: backend)
    #expect(result.synthesizedChunks == 0 && result.episode.id == item.id)
    #expect(result.episode.settings.voice == "af_heart" && result.episode.settings.backendSettings["speed"]?.numericValue == 1.25)
    #expect(try NativeStore(url: storage.profile.database, readOnly: true).query("SELECT fingerprint,checkpoint FROM chunks ORDER BY chunk_index") == chunks)
    if boundary == .encoded {
        #expect(result.episode.settings.bitrate == "96k")
        #expect(result.episode.audioHash != oldHash && result.episode.synthesisFingerprint != oldFingerprint)
    } else {
        #expect(result.episode.settings.bitrate == oldBitrate)
        #expect(try Files.hash(result.audioURL) == oldHash)
    }
    let publishedHash = try Files.hash(result.audioURL), feed = try Data(contentsOf: result.feedURL)
    let again = try await coordinator.resume(storage: storage, articleID: item.id, backend: backend)
    #expect(again.synthesizedChunks == 0 && again.episode.settings.bitrate == result.episode.settings.bitrate)
    #expect(try Files.hash(again.audioURL) == publishedHash && Data(contentsOf: again.feedURL) == feed)
}

@Test func configurationPreservesCustomizedValuesWithoutWriting() throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let file = try config(at: root); let before = try Data(contentsOf: file)
    let p = try PrototypeProfile.load(file)
    #expect(p.database.path == root.appendingPathComponent("live/state.sqlite3").path)
    #expect(p.safariPlist.path.hasSuffix("Library/Safari/Bookmarks.plist"))
    #expect(p.channelTitle == "Custom & Private")
    #expect(p.bitrate == "48k" && p.sampleRate == 22050 && p.gapSeconds == 0.2 && p.loudnessLUFS == -18)
    #expect(p.backendSelector == "python_adapter:Backend" && !p.compatibilityNotices.isEmpty)
    #expect(p.backendSettings["speed"] == .number(1.1))
    #expect(try Data(contentsOf: file) == before)
    #expect(!FileManager.default.fileExists(atPath: p.database.path))
    let fixture = p.isolated(at: root.appendingPathComponent("fixture"))
    #expect(fixture.backendSelector == "speech-fixture" && fixture.webdavURL == nil)
    #expect(fixture.feedURL.host == "fixture.invalid" && fixture.bitrate == p.bitrate)
    #expect(fixture.channelTitle != p.channelTitle)
}

@Test(arguments: ["http://feed.invalid/x", "https://user:password@feed.invalid/x", "https://feed.invalid/x?q=private", "https://feed.invalid/x#fragment", "https://feed.invalid:0/x"])
func unsafeDeliveryURLsRejected(_ value: String) {
    #expect(throws: RelayError.self) { try PrototypeProfile.https(value) }
}

@Test func invalidConfigIsSafeAndPathOverlapRejected() throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let file = try config(at: root, suffix: "password = \"do-not-copy\"")
    // Unknown fields remain in the source document, never in the native profile/checkpoint.
    let p = try PrototypeProfile.load(file)
    #expect(!String(decoding: try Files.json(p), as: UTF8.self).contains("do-not-copy"))
    var overlapping = p; overlapping.work = p.audio.appendingPathComponent("private")
    #expect(throws: RelayError.self) { try overlapping.validate() }
    var secret = p; secret.backendSettings = ["password": .string("sensitive")]
    #expect(throws: RelayError.self) { try secret.validate() }
    secret.backendSettings = ["options": .array([.object(["password": .string("sensitive")])])]
    #expect(throws: RelayError.self) { try secret.validate() }
    try "sample_rate = \"private-value\"".write(to: file, atomically: true, encoding: .utf8)
    do { _ = try PrototypeProfile.load(file); Issue.record("Malformed profile accepted") }
    catch { #expect(!error.localizedDescription.contains("private-value")) }
}

@Test func sourceExtractionPreservesStructureAndRejectsEmptyContent() throws {
    let data = try FixtureResource.html()
    let page = URL(string: "https://articles.example/fixture")!
    let document = try ArticleExtractor.extract(html: String(decoding: data, as: UTF8.self), originalURL: page, finalURL: page)
    let a = document.article
    #expect(a.title.contains("Reading"))
    #expect(a.blocks.contains { $0.kind == .heading && $0.text == "A second section" })
    #expect(a.blocks.filter { $0.kind == .listItem }.count == 2)
    #expect(a.blocks.contains { $0.kind == .quote })
    let text = a.blocks.map(\.text).joined(separator: "\n")
    #expect(text.contains("This is the first paragraph") && text.contains("This final paragraph"))
    #expect(!text.contains("Home About") && !text.contains("Copyright Synthetic"))
    #expect(a.canonicalURL?.path == "/private-canonical")
    #expect(throws: (any Error).self) { try ArticleExtractor.extract(html: "<html><body></body></html>", originalURL: page, finalURL: page) }
}

@Test func semanticBlocksKeepNestedOrderAndSpecialStructures() throws {
    let html = "<div><p>Before <a href='/private'>meaningful label</a>.</p><blockquote>Opening<p>Quoted paragraph</p>Closing</blockquote><ul><li>Parent<ul><li>Nested</li></ul>After</li></ul><pre>let x = 1</pre><table><tr><td>Cell</td></tr></table><figcaption>Café 日本語</figcaption><aside role='doc-footnote'>Footnote</aside></div>"
    let blocks = try ArticleExtractor.semanticBlocks(html: html, baseURL: URL(string: "https://articles.example/final/")!)
    #expect(blocks.map(\.text) == ["Before meaningful label.", "Opening", "Quoted paragraph", "Closing", "Parent", "Nested", "After", "let x = 1", "Cell", "Café 日本語", "Footnote"])
    #expect(blocks.contains { $0.kind == .table } && blocks.contains { $0.kind == .footnote })
    let a = SemanticArticle(title: "Special", originalURL: URL(string: "https://articles.example")!, finalURL: URL(string: "https://articles.example")!, canonicalURL: nil, author: nil, blocks: blocks, warnings: [], extractorVersion: ArticleExtractor.version)
    let plan = try Narration.prepare(a, limit: 50)
    #expect(plan.notices.count >= 3)
    #expect(plan.chunks.map(\.text).joined().contains("Table omitted"))
    #expect(!plan.chunks.map(\.text).joined().contains("let x = 1"))
    #expect(plan.chunks.allSatisfy { $0.text.count <= 50 })
}

@Test func narrationHasBoundsUnicodeAndLosslessLongTokenFallback() throws {
    let text = "Café 2026 costs $42. " + String(repeating: "界", count: 137)
    let block = ContentBlock(kind: .paragraph, text: text)
    let a = SemanticArticle(title: "Bounded", originalURL: URL(string: "https://example.com")!, finalURL: URL(string: "https://example.com")!, canonicalURL: nil, author: nil, blocks: [block], warnings: [], extractorVersion: "test")
    let plan = try Narration.prepare(a, limit: 30)
    #expect(a.blocks[0].text == text)
    #expect(plan.chunks.allSatisfy { $0.text.count <= 30 && ($0.blockIndices == [0] || $0.blockIndices.isEmpty) })
    #expect(plan.chunks.map(\.text).joined().filter { $0 == "界" }.count == 137)
    #expect(plan.chunks.map(\.text).joined().contains("Café 2026 costs $42."))
}

@Test func narrationOmitsStandaloneDecorativeQuotesWithoutDroppingContent() throws {
    let url = URL(string: "https://articles.example/synthetic-quotes")!
    let texts = ["Before the quotation.", "\u{275D}", "\u{275D} Meaningful quoted words. \u{275E}", "\u{275E}", "\u{2019}", "After the quotation.", "42", "Café 日本語"]
    let blocks = texts.map { ContentBlock(kind: .paragraph, text: $0) }
    let article = SemanticArticle(title: "Synthetic quotation", originalURL: url, finalURL: url,
                                  canonicalURL: nil, author: nil, blocks: blocks, warnings: [], extractorVersion: "test")
    let plan = try Narration.prepare(article, limit: 1800)
    #expect(article.blocks.map(\.text) == texts)
    #expect(plan.chunks.filter { !$0.blockIndices.isEmpty }.map(\.text) == [texts[0], texts[2], texts[5], texts[6], texts[7]])
    #expect(plan.chunks.filter { !$0.blockIndices.isEmpty }.map(\.blockIndices) == [[0], [2], [5], [6], [7]])
    #expect(plan.notices.filter { $0.contains("decorative quotation") }.count == 3)
    let decoration = SemanticArticle(title: "Synthetic decoration", originalURL: url, finalURL: url,
                                    canonicalURL: nil, author: nil, blocks: [blocks[1]], warnings: [], extractorVersion: "test")
    #expect(throws: RelayError.self) { try Narration.prepare(decoration, limit: 1800) }
}

@Test func narrationOmitsDecorativeSeparatorsAndPreservesMeaningfulSymbols() throws {
    let url = URL(string: "https://articles.example/separators")!
    let separators = ["--", "•", "|", "— — —", "* * *", "…", "___", "• | --"]
    let content = ["Before the break.", "C++ costs $42.", "x | y", "42", "Café 日本語", "Words -- still belong here."]
    let texts = separators + content
    let article = SemanticArticle(title: "Synthetic separators", originalURL: url, finalURL: url, canonicalURL: nil,
        author: nil, blocks: texts.map { ContentBlock(kind: .paragraph, text: $0) }, warnings: [], extractorVersion: "test")
    let plan = try Narration.prepare(article, limit: 1800)
    #expect(article.blocks.map(\.text) == texts)
    #expect(plan.chunks.filter { !$0.blockIndices.isEmpty }.map(\.text) == content)
    #expect(plan.notices.filter { $0.contains("decorative separator") }.count == separators.count)
    #expect(plan.chunks.first?.text.contains("Source: articles.example.") == true && plan.chunks.last?.text == "End of article.")
    let decoration = SemanticArticle(title: "Separators only", originalURL: url, finalURL: url, canonicalURL: nil,
        author: nil, blocks: separators.map { ContentBlock(kind: .paragraph, text: $0) }, warnings: [], extractorVersion: "test")
    #expect(throws: RelayError.self) { try Narration.prepare(decoration, limit: 1800) }
}

@Test func queueOriginCapturesOriginalSiteAndRecoversLegacyRowsReadOnly() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    try Files.directory(root.appendingPathComponent("audio"))
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"), stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator(), review = try reviewedArticle(host: "origin.example")
    let item = try await coordinator.enqueue(review, storage: storage, preferences: SpeechPreferences())
    #expect(item.sourceHost == "origin.example")
    let raw: String
    do {
        let store = try NativeStore(url: storage.profile.database)
        var legacy = try #require(JSONSerialization.jsonObject(with: Files.json(item)) as? [String: Any])
        legacy.removeValue(forKey: "sourceHost")
        let bytes = try JSONSerialization.data(withJSONObject: legacy)
        #expect(try JSONDecoder().decode(SpeechQueueItem.self, from: bytes).sourceHost == nil)
        raw = String(decoding: bytes, as: UTF8.self)
        try store.execute("UPDATE speech_queue SET record=? WHERE article_id=?", [raw, item.id])
    }
    let recovered = try #require(await coordinator.queue(stateRoot: storage.stateRoot).first)
    #expect(recovered.sourceHost == "origin.example" && recovered.id == item.id)
    do { #expect(try NativeStore(url: storage.profile.database, readOnly: true).query("SELECT record FROM speech_queue WHERE article_id=?", [item.id]).first?.first == raw) }
}

@Test func separatorNarrationUpgradeRetainsCompatibleCompletedChunk() async throws {
    struct PreviousFingerprint: Encodable {
        let request: SynthesisRequest
        let backend: BackendIdentity
        let extraction: String
        let narration: String
    }
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    try Files.directory(root.appendingPathComponent("audio"))
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"), stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let url = URL(string: "https://articles.example/legacy-separator")!
    let html = String(decoding: try FixtureResource.html(), as: UTF8.self).replacingOccurrences(of: "</article>", with: "<p>--</p></article>")
    let review = try ReviewedSource.prepare(FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html,
        contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast), chunkLimit: 1800)
    let coordinator = FixtureCoordinator(), backend = SyntheticSpeechContractBackend("separator-upgrade")
    let item = try await coordinator.enqueue(review, storage: storage, preferences: SpeechPreferences())
    do {
        _ = try await coordinator.runReviewed(root: storage.stateRoot, review: review, backend: backend,
            interruptAfter: .chunkCommitted, storage: storage)
        Issue.record("Expected interruption")
    } catch { #expect(error as? RelayError == .interrupted) }
    let episode = try #require(await coordinator.library(storage: storage).first)
    let current = try #require(review.narration), article = try #require(review.document?.article)
    let first = try #require(current.chunks.first)
    let request = SynthesisRequest(text: first.text, language: episode.settings.language, voice: episode.settings.voice,
        articleID: item.id, chunkIndex: first.index, blockIndices: first.blockIndices, settings: episode.settings.backendSettings)
    let oldVersion = "conservative-2/footnotes-1/sentence-chunks-1/decorative-quotes-1/article-boundaries-1"
    let expected = Files.hash(try Files.json(PreviousFingerprint(request: request, backend: backend.identity,
        extraction: article.extractorVersion, narration: oldVersion)))
    // Restore an authentic older plan containing a separator and the same completed request.
    do {
        let store = try NativeStore(url: storage.profile.database)
        #expect(try store.query("SELECT fingerprint FROM chunks WHERE article_id=? AND chunk_index=0", [item.id]).first?.first == expected)
        var files = try JSONDecoder().decode(StoredExtraction.self, from: #require(try store.snapshot(articleID: item.id))).files
        let separatorIndex = try #require(article.blocks.firstIndex { $0.text == "--" })
        let chunks = Array(current.chunks.dropLast()) + [NarrationChunk(index: current.chunks.count - 1, text: "--", blockIndices: [separatorIndex]),
            NarrationChunk(index: current.chunks.count, text: "End of article.", blockIndices: [])]
        files["narration.json"] = try Files.json(NarrationPlan(version: oldVersion, chunks: chunks, notices: []))
        var checkpoint = try #require(JSONSerialization.jsonObject(with: files["extraction-checkpoint.json"]!) as? [String: Any])
        checkpoint["narrationVersion"] = oldVersion
        checkpoint["narrationHash"] = Files.hash(files["narration.json"]!)
        files["extraction-checkpoint.json"] = try JSONSerialization.data(withJSONObject: checkpoint)
        try store.saveSnapshot(articleID: item.id, data: Files.json(["files": files]))
        let directory = episode.settings.work.appendingPathComponent(item.id)
        for (name, data) in files { try Files.write(data, to: directory.appendingPathComponent(name)) }
    }
    let result = try await coordinator.resume(storage: storage, articleID: item.id, backend: backend)
    #expect(result.narration.version == Narration.version && result.narration.chunks.allSatisfy { $0.text != "--" })
    #expect(result.synthesizedChunks == result.narration.chunks.count - 1)
    #expect(result.article.blocks.contains { $0.text == "--" })
}

@Test func sqliteRejectsForeignNewerAndCompetingWriters() throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let db = root.appendingPathComponent("state.sqlite3")
    do {
        let store = try NativeStore(url: db)
        #expect(throws: RelayError.self) { try NativeStore(url: db) }
        try store.execute("PRAGMA user_version=99")
    }
    #expect(throws: RelayError.self) { try NativeStore(url: db) }
    let foreign = root.appendingPathComponent("python.sqlite3")
    var handle: OpaquePointer?
    #expect(sqlite3_open(foreign.path, &handle) == SQLITE_OK)
    #expect(sqlite3_exec(handle, "CREATE TABLE articles(id TEXT); PRAGMA user_version=1;", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(handle)
    let before = try Files.hash(foreign)
    #expect(throws: RelayError.self) { try NativeStore(url: foreign) }
    #expect(try Files.hash(foreign) == before)
}

@Test func fixtureWorkspaceRefusesUnownedLiveAndSymlinkedDestinations() throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let p = try PrototypeProfile.load(config(at: root))
    #expect(throws: RelayError.self) { try FixtureWorkspace.prepare(root: root, imported: p) }
    #expect(throws: RelayError.self) { try FixtureWorkspace.prepare(root: p.work, imported: p) }
    let fixture = root.appendingPathComponent("fixture")
    let isolated = try FixtureWorkspace.prepare(root: fixture, imported: p)
    try FileManager.default.removeItem(at: isolated.audio)
    #expect(throws: RelayError.self) { try FixtureWorkspace.prepare(root: fixture, imported: p) }
    #expect(!FileManager.default.fileExists(atPath: isolated.audio.path))
    try FileManager.default.createSymbolicLink(at: isolated.audio, withDestinationURL: root)
    #expect(throws: RelayError.self) { try FixtureWorkspace.prepare(root: fixture, imported: p) }
}

@Test func completeFixtureUsesCustomizedAudioAndIsIdempotent() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let p = try PrototypeProfile.load(config(at: root))
    let directory = root.appendingPathComponent("fixture")
    let first = try await FixtureCoordinator().run(root: directory, imported: p)
    #expect(first.episode.stage == .published && first.episode.info?.sampleRate == 22050)
    #expect(first.episode.info?.codec == "aac" && first.episode.info?.channels == 1)
    let audio = try Files.hash(first.audioURL); let feed = try Data(contentsOf: first.feedURL)
    let date = try first.audioURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    let second = try await FixtureCoordinator().run(root: directory, imported: p)
    #expect(second.synthesizedChunks == 0 && second.episode.guid == first.episode.guid)
    #expect(second.episode.publicationDate == first.episode.publicationDate)
    #expect(try Files.hash(second.audioURL) == audio && Data(contentsOf: second.feedURL) == feed)
    #expect(try second.audioURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == date)
    #expect(XMLParser(data: feed).parse())
    let xml = String(decoding: feed, as: UTF8.self)
    #expect(xml.contains("<itunes:block>yes</itunes:block>") && xml.contains("isPermaLink=\"false\""))
    #expect(xml.contains("audio/mp4") && xml.contains("length=\"\(first.episode.info!.byteLength)\""))
    #expect(!xml.contains("articles.example") && !xml.contains("Private Author") && !xml.contains("first paragraph"))
    #expect(!FileManager.default.fileExists(atPath: p.database.path))
}

@Test(arguments: FixtureBoundary.allCases)
func interruptionResumesWithStableIdentityAndCheckpoints(_ boundary: FixtureBoundary) async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("fixture")
    do { _ = try await FixtureCoordinator().run(root: directory, interruptAfter: boundary); Issue.record("Expected recovery interruption") }
    catch { #expect(error as? RelayError == .interrupted) }
    var original: Episode?
    do {
        let p = PrototypeProfile.fixture(at: directory)
        let store = try NativeStore(url: p.database)
        original = try store.episode(sourceKey: "bundled-synthetic-article-v1", settings: p)
        #expect(try store.query("SELECT count(*) FROM episodes")[0][0] == "1")
    }
    let result = try await FixtureCoordinator().run(root: directory)
    #expect(result.episode.id == original?.id && result.episode.stage == .published)
    if boundary == .chunkCommitted { #expect(result.synthesizedChunks == result.narration.chunks.count - 1) }
    else { #expect(result.synthesizedChunks == 0 && result.episode.publicationDate == original?.publicationDate) }
    let again = try await FixtureCoordinator().run(root: directory)
    #expect(again.synthesizedChunks == 0 && again.episode.guid == result.episode.guid)
}

@Test func damagedChunkRecoversWithoutChangingEpisodeAndPublishedCorruptionPreservesFeed() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("fixture")
    do { _ = try await FixtureCoordinator().run(root: directory, interruptAfter: .encoded) }
    catch { #expect(error as? RelayError == .interrupted) }
    let p = PrototypeProfile.fixture(at: directory)
    var episode: Episode?
    do { let s = try NativeStore(url: p.database); episode = try s.episode(sourceKey: "bundled-synthetic-article-v1", settings: p) }
    let work = p.work.appendingPathComponent(episode!.id)
    try Files.write(Data("invalid encode".utf8), to: work.appendingPathComponent("episode.m4a"))
    let chunk = work.appendingPathComponent("chunk-0/segment.wav")
    var damaged = try Data(contentsOf: chunk); damaged[damaged.count - 1] ^= 1
    try Files.write(damaged, to: chunk)
    let result = try await FixtureCoordinator().run(root: directory)
    #expect(result.synthesizedChunks == 1 && result.episode.id == episode!.id)
    let feed = try Data(contentsOf: result.feedURL)
    var audio = try Data(contentsOf: result.audioURL); audio[audio.count / 2] ^= 1
    try Files.write(audio, to: result.audioURL)
    do { _ = try await FixtureCoordinator().run(root: directory); Issue.record("Corrupt publication was accepted") }
    catch { #expect(error is RelayError) }
    #expect(try Data(contentsOf: result.feedURL) == feed)
}

@Test func pendingFeedRepairsWithoutSynthesis() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("fixture")
    let first = try await FixtureCoordinator().run(root: directory)
    try FileManager.default.removeItem(at: first.feedURL)
    let second = try await FixtureCoordinator().run(root: directory)
    #expect(second.synthesizedChunks == 0 && second.episode.guid == first.episode.guid)
    #expect(FileManager.default.fileExists(atPath: second.feedURL.path))
}

@Test func missingPreviousFeedAudioReportsContextAndRetainsNewQueueWork() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let first = try await coordinator.runReviewed(root: storage.stateRoot, review: reviewedArticle("previous", host: "synthetic.example"), backend: TwoArtifactBackend(), storage: storage)
    let priorFeed = try Data(contentsOf: first.feedURL)
    try FileManager.default.removeItem(at: first.audioURL)
    let second = try await coordinator.enqueue(reviewedArticle("current", host: "synthetic.example"), storage: storage, preferences: SpeechPreferences())
    let guid = try { () throws -> String in
        let store = try NativeStore(url: storage.profile.database)
        return try #require(try store.episodes().first(where: { $0.id == second.id })).guid
    }()
    let stale = try { () throws -> [Episode] in
        let store = try NativeStore(url: storage.profile.database, readOnly: true)
        return try store.published()
    }()
    do {
        _ = try RSS.render(stale, settings: first.episode.settings)
        Issue.record("Missing feed audio rendered")
    } catch let error as RelayError {
        guard case .artifact = error else { throw error }
        let message = error.localizedDescription
        #expect(message.contains("saved audio referenced by the local feed") && message.contains("saved progress"))
        #expect(!message.contains("synthetic.example") && !message.contains(root.path))
    }
    #expect(try Data(contentsOf: first.feedURL) == priorFeed)
    let result = try await coordinator.runQueued(second.id, storage: storage, backend: { _ in TwoArtifactBackend() })
    #expect(result.episode.id == second.id && result.episode.guid == guid)
    #expect(FileManager.default.fileExists(atPath: audio.appendingPathComponent(second.id + ".m4a").path))
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    let records = try { () throws -> [Episode] in
        let store = try NativeStore(url: storage.profile.database, readOnly: true)
        return try store.episodes()
    }()
    #expect(records.first(where: { $0.id == first.episode.id })?.stage == .expired)
    #expect(records.first(where: { $0.id == second.id })?.stage == .published)
    let feed = String(decoding: try Data(contentsOf: result.feedURL), as: UTF8.self)
    #expect(feed.contains(second.id + ".m4a") && !feed.contains(first.episode.id + ".m4a"))
    #expect(try await coordinator.savedAudio(storage: storage).map(\.id) == [second.id])
}

@Test func missingAudioReconciliationRetiresDeletedFilesAndPreservesSource() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let first = try await coordinator.runReviewed(root: storage.stateRoot, review: reviewedArticle("previous", host: "synthetic.example"), backend: TwoArtifactBackend(), storage: storage)
    let second = try await coordinator.runReviewed(root: storage.stateRoot, review: reviewedArticle("current", host: "synthetic.example"), backend: TwoArtifactBackend(), storage: storage)
    let snapshot = try { () throws -> Data in
        let store = try NativeStore(url: storage.profile.database, readOnly: true)
        return try #require(try store.snapshot(articleID: first.episode.id))
    }()
    try FileManager.default.removeItem(at: first.audioURL)
    #expect(try await coordinator.reconcileMissingAudio(storage: storage) == [first.episode.id])
    let records = try { () throws -> [Episode] in
        let store = try NativeStore(url: storage.profile.database, readOnly: true)
        return try store.episodes()
    }()
    #expect(records.first(where: { $0.id == first.episode.id })?.stage == .expired)
    #expect(records.first(where: { $0.id == second.episode.id })?.stage == .published)
    #expect(try await coordinator.savedAudio(storage: storage).map(\.id) == [second.episode.id])
    #expect(FileManager.default.fileExists(atPath: second.audioURL.path))
    let feed = String(decoding: try Data(contentsOf: first.feedURL), as: UTF8.self)
    #expect(feed.contains(second.episode.id + ".m4a") && !feed.contains(first.episode.id + ".m4a"))
    #expect(try { () throws -> Data? in
        let store = try NativeStore(url: storage.profile.database, readOnly: true)
        return try store.snapshot(articleID: first.episode.id)
    }() == snapshot)
    #expect(try { () throws -> Stage? in
        let store = try NativeStore(url: storage.profile.database, readOnly: true)
        return try store.episodes().first(where: { $0.id == first.episode.id })?.stage
    }() == .expired)
    let readded = try await coordinator.enqueue(reviewedArticle("previous", host: "synthetic.example"), storage: storage, preferences: SpeechPreferences())
    #expect(readded.id == first.episode.id)
    _ = try await coordinator.runQueued(readded.id, storage: storage, backend: { _ in TwoArtifactBackend() })
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    #expect(FileManager.default.fileExists(atPath: audio.appendingPathComponent(first.episode.id + ".m4a").path))
    #expect(try await coordinator.savedAudio(storage: storage).map(\.id).sorted() == [first.episode.id, second.episode.id].sorted())
}

@Test func missingAudioUnavailableStorageRetainsMetadataAndDoesNotCreateFolders() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let result = try await coordinator.runReviewed(root: storage.stateRoot, review: reviewedArticle("previous", host: "synthetic.example"), backend: TwoArtifactBackend(), storage: storage)
    let priorFeed = try Data(contentsOf: result.feedURL)
    func pending() throws -> String {
        let store = try NativeStore(url: storage.profile.database, readOnly: true)
        return try #require(try store.query("SELECT pending FROM feed_status WHERE singleton=1").first?.first)
    }
    let renamed = root.appendingPathComponent("audio-offline")
    try FileManager.default.moveItem(at: audio, to: renamed)
    #expect(try await coordinator.reconcileMissingAudio(storage: storage).isEmpty)
    #expect(try pending() == "0")
    #expect(try await coordinator.savedAudio(storage: storage).isEmpty)
    #expect(try Data(contentsOf: result.feedURL) == priorFeed)
    #expect(!FileManager.default.fileExists(atPath: audio.path))
    try FileManager.default.moveItem(at: renamed, to: audio)
    #expect(try await coordinator.savedAudio(storage: storage).map(\.id) == [result.episode.id])
    if geteuid() != 0 {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: audio.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: audio.path) }
        #expect(try await coordinator.savedAudio(storage: storage).isEmpty)
        #expect(try await coordinator.reconcileMissingAudio(storage: storage).isEmpty)
        #expect(try pending() == "0")
        #expect(try Data(contentsOf: result.feedURL) == priorFeed)
        #expect(try { () throws -> Stage? in
            let store = try NativeStore(url: storage.profile.database, readOnly: true)
            return try store.episodes().first(where: { $0.id == result.episode.id })?.stage
        }() == .published)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: audio.path)
    }
    let real = root.appendingPathComponent("audio-real")
    try FileManager.default.moveItem(at: audio, to: real)
    try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: real)
    #expect(try await coordinator.savedAudio(storage: storage).isEmpty)
    #expect(try await coordinator.reconcileMissingAudio(storage: storage).isEmpty)
    try FileManager.default.removeItem(at: audio)
    try FileManager.default.moveItem(at: real, to: audio)
    var wrong = result.episode
    wrong.audioVolumeID = "00000000-0000-0000-0000-000000000000"
    try { () throws in
        let store = try NativeStore(url: storage.profile.database)
        try store.save(wrong)
    }()
    #expect(try await coordinator.savedAudio(storage: storage).isEmpty)
    #expect(try await coordinator.reconcileMissingAudio(storage: storage).isEmpty)
    try { () throws in
        let store = try NativeStore(url: storage.profile.database)
        try store.save(result.episode)
    }()
    #expect(try Data(contentsOf: result.feedURL) == priorFeed)
    #expect(try pending() == "0")
    #expect(try await coordinator.savedAudio(storage: storage).map(\.id) == [result.episode.id])
}

@Test func missingAudioFeedRepairIsDurable() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let result = try await coordinator.runReviewed(root: storage.stateRoot, review: reviewedArticle("previous", host: "synthetic.example"), backend: TwoArtifactBackend(), storage: storage)
    let snapshot = try { () throws -> Data in
        let store = try NativeStore(url: storage.profile.database, readOnly: true)
        return try #require(try store.snapshot(articleID: result.episode.id))
    }()
    func pending() throws -> String {
        let store = try NativeStore(url: storage.profile.database, readOnly: true)
        return try #require(try store.query("SELECT pending FROM feed_status WHERE singleton=1").first?.first)
    }
    try FileManager.default.removeItem(at: result.audioURL)
    try FileManager.default.removeItem(at: result.feedURL)
    try Files.directory(result.feedURL)
    defer { try? FileManager.default.removeItem(at: result.feedURL) }
    do {
        _ = try await coordinator.reconcileMissingAudio(storage: storage)
        Issue.record("Feed write failure accepted")
    } catch { #expect(error is RelayError) }
    #expect(try { () throws -> Stage? in
        let store = try NativeStore(url: storage.profile.database, readOnly: true)
        return try store.episodes().first(where: { $0.id == result.episode.id })?.stage
    }() == .expired)
    #expect(try pending() == "1")
    #expect(try { () throws -> Data? in
        let store = try NativeStore(url: storage.profile.database, readOnly: true)
        return try store.snapshot(articleID: result.episode.id)
    }() == snapshot)
    try FileManager.default.removeItem(at: result.feedURL)
    #expect(try await coordinator.reconcileMissingAudio(storage: storage).isEmpty)
    #expect(try pending() == "0")
    let feed = String(decoding: try Data(contentsOf: result.feedURL), as: UTF8.self)
    #expect(feed.contains("<channel>") && !feed.contains(result.episode.id + ".m4a"))
    #expect(FileManager.default.fileExists(atPath: audio.path))
}

@Test func missingAudioFolderRaceNeverBecomesDeletion() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let result = try await coordinator.runReviewed(root: storage.stateRoot, review: reviewedArticle("previous", host: "synthetic.example"), backend: TwoArtifactBackend(), storage: storage)
    let snapshot = try { () throws -> Data in
        let store = try NativeStore(url: storage.profile.database, readOnly: true)
        return try #require(try store.snapshot(articleID: result.episode.id))
    }()
    let priorFeed = try Data(contentsOf: result.feedURL)
    try FileManager.default.removeItem(at: result.audioURL)
    let offline = root.appendingPathComponent("audio-offline")
    #expect(audioAvailability(result.episode, beforeMissingRecheck: {
        try? FileManager.default.moveItem(at: audio, to: offline)
    }) == .unavailable)
    #expect(FileManager.default.fileExists(atPath: offline.path) && !FileManager.default.fileExists(atPath: audio.path))
    try FileManager.default.moveItem(at: offline, to: audio)
    #expect(audioAvailability(result.episode) == .missing)
    #expect(audioAvailability(result.episode, beforeMissingRecheck: {
        try? FileManager.default.moveItem(at: audio, to: offline)
        try? FileManager.default.createDirectory(at: audio, withIntermediateDirectories: false)
    }) == .unavailable)
    try FileManager.default.removeItem(at: audio)
    try FileManager.default.moveItem(at: offline, to: audio)
    #expect(audioAvailability(result.episode) == .missing)
    #expect(try Data(contentsOf: result.feedURL) == priorFeed)
    #expect(try { () throws -> Data? in
        let store = try NativeStore(url: storage.profile.database, readOnly: true)
        return try store.snapshot(articleID: result.episode.id)
    }() == snapshot)
    #expect(try { () throws -> Stage? in
        let store = try NativeStore(url: storage.profile.database, readOnly: true)
        return try store.episodes().first(where: { $0.id == result.episode.id })?.stage
    }() == .published)
}

@Test func runtimeArtifactFailureNamesRoleWithoutPrivatePaths() throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let runtime = root.appendingPathComponent("runtime/kokoro")
    try Files.directory(runtime)
    for name in ["selection.json", "runtime_setup.py", "requirements.lock", "python-downloads.json"] {
        try Files.write(Data(), to: runtime.appendingPathComponent(name))
    }
    try Files.directory(runtime.appendingPathComponent("provider.py"))
    do {
        _ = try KokoroMLXBackend(configuration: KokoroConfiguration(projectRoot: root, voice: "af_heart", speed: 1))
        Issue.record("Unreadable runtime source was accepted")
    } catch let error as RelayError {
        guard case .artifact = error else { throw error }
        #expect(error.localizedDescription.contains("speech runtime sources or dependency pins"))
        #expect(!error.localizedDescription.contains(root.path))
    }
}

@Test func temporarySnapshotReadFailureNamesRoleWithoutPrivatePaths() throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = try StoredExtraction(review: reviewedArticle(), chunkLimit: 1800)
    let target = root.appendingPathComponent("snapshot"); try Files.directory(target)
    try Files.directory(target.appendingPathComponent("source.html"))
    do {
        try snapshot.restore(to: target)
        Issue.record("Unreadable snapshot file was accepted")
    } catch let error as RelayError {
        guard case .artifact = error else { throw error }
        #expect(error.localizedDescription.contains("temporary article snapshot"))
        #expect(!error.localizedDescription.contains(root.path))
    }
}

@Test func cancellationStopsBeforeFixtureMutation() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let task = Task { try await FixtureCoordinator().run(root: root.appendingPathComponent("fixture")) }
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled work completed") }
    catch { #expect(error is CancellationError) }
}

private struct TwoArtifactBackend: TTSBackend {
    let identity = BackendIdentity(id: "test-two-artifacts-v1", displayName: "Two synthetic test artifacts", isMock: false)
    func prepare() throws {}
    func cancel() {}
    func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult {
        let one = try SyntheticAudioBackend().synthesize(request, directory: directory)
        return SynthesisResult(artifacts: one.artifacts + one.artifacts)
    }
}

@Test func replaceableBackendPersistsProvenanceAndMultipleArtifacts() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("fixture")
    let result = try await FixtureCoordinator().run(root: directory, backend: TwoArtifactBackend())
    #expect(result.episode.info!.duration > Double(result.narration.chunks.count) * 0.5)
    let store = try NativeStore(url: PrototypeProfile.fixture(at: directory).database)
    let records = try store.query("SELECT checkpoint FROM chunks ORDER BY chunk_index")
    #expect(records.count == result.narration.chunks.count)
    let chunk = try JSONDecoder().decode(ChunkCheckpoint.self, from: Data(records[0][0].utf8))
    #expect(chunk.request.blockIndices == result.narration.chunks[0].blockIndices)
    #expect(chunk.request.text == result.narration.chunks[0].text && chunk.result.artifacts.count == 2)
}

@Test func ownedToolDeadlineAndCancellationAreBounded() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let timeout = Task.detached { try ToolRunner.run("/bin/sleep", ["30"], timeout: 1, directory: root) }
    do { _ = try await timeout.value; Issue.record("Tool deadline was not enforced") }
    catch { #expect(error is RelayError) }
    let started = Date()
    let cancelled = Task.detached { try ToolRunner.run("/bin/sleep", ["30"], timeout: 20, directory: root) }
    try await Task.sleep(for: .milliseconds(100)); cancelled.cancel()
    do { _ = try await cancelled.value; Issue.record("Tool cancellation was not enforced") }
    catch { #expect(error is CancellationError) }
    #expect(Date().timeIntervalSince(started) < 3)
}

@Test func systemTemporaryPathAliasesResumeAcrossFirstCreation() async throws {
    let directory = URL(fileURLWithPath: "/private/tmp/voicerelay-alias-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try await FixtureCoordinator().run(root: directory)
    let alias = URL(fileURLWithPath: "/tmp").appendingPathComponent(directory.lastPathComponent)
    let second = try await FixtureCoordinator().run(root: alias)
    #expect(second.synthesizedChunks == 0 && first.episode.id == second.episode.id)
}

// This executable fixture emits tiny synthetic WAVs; it never imports a TTS engine.
private func speechHelper(at root: URL, mode: String = "normal", deadline: Double = 2,
                          temporaryRoot: URL? = nil) throws -> ExecutableSpeechBackend {
    let script = root.appendingPathComponent("helper.py")
    let source = #"""
    import json, os, signal, subprocess, sys, time, wave
    from pathlib import Path
    mode, folder = sys.argv[1], Path(sys.argv[2])
    if os.getpgrp() != os.getpid(): os.setsid()
    if mode == 'startup-exit': os._exit(7)
    def emit(i, **kw):
        print(json.dumps(dict(protocol=1, id=i, **kw)), flush=True)
    emit(0, kind="hello", pid=os.getpid())
    child = None
    def shutdown(*args):
        if child is not None:
            try: child.wait(timeout=0.1)
            except subprocess.TimeoutExpired: pass
        sys.exit(0)
    signal.signal(signal.SIGTERM, shutdown)
    for line in sys.stdin:
        r = json.loads(line)
        if r['command'] == 'prepare':
            if mode == 'preparation-exit': os._exit(8)
            (folder/'last-temp.txt').write_text(os.environ.get('TMPDIR') or '')
            with (folder/'prepares').open('a') as h: h.write('1\n')
            emit(r['id'], kind='ready')
            continue
        if mode in ['timeout', 'cancel']:
            child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
            (folder/'child-pid').write_text(str(child.pid))
            time.sleep(30)
        if mode == 'crash': os._exit(2)
        if mode == 'signal': os.kill(os.getpid(), signal.SIGKILL)
        if mode == 'control-close':
            os.close(sys.stdout.fileno())
            time.sleep(30)
        if mode == 'error':
            emit(r['id'], kind='error', code='synthesis_failed', detail=r['text'])
            continue
        files = []
        (folder/'last-speed.json').write_text(json.dumps(r['speed']))
        for name in ['first.wav', 'second.wav']:
            path = Path(r['directory'])/name
            with wave.open(str(path), 'wb') as w:
                w.setnchannels(1); w.setsampwidth(2); w.setframerate(24000)
                w.writeframes(b'\x00\x00'*2400)
            files.append(dict(file=name, sample_rate=24000, channels=1, format='wav'))
        if mode == 'escape': files[0]['file'] = '../outside.wav'
        if mode == 'provenance': r['block_indices'] = [999]
        emit(r['id'], kind='result', article_id=r['article_id'], chunk_index=r['chunk_index'],
             block_indices=r['block_indices'], artifacts=files)
    """#
    try Files.write(Data(source.utf8), to: script)
    guard let python = ToolRunner.locate("python3") else { throw RelayError.setup("Python is needed for the synthetic protocol check.") }
    return ExecutableSpeechBackend(identity: BackendIdentity(id: "synthetic-executable-v1", displayName: "Protocol test", isMock: false),
        executable: python, arguments: ["-I", script.path, mode, root.path],
        environment: ProcessInfo.processInfo.environment, voice: "af_heart", speed: 1,
        prepareTimeout: 2, synthesisTimeout: deadline, temporaryRoot: temporaryRoot)
}
private func speechRequest() -> SynthesisRequest {
    SynthesisRequest(text: "private test narration", language: "en-US", voice: nil,
                     articleID: "test-article", chunkIndex: 3, blockIndices: [2, 4], settings: [:])
}

@Test func speechHelperReusesPreparationAndPreservesArtifactOrder() throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let backend = try speechHelper(at: root); defer { backend.cancel() }
    try backend.prepare(); try backend.prepare()
    let first = try backend.synthesize(speechRequest(), directory: root)
    let second = try backend.synthesize(speechRequest(), directory: root)
    #expect(first.artifacts.map(\.url.lastPathComponent) == ["first.wav", "second.wav"])
    #expect(second.artifacts.count == 2)
    #expect(try String(contentsOf: root.appendingPathComponent("prepares"), encoding: .utf8) == "1\n")
    let processor = AudioProcessor(settings: .fixture(at: root), toolDirectory: root)
    try processor.validate(first, within: root)
}

@Test(arguments: [1.0, 2.0, 1.25])
func speechHelperAcceptsNumericSpeedAfterCheckpointRoundTrip(_ speed: Double) throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let backend = try speechHelper(at: root); defer { backend.cancel() }
    try backend.prepare()
    let settings = try JSONDecoder().decode([String: SettingValue].self, from: Files.json(["speed": SettingValue.number(speed)]))
    if speed.rounded() == speed { #expect(settings["speed"] == .integer(Int(speed))) }
    let request = SynthesisRequest(text: "Synthetic speech request.", language: "en", voice: nil,
        articleID: "synthetic", chunkIndex: 0, blockIndices: [0], settings: settings)
    #expect(try backend.synthesize(request, directory: root).artifacts.count == 2)
    #expect(try JSONDecoder().decode(Double.self, from: Data(contentsOf: root.appendingPathComponent("last-speed.json"))) == speed)
}

@Test(arguments: [SettingValue.string("1.0"), .bool(true), .integer(0), .integer(5)])
func speechHelperRefusesInvalidSpeedSettings(_ value: SettingValue) throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let backend = try speechHelper(at: root); defer { backend.cancel() }
    try backend.prepare()
    let request = SynthesisRequest(text: "Synthetic speech request.", language: "en", voice: nil,
        articleID: "synthetic", chunkIndex: 0, blockIndices: [0], settings: ["speed": value])
    #expect(throws: RelayError.self) { try backend.synthesize(request, directory: root) }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("last-speed.json").path))
}

@Test func speechHelperNumericSpeedSurvivesPersistedFixture() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let backend = try speechHelper(at: root); defer { backend.cancel() }
    let workspace = root.appendingPathComponent("speech-fixture")
    let first = try await FixtureCoordinator().runSpeech(root: workspace, backend: backend, voice: "af_heart", speed: 1.0)
    #expect(first.episode.settings.backendSettings["speed"]?.numericValue == 1 && first.synthesizedChunks > 0)
    #expect(try JSONDecoder().decode(Double.self, from: Data(contentsOf: root.appendingPathComponent("last-speed.json"))) == 1)
    // A published checkpoint remains valid when a later build changes extraction/narration versions.
    let artifacts = workspace.appendingPathComponent("private/work").appendingPathComponent(first.episode.id)
    let articleFile = artifacts.appendingPathComponent("article.json"), planFile = artifacts.appendingPathComponent("narration.json")
    let checkpointFile = artifacts.appendingPathComponent("extraction-checkpoint.json")
    var article = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: articleFile)) as? [String: Any])
    var plan = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: planFile)) as? [String: Any])
    var checkpoint = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: checkpointFile)) as? [String: Any])
    article["extractorVersion"] = "previous-extractor"
    plan["version"] = "previous-narration"
    checkpoint["extractorVersion"] = "previous-extractor"; checkpoint["narrationVersion"] = "previous-narration"
    try Files.write(JSONSerialization.data(withJSONObject: article, options: [.sortedKeys]), to: articleFile)
    try Files.write(JSONSerialization.data(withJSONObject: plan, options: [.sortedKeys]), to: planFile)
    checkpoint["articleHash"] = try Files.hash(articleFile); checkpoint["narrationHash"] = try Files.hash(planFile)
    try Files.write(JSONSerialization.data(withJSONObject: checkpoint, options: [.sortedKeys]), to: checkpointFile)
    let protected = [articleFile, planFile, checkpointFile, first.audioURL, first.feedURL]
    let before = try protected.map { try Data(contentsOf: $0) }
    let repeated = try await FixtureCoordinator().runSpeech(root: workspace, backend: backend, voice: "af_heart", speed: 1.0)
    #expect(repeated.synthesizedChunks == 0 && repeated.episode.id == first.episode.id)
    #expect(repeated.article.extractorVersion == "previous-extractor" && repeated.narration.version == "previous-narration")
    #expect(try protected.map { try Data(contentsOf: $0) } == before)
}

@Test(arguments: ["error", "escape", "provenance", "crash"])
func speechHelperRejectsFailuresAndUnsafeOutputs(_ mode: String) throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let backend = try speechHelper(at: root, mode: mode); defer { backend.cancel() }
    try backend.prepare()
    do { _ = try backend.synthesize(speechRequest(), directory: root); Issue.record("Invalid helper result accepted") }
    catch { #expect(error is RelayError); #expect(!error.localizedDescription.contains("private test narration")) }
    // A failure stops the session; preparation must start a fresh helper.
    try backend.prepare()
    #expect(try String(contentsOf: root.appendingPathComponent("prepares"), encoding: .utf8) == "1\n1\n")
}

@Test(arguments: ["startup-exit", "preparation-exit", "crash", "signal", "control-close"])
func speechHelperReportsExitReasonAndOperation(_ mode: String) throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let backend = try speechHelper(at: root, mode: mode); defer { backend.cancel() }
    let start = Date()
    do {
        try backend.prepare()
        _ = try backend.synthesize(speechRequest(), directory: root)
        Issue.record("Helper failure accepted")
    } catch {
        let message = error.localizedDescription
        let expected = switch mode {
        case "startup-exit": "exited with status 7 during startup"
        case "preparation-exit": "exited with status 8 during preparation"
        case "crash": "exited with status 2 during synthesis"
        case "signal": "terminated by signal 9 during synthesis"
        default: "closed its control connection during synthesis"
        }
        #expect(error is RelayError)
        #expect(message.contains(expected))
        #expect(!message.contains(speechRequest().text))
        #expect(!message.contains(root.path))
    }
    #expect(Date().timeIntervalSince(start) < 3)
}

@Test func speechHelperOwnsSystemTemporaryDirectoryAndCleansItOnStop() throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let tempParent = try temporary(); defer { try? FileManager.default.removeItem(at: tempParent) }
    let backend = try speechHelper(at: root, temporaryRoot: tempParent)
    #expect(try FileManager.default.contentsOfDirectory(atPath: tempParent.path).isEmpty)
    try backend.prepare()
    let children = try FileManager.default.contentsOfDirectory(atPath: tempParent.path)
    #expect(children.count == 1)
    let child = tempParent.appendingPathComponent(children[0])
    let marker = try String(contentsOf: root.appendingPathComponent("last-temp.txt"), encoding: .utf8)
    #expect(marker == child.path && !marker.hasPrefix(root.path))
    let mode = try #require(FileManager.default.attributesOfItem(atPath: child.path)[.posixPermissions] as? NSNumber)
    #expect(mode.intValue == 0o700)
    backend.cancel()
    #expect(try FileManager.default.contentsOfDirectory(atPath: tempParent.path).isEmpty)
    try backend.prepare()
    let second = try FileManager.default.contentsOfDirectory(atPath: tempParent.path)
    #expect(second.count == 1 && second != children)
    backend.cancel()
    #expect(try FileManager.default.contentsOfDirectory(atPath: tempParent.path).isEmpty)
}

@Test func speechHelperTemporaryDirectoryCleansAfterLaunchPreparationFailure() throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let tempParent = try temporary(); defer { try? FileManager.default.removeItem(at: tempParent) }
    let backend = try speechHelper(at: root, mode: "preparation-exit", temporaryRoot: tempParent)
    defer { backend.cancel() }
    do { try backend.prepare(); Issue.record("Failed preparation accepted") }
    catch { #expect(error is RelayError) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: tempParent.path).isEmpty)
    #expect(FileManager.default.fileExists(atPath: tempParent.path))
}

@Test func speechHelperRejectsUnsafeTemporaryRootsWithoutCreation() throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    func refused(_ temporaryRoot: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let backend = try speechHelper(at: root, temporaryRoot: temporaryRoot)
        defer { backend.cancel() }
        do {
            try backend.prepare()
            Issue.record("Unsafe temporary root accepted", sourceLocation: sourceLocation)
        } catch {
            #expect(error is RelayError, sourceLocation: sourceLocation)
            #expect(!error.localizedDescription.contains(temporaryRoot.path), sourceLocation: sourceLocation)
        }
    }
    let outside = URL(fileURLWithPath: "/nonexistent-voicerelay-test-\(UUID().uuidString)")
    try refused(outside)
    #expect(!FileManager.default.fileExists(atPath: outside.path))
    try refused(URL(fileURLWithPath: "/"))
    try refused(FileManager.default.homeDirectoryForCurrentUser)
    let target = try temporary(); defer { try? FileManager.default.removeItem(at: target) }
    let parent = try temporary(); defer { try? FileManager.default.removeItem(at: parent) }
    let link = parent.appendingPathComponent("linked-root")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    try refused(link)
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["linked-root"])
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("prepares").path))
}

@Test(arguments: ["timeout", "cancel"])
func speechHelperDeadlineAndCancelStopOwnedDescendants(_ mode: String) async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let backend = try speechHelper(at: root, mode: mode, deadline: mode == "timeout" ? 0.3 : 10)
    defer { backend.cancel() }; try backend.prepare()
    let work = Task.detached {
        let start = Date()
        let result = Result { try backend.synthesize(speechRequest(), directory: root) }
        return (result, Date().timeIntervalSince(start))
    }
    if mode == "cancel" {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("child-pid").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        backend.cancel()
    }
    let (result, elapsed) = await work.value
    do { _ = try result.get(); Issue.record("Unbounded helper completed") }
    catch { #expect(mode == "cancel" ? error is CancellationError : error is RelayError) }
    // Measure the helper call, excluding the test executor's delayed resumption
    // when the other fixture cases run ffmpeg concurrently.
    #expect(elapsed < 3)
    let pid = try #require(Int32(String(contentsOf: root.appendingPathComponent("child-pid"), encoding: .utf8)))
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
}

@Test func kokoroMissingRuntimeAndEscapedModelPathsFailLocally() throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("runtime/kokoro"); try Files.directory(source)
    for name in ["provider.py", "runtime_setup.py", "selection.json", "requirements.lock", "python-downloads.json"] {
        try Files.write(Data("synthetic pin".utf8), to: source.appendingPathComponent(name))
    }
    let backend = try KokoroMLXBackend(configuration: KokoroConfiguration(projectRoot: root))
    try Files.write(Data("changed interpreter metadata".utf8), to: source.appendingPathComponent("python-downloads.json"))
    let changed = try KokoroMLXBackend(configuration: KokoroConfiguration(projectRoot: root))
    #expect(backend.identity.id != changed.identity.id)
    #expect(throws: RelayError.self) { try backend.prepare() }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".runtime").path))
    let outside = try temporary(); defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("models"), withDestinationURL: outside)
    #expect(throws: RelayError.self) { try KokoroMLXBackend(configuration: KokoroConfiguration(projectRoot: root)) }
}

private struct SyntheticSpeechContractBackend: TTSBackend {
    let identity: BackendIdentity
    init(_ revision: String) { identity = BackendIdentity(id: revision, displayName: "Synthetic speech-contract test only", isMock: false) }
    func prepare() throws {}
    func cancel() {}
    func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult {
        try SyntheticAudioBackend().synthesize(request, directory: directory)
    }
}

@Test(arguments: [FixtureBoundary.chunkCommitted, .encoded])
func speechFingerprintChangesInvalidateUnpublishedAudio(_ boundary: FixtureBoundary) async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("speech")
    do { _ = try await FixtureCoordinator().runSpeech(root: folder, backend: SyntheticSpeechContractBackend("a"), interruptAfter: boundary) }
    catch { #expect(error as? RelayError == .interrupted) }
    let before: Episode
    do {
        let store = try NativeStore(url: PrototypeProfile.fixture(at: folder).database)
        before = try store.episode(sourceKey: "bundled-synthetic-article-v1", settings: .fixture(at: folder))
    }
    let next = try await FixtureCoordinator().runSpeech(root: folder, backend: SyntheticSpeechContractBackend("b"))
    #expect(next.synthesizedChunks == next.narration.chunks.count && before.id == next.episode.id)
    let bytes = try Data(contentsOf: next.audioURL)
    let third = try await FixtureCoordinator().runSpeech(root: folder, backend: SyntheticSpeechContractBackend("c"))
    #expect(third.synthesizedChunks == 0 && next.episode.guid == third.episode.guid)
    #expect(try Data(contentsOf: third.audioURL) == bytes)
    #expect(throws: RelayError.self) { try FixtureWorkspace.prepare(root: folder, imported: nil, articles: true) }
}

@Test func speechCompatibleCheckpointResumesAndLegacyEpisodeDecodes() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("speech")
    do { _ = try await FixtureCoordinator().runSpeech(root: folder, backend: SyntheticSpeechContractBackend("a"), interruptAfter: .chunkCommitted) }
    catch { #expect(error as? RelayError == .interrupted) }
    let next = try await FixtureCoordinator().runSpeech(root: folder, backend: SyntheticSpeechContractBackend("a"))
    #expect(next.synthesizedChunks == next.narration.chunks.count - 1)
    var legacy = try #require(JSONSerialization.jsonObject(with: Files.json(next.episode)) as? [String: Any])
    legacy.removeValue(forKey: "synthesisFingerprint")
    let restored = try JSONDecoder().decode(Episode.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(restored.id == next.episode.id && restored.synthesisFingerprint == nil)
}

@Test func speechResumeRejectsEscapedChunkBeforeWriting() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let outside = try temporary(); defer { try? FileManager.default.removeItem(at: outside) }
    let folder = root.appendingPathComponent("speech")
    do { _ = try await FixtureCoordinator().runSpeech(root: folder, backend: SyntheticSpeechContractBackend("a"), interruptAfter: .chunkCommitted) }
    catch { #expect(error as? RelayError == .interrupted) }
    let episode: Episode
    do {
        let store = try NativeStore(url: PrototypeProfile.fixture(at: folder).database)
        episode = try store.episode(sourceKey: "bundled-synthetic-article-v1", settings: .fixture(at: folder))
    }
    let chunk = episode.settings.work.appendingPathComponent(episode.id).appendingPathComponent("chunk-0")
    try FileManager.default.removeItem(at: chunk)
    try FileManager.default.createSymbolicLink(at: chunk, withDestinationURL: outside)
    do { _ = try await FixtureCoordinator().runSpeech(root: folder, backend: SyntheticSpeechContractBackend("a")); Issue.record("Escaped chunk accepted") }
    catch { #expect(error is RelayError) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
}

@Test func speechOptionsAreCapturedWithoutTreatingDefaultPathsAsLive() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("speech")
    let first = try await FixtureCoordinator().runSpeech(root: folder, backend: SyntheticSpeechContractBackend("a"), voice: "af_heart", speed: 1.25)
    #expect(first.episode.settings.voice == "af_heart" && first.episode.settings.backendSettings["speed"] == .number(1.25))
    let repeatRun = try await FixtureCoordinator().runSpeech(root: folder, backend: SyntheticSpeechContractBackend("a"), voice: "bf_emma", speed: 1)
    #expect(repeatRun.episode.settings.voice == "af_heart" && repeatRun.episode.settings.backendSettings["speed"] == .number(1.25))
    #expect(repeatRun.synthesizedChunks == 0 && repeatRun.episode.id == first.episode.id)
}

// Test-only audio. No tone provider is shipped in the app or CLI.
private struct SyntheticAudioBackend: TTSBackend {
    let identity = BackendIdentity(id: "synthetic-test-pcm-v1", displayName: "Synthetic test audio", isMock: false)
    init() {}
    func prepare() throws { try Task.checkCancellation() }
    func cancel() {}
    func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult {
        try Task.checkCancellation()
        let rate = 24000; let count = rate / 4
        var pcm = Data()
        func u16(_ v: UInt16) { var v = v.littleEndian; withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { var v = v.littleEndian; withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) } }
        pcm.append(Data("RIFF".utf8)); u32(UInt32(36 + count * 2)); pcm.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        pcm.append(Data("data".utf8)); u32(UInt32(count * 2))
        let frequency = 330.0 + Double(request.chunkIndex % 7) * 30
        for sample in 0..<count {
            let ramp = min(1.0, Double(min(sample, count - 1 - sample)) / 240.0)
            let value = Int16(sin(Double(sample) * 2 * .pi * frequency / Double(rate)) * 3000 * ramp)
            u16(UInt16(bitPattern: value))
        }
        let file = directory.appendingPathComponent("segment.wav")
        try Files.write(pcm, to: file)
        return SynthesisResult(artifacts: [LosslessArtifact(url: file, sampleRate: rate, channels: 1, format: "wav")])
    }
}

private extension FixtureCoordinator {
    func run(root: URL, imported: PrototypeProfile? = nil,
             backend: any TTSBackend = SyntheticAudioBackend(), interruptAfter: FixtureBoundary? = nil,
             onBoundary: @escaping @Sendable (FixtureBoundary) -> Void = { _ in },
             onProgress: @escaping @Sendable (PipelineProgress) -> Void = { _ in }) async throws -> FixtureResult {
        try await runSpeech(root: root, imported: imported, backend: backend, interruptAfter: interruptAfter,
                      onBoundary: onBoundary, onProgress: onProgress)
    }
}

@Test func speechPreferencesHaveSensibleDefaultsAndRoundTrip() throws {
    let defaults = SpeechPreferences()
    #expect(defaults.voice == .heart && defaults.speed == 1)
    let changed = SpeechPreferences(voice: .emma, speed: 1.25)
    try changed.validate()
    let bytes = try Files.json(changed)
    #expect(try JSONDecoder().decode(SpeechPreferences.self, from: bytes) == changed)
    #expect(!String(decoding: bytes, as: UTF8.self).contains("path"))
    for speed in [0.0, 0.5, 2.0, Double.infinity, Double.nan] {
        #expect(throws: RelayError.self) { try SpeechPreferences(speed: speed).validate() }
    }
}

@Test func speechVoiceMenusAreRegionalBoundedAndOrderedByPublishedQuality() throws {
    #expect(SpeechPreferences().languageRegion == .usEnglish)
    #expect(SpeechLanguageRegion.usEnglish.voices.count == 10)
    #expect(SpeechLanguageRegion.ukEnglish.voices.count == 8)
    #expect(SpeechLanguageRegion.usEnglish.voices.prefix(3) == [.heart, .bella, .nicole])
    #expect(SpeechLanguageRegion.ukEnglish.voices.first == .emma)
    let grades = ["A": 0, "A−": 1, "B−": 2, "C+": 3, "C": 4, "D+": 5, "D": 6]
    for region in SpeechLanguageRegion.allCases {
        let voices = region.voices
        #expect(Set(voices).count == voices.count)
        #expect(voices.allSatisfy { $0.languageRegion == region })
        for (first, second) in zip(voices, voices.dropFirst()) {
            #expect(try #require(grades[first.qualityGrade]) <= #require(grades[second.qualityGrade]))
            if first.qualityGrade == second.qualityGrade { #expect(first.label < second.label) }
        }
        for voice in voices {
            let configuration = try KokoroConfiguration(projectRoot: URL(fileURLWithPath: "/synthetic/VoiceRelay"), voice: voice.rawValue)
            #expect(configuration.voice == voice.rawValue)
            #expect(try JSONDecoder().decode(SpeechPreferences.self, from: Files.json(SpeechPreferences(voice: voice))).voice == voice)
        }
    }
    #expect(Set(SpeechVoice.allCases) == Set(SpeechLanguageRegion.allCases.flatMap(\.voices)))
}

@Test func speechRegionChangesKeepMatchingSelectionsAndRestoreLegacyPreferences() throws {
    var preferences = SpeechPreferences(voice: .bella, speed: 1.25)
    preferences.languageRegion = .usEnglish
    #expect(preferences.voice == .bella)
    preferences.languageRegion = .ukEnglish
    #expect(preferences.voice == .emma && preferences.speed == 1.25)
    preferences.voice = .george
    preferences.languageRegion = .ukEnglish
    #expect(preferences.voice == .george)
    preferences.languageRegion = .usEnglish
    #expect(preferences.voice == .heart && preferences.speed == 1.25)
    for voice in [SpeechVoice.heart, .bella, .emma] {
        let legacy = Data("{\"voice\":\"\(voice.rawValue)\",\"speed\":1.25}".utf8)
        let restored = try JSONDecoder().decode(SpeechPreferences.self, from: legacy)
        #expect(restored.voice == voice && restored.languageRegion == voice.languageRegion)
        let object = try #require(JSONSerialization.jsonObject(with: Files.json(restored)) as? [String: Any])
        #expect(Set(object.keys) == ["voice", "speed"])
    }
}

@Test func queueCapturesRegionalVoiceAndKeepsEarlierChoicesOnReenqueue() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"),
                                       temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let uk = try await coordinator.enqueue(reviewedArticle("british"), storage: storage,
        preferences: SpeechPreferences(voice: .george, speed: 1.25))
    let us = try await coordinator.enqueue(reviewedArticle("american"), storage: storage,
        preferences: SpeechPreferences(voice: .puck))
    let again = try await coordinator.enqueue(reviewedArticle("british"), storage: storage, preferences: SpeechPreferences())
    #expect(again.id == uk.id)
    let episodes = try await coordinator.library(storage: storage)
    let capturedUK = try #require(episodes.first { $0.id == uk.id })
    let capturedUS = try #require(episodes.first { $0.id == us.id })
    #expect(capturedUK.settings.voice == "bm_george" && capturedUK.settings.language == "en-GB")
    #expect(capturedUK.settings.backendSettings["speed"]?.numericValue == 1.25)
    #expect(capturedUS.settings.voice == "am_puck" && capturedUS.settings.language == "en-US")
}

@Test func speechWorkspaceRejectsHistoricalToneDataWithoutWriting() throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent(".voicerelay-fixture")
    let bytes = Data("VoiceRelay isolated fixture workspace v1\n".utf8)
    try Files.write(bytes, to: marker)
    #expect(throws: RelayError.self) { try FixtureWorkspace.prepare(root: root, imported: nil) }
    #expect(try Data(contentsOf: marker) == bytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [".voicerelay-fixture"])
}

@Test func libraryReadOnlyStoreRejectsForeignOrMissingDataWithoutCreatingLock() throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let foreign = root.appendingPathComponent("foreign.sqlite3")
    var db: OpaquePointer?
    #expect(sqlite3_open(foreign.path, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, "PRAGMA application_id=1; CREATE TABLE historical(value TEXT)", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let before = try Files.hash(foreign)
    #expect(throws: RelayError.self) { try NativeStore(url: foreign, readOnly: true) }
    #expect(try Files.hash(foreign) == before)
    #expect(!FileManager.default.fileExists(atPath: foreign.appendingPathExtension("writer.lock").path))
    let missing = root.appendingPathComponent("missing.sqlite3")
    #expect(throws: RelayError.self) { try NativeStore(url: missing, readOnly: true) }
    #expect(!FileManager.default.fileExists(atPath: missing.path))
}

@Test func reviewedLibraryRejectsEscapedMediaBeforePresentingSavedFiles() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let outside = try temporary(); defer { try? FileManager.default.removeItem(at: outside) }
    let folder = root.appendingPathComponent("library")
    let profile = try FixtureWorkspace.prepare(root: folder, imported: nil, articles: true)
    do { _ = try NativeStore(url: profile.database) }
    #expect(try await FixtureCoordinator().library(root: folder).isEmpty)
    try FileManager.default.removeItem(at: profile.audio)
    try FileManager.default.createSymbolicLink(at: profile.audio, withDestinationURL: outside)
    do { _ = try await FixtureCoordinator().library(root: folder); Issue.record("Escaped library media accepted") }
    catch { #expect(error is RelayError) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
}

private func reviewedArticle(_ path: String = "one", changed: Bool = false, host: String = "articles.example") throws -> ReviewedSource {
    let url = URL(string: "https://\(host)/\(path)")!
    var html = String(decoding: try FixtureResource.html(), as: UTF8.self)
    if changed { html = html.replacingOccurrences(of: "</article>", with: "<p>A changed source revision must not replace published audio.</p></article>") }
    let page = FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html,
                           contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
    return try ReviewedSource.prepare(page, chunkLimit: 1800)
}

@Test func reviewedSpeechPublishesMultipleArticlesAndResumesOffline() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("articles")
    let review = try reviewedArticle()
    let first = try await FixtureCoordinator().runReviewed(root: folder, review: review,
        backend: SyntheticSpeechContractBackend("review-v1"), voice: "af_heart", speed: 1.25)
    #expect(first.article == review.document?.article)
    let raw = first.episode.settings.work.appendingPathComponent(first.episode.id).appendingPathComponent("source.html")
    #expect(try Data(contentsOf: raw) == review.page.bytes)
    let second = try await FixtureCoordinator().runReviewed(root: folder, review: reviewedArticle("two"),
        backend: SyntheticSpeechContractBackend("review-v1"))
    #expect(first.episode.id != second.episode.id)
    #expect(try String(contentsOf: second.feedURL, encoding: .utf8).components(separatedBy: "<item>").count == 3)
    let library = try await FixtureCoordinator().library(root: folder)
    #expect(library.count == 2 && library.allSatisfy { $0.stage == .published })
    let hashes = try [first.audioURL, second.audioURL, second.feedURL].map(Files.hash)
    let resumed = try await FixtureCoordinator().resumeReviewed(root: folder, articleID: first.episode.id,
        backend: SyntheticSpeechContractBackend("review-v2"))
    #expect(resumed.episode.id == first.episode.id && resumed.synthesizedChunks == 0)
    #expect(resumed.episode.settings.backendSettings["speed"]?.numericValue == 1.25)
    #expect(try [first.audioURL, second.audioURL, second.feedURL].map(Files.hash) == hashes)
    let feed = try String(contentsOf: resumed.feedURL, encoding: .utf8)
    #expect(!feed.contains("articles.example") && !feed.contains("first paragraph"))
}

@Test func reviewedSpeechKeepsCapturedOptionsAndCompletedChunkAfterInterruption() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("articles")
    let review = try reviewedArticle()
    do {
        _ = try await FixtureCoordinator().runReviewed(root: folder, review: review,
            backend: SyntheticSpeechContractBackend("review-v1"), voice: "af_heart", speed: 1.25,
            interruptAfter: .chunkCommitted)
        Issue.record("Expected interruption")
    } catch { #expect(error as? RelayError == .interrupted) }
    let saved = try #require(await FixtureCoordinator().library(root: folder).first)
    let resumed = try await FixtureCoordinator().resumeReviewed(root: folder, articleID: saved.id,
        backend: SyntheticSpeechContractBackend("review-v1"))
    #expect(resumed.episode.id == saved.id && resumed.synthesizedChunks == resumed.narration.chunks.count - 1)
    #expect(resumed.episode.settings.voice == "af_heart" && resumed.episode.settings.backendSettings["speed"]?.numericValue == 1.25)
}

@Test func reviewedSpeechRefusesBlockedSourcesBeforeCreatingStorage() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let review = try reviewedArticle()
    for issue in [SourceReviewIssue.login, .consent, .accessBlocked, .extraction] {
        let blocked = ReviewedSource(page: review.page, document: review.document, narration: review.narration, issue: issue)
        let folder = root.appendingPathComponent(issue.rawValue)
        do {
            _ = try await FixtureCoordinator().runReviewed(root: folder, review: blocked, backend: SyntheticSpeechContractBackend("test"))
            Issue.record("Unreviewable source accepted")
        } catch { #expect(error is RelayError) }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
    let missing = root.appendingPathComponent("missing")
    #expect(try await FixtureCoordinator().library(root: missing).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: missing.path))
}

@Test func reviewedSpeechPreservesPublishedRevisionAndRejectsTamperedResume() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("articles")
    let original = try await FixtureCoordinator().runReviewed(root: folder, review: reviewedArticle(), backend: SyntheticSpeechContractBackend("test"))
    let before = try [original.audioURL, original.feedURL].map(Files.hash)
    do {
        _ = try await FixtureCoordinator().runReviewed(root: folder, review: reviewedArticle(changed: true), backend: SyntheticSpeechContractBackend("test"))
        Issue.record("Published revision replaced")
    } catch { #expect(error is RelayError) }
    #expect(try [original.audioURL, original.feedURL].map(Files.hash) == before)
    let raw = original.episode.settings.work.appendingPathComponent(original.episode.id).appendingPathComponent("source.html")
    try Files.write(Data("tampered source".utf8), to: raw)
    do {
        _ = try await FixtureCoordinator().resumeReviewed(root: folder, articleID: original.episode.id, backend: SyntheticSpeechContractBackend("test"))
        Issue.record("Tampered review resumed")
    } catch { #expect(error is RelayError) }
    #expect(try [original.audioURL, original.feedURL].map(Files.hash) == before)
}

@Test func managedSpeechStoresOnlyAudioInChosenFolderAndSurvivesTemporaryCleanup() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("hosted-audio"); try Files.directory(audio)
    let existing = audio.appendingPathComponent("existing.txt"); try Files.write(Data("preserve".utf8), to: existing)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("app-data"),
                                       temporaryRoot: root.appendingPathComponent("scratch"))
    let first = try await FixtureCoordinator().runReviewed(root: storage.stateRoot, review: reviewedArticle(),
        backend: SyntheticSpeechContractBackend("managed-v1"), speed: 1.25, storage: storage)
    #expect(Files.samePath(first.audioURL.deletingLastPathComponent(), audio))
    #expect(try FileManager.default.contentsOfDirectory(atPath: audio.path).sorted() == ["existing.txt", first.episode.id + ".m4a"].sorted())
    #expect(try String(contentsOf: existing, encoding: .utf8) == "preserve")
    #expect(!FileManager.default.fileExists(atPath: first.episode.settings.work.appendingPathComponent(first.episode.id).path))
    let hashes = try [first.audioURL, first.feedURL].map(Files.hash)
    try FileManager.default.removeItem(at: storage.temporaryRoot)
    let resumed = try await FixtureCoordinator().resume(storage: storage, articleID: first.episode.id,
        backend: SyntheticSpeechContractBackend("unused-new-backend"))
    #expect(resumed.synthesizedChunks == 0 && resumed.episode.id == first.episode.id)
    #expect(resumed.episode.settings.backendSettings["speed"]?.numericValue == 1.25)
    #expect(try [first.audioURL, first.feedURL].map(Files.hash) == hashes)
    #expect(resumed.article == first.article && resumed.narration == first.narration)
}

@Test func managedSpeechResumeRebuildsPurgedScratchWithoutFetchingOrChangingSettings() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"),
                                       temporaryRoot: root.appendingPathComponent("scratch"))
    do {
        _ = try await FixtureCoordinator().runReviewed(root: storage.stateRoot, review: reviewedArticle(),
            backend: SyntheticSpeechContractBackend("managed-v1"), voice: "bf_emma", speed: 1.3,
            interruptAfter: .chunkCommitted, storage: storage)
        Issue.record("Expected interruption")
    } catch { #expect(error as? RelayError == .interrupted) }
    let saved = try #require(await FixtureCoordinator().library(storage: storage).first)
    try FileManager.default.removeItem(at: storage.temporaryRoot)
    // Simulate the per-user temporary directory changing after a reboot.
    let afterReboot = ManagedSpeechStorage(audioDirectory: audio, stateRoot: storage.stateRoot,
                                          temporaryRoot: root.appendingPathComponent("new-scratch"))
    let resumed = try await FixtureCoordinator().resume(storage: afterReboot, articleID: saved.id,
        backend: SyntheticSpeechContractBackend("managed-v1"))
    #expect(resumed.synthesizedChunks == resumed.narration.chunks.count)
    #expect(resumed.episode.id == saved.id && resumed.episode.settings.voice == "bf_emma")
    #expect(resumed.episode.settings.backendSettings["speed"]?.numericValue == 1.3)
    #expect(Files.contains(afterReboot.temporaryRoot, resumed.episode.settings.work))
}

@Test func managedAudioLocationChangesAffectNewArticlesAndPreserveSavedDestinations() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let firstAudio = root.appendingPathComponent("first-audio"), secondAudio = root.appendingPathComponent("second-audio")
    try Files.directory(firstAudio); try Files.directory(secondAudio)
    let firstStorage = ManagedSpeechStorage(audioDirectory: firstAudio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let first = try await FixtureCoordinator().runReviewed(root: firstStorage.stateRoot, review: reviewedArticle(),
        backend: SyntheticSpeechContractBackend("managed"), storage: firstStorage)
    let secondStorage = ManagedSpeechStorage(audioDirectory: secondAudio, stateRoot: firstStorage.stateRoot, temporaryRoot: firstStorage.temporaryRoot)
    let second = try await FixtureCoordinator().runReviewed(root: secondStorage.stateRoot, review: reviewedArticle("two"),
        backend: SyntheticSpeechContractBackend("managed"), storage: secondStorage)
    #expect(Files.samePath(second.audioURL.deletingLastPathComponent(), secondAudio))
    #expect(try await FixtureCoordinator().library(storage: secondStorage).count == 2)
    let hash = try Files.hash(first.audioURL)
    let resumed = try await FixtureCoordinator().resume(storage: secondStorage, articleID: first.episode.id, backend: SyntheticSpeechContractBackend("managed"))
    #expect(resumed.audioURL == first.audioURL)
    #expect(try Files.hash(first.audioURL) == hash)
    #expect(try FileManager.default.contentsOfDirectory(atPath: secondAudio.path) == [second.episode.id + ".m4a"])
}

@Test func managedStorageRefusesMissingDestinationAndOverlapsWithoutCreatingIt() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("missing-volume/audio"),
        stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    #expect(try await FixtureCoordinator().library(storage: storage).isEmpty)
    do {
        _ = try await FixtureCoordinator().runReviewed(root: storage.stateRoot, review: reviewedArticle(),
            backend: SyntheticSpeechContractBackend("managed"), storage: storage)
        Issue.record("Missing destination was recreated")
    } catch { #expect(error is RelayError) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    for audio in [storage.stateRoot, root, storage.temporaryRoot] {
        #expect(throws: RelayError.self) {
            try ManagedSpeechStorage(audioDirectory: audio, stateRoot: storage.stateRoot, temporaryRoot: storage.temporaryRoot).validate()
        }
    }
}

@Test func managedResumeRejectsTamperedSnapshotAndLinkedAudioWithoutTouchingTarget() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let result = try await FixtureCoordinator().runReviewed(root: storage.stateRoot, review: reviewedArticle(),
        backend: SyntheticSpeechContractBackend("managed"), storage: storage)
    let originalHash = try Files.hash(result.audioURL)
    do {
        let store = try NativeStore(url: storage.profile.database)
        let original = try #require(try store.snapshot(articleID: result.episode.id))
        try store.execute("UPDATE snapshots SET record=? WHERE article_id=?", [Data("tampered".utf8).base64EncodedString(), result.episode.id])
        #expect(throws: RelayError.self) { try store.snapshot(articleID: result.episode.id) }
        try store.saveSnapshot(articleID: result.episode.id, data: original)
    }
    let outside = root.appendingPathComponent("existing-audio"); try Files.write(Data("preserve".utf8), to: outside)
    try FileManager.default.removeItem(at: result.audioURL)
    try FileManager.default.createSymbolicLink(at: result.audioURL, withDestinationURL: outside)
    do {
        _ = try await FixtureCoordinator().resume(storage: storage, articleID: result.episode.id, backend: SyntheticSpeechContractBackend("managed"))
        Issue.record("Linked audio was accepted")
    } catch { #expect(error is RelayError) }
    #expect(try String(contentsOf: outside, encoding: .utf8) == "preserve")
    #expect(originalHash != Files.hash(Data("preserve".utf8)))
}

@Test func nativeSchemaOneUpgradePreservesEpisodesAndAddsSnapshots() throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("native.sqlite3")
    let profile = PrototypeProfile.fixture(at: root)
    let id: String
    do {
        let store = try NativeStore(url: database)
        id = try store.episode(sourceKey: "preserved", settings: profile).id
        try store.execute("DROP TABLE snapshots")
        try store.execute("DROP TABLE reading_list_inventory")
        try store.execute("DROP TABLE speech_queue")
        try store.execute("PRAGMA user_version=1")
    }
    do {
        let readOnly = try NativeStore(url: database, readOnly: true)
        #expect(try readOnly.episodes().first?.id == id)
        #expect(try readOnly.query("PRAGMA user_version").first?.first == "1")
    }
    let upgraded = try NativeStore(url: database)
    #expect(try upgraded.query("PRAGMA user_version").first?.first == String(NativeStore.schemaVersion))
    #expect(try upgraded.episodes().first?.id == id)
    try upgraded.saveSnapshot(articleID: id, data: Data("retained".utf8))
    #expect(try upgraded.snapshot(articleID: id) == Data("retained".utf8))
}

@Test func managedSampleSpeechUsesSameAudioDestinationAndLibrary() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let result = try await FixtureCoordinator().runSpeech(root: storage.stateRoot, backend: SyntheticSpeechContractBackend("managed"), storage: storage)
    #expect(Files.samePath(result.audioURL.deletingLastPathComponent(), audio))
    #expect(try await FixtureCoordinator().library(storage: storage).first?.id == result.episode.id)
    let resumed = try await FixtureCoordinator().resume(storage: storage, articleID: result.episode.id, backend: SyntheticSpeechContractBackend("managed"))
    #expect(resumed.synthesizedChunks == 0 && resumed.episode.id == result.episode.id)
}

@Test func durableReadingListRetainsAbsentEntriesAndClearsLegacyExclusionsAcrossLaunches() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let state = root.appendingPathComponent("state")
    #expect(try await FixtureCoordinator().catalog(stateRoot: state).entries.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: state.path))
    let one = ReadingListEntry(id: "safari:one", safariID: "one", url: URL(string: "https://articles.example/one")!, title: "One", addedAt: nil)
    let two = ReadingListEntry(id: "safari:two", safariID: "two", url: URL(string: "https://articles.example/two")!, title: "Two", addedAt: nil)
    _ = try await FixtureCoordinator().reconcile(ReadingListSnapshot(entries: [one], skippedEntries: 0), stateRoot: state)
    // Older builds persisted exclusions; a saved catalog can still carry them until the next reconcile.
    do {
        let store = try NativeStore(url: PrototypeProfile.fixture(at: state).database)
        var legacy = try store.catalog(); legacy.excludedIDs = [one.id]; try store.saveCatalog(legacy)
    }
    _ = try await FixtureCoordinator().reconcile(ReadingListSnapshot(entries: [two], skippedEntries: 0), stateRoot: state)
    let restored = try await FixtureCoordinator().catalog(stateRoot: state)
    #expect(restored.entries == [one, two] && restored.currentIDs == [two.id] && restored.excludedIDs.isEmpty)
    let database = PrototypeProfile.fixture(at: state).database
    let before = try Files.hash(database)
    #expect(throws: RelayError.self) { try ReadingList.parse(Data("incomplete plist".utf8)) }
    #expect(try Files.hash(database) == before)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["state"])
}

@Test func queueEnqueueCapturesTextAndOptionsWithoutAudioOrScratchAndDeduplicates() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"), scratch = root.appendingPathComponent("scratch")
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: scratch)
    let first = try await FixtureCoordinator().enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences(voice: .emma, speed: 1.2))
    let otherFolder = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("other-audio"), stateRoot: storage.stateRoot, temporaryRoot: scratch)
    let duplicate = try await FixtureCoordinator().enqueue(reviewedArticle(), storage: otherFolder, preferences: SpeechPreferences())
    #expect(first.id == duplicate.id && duplicate.state == .queued && duplicate.attempts == 0)
    #expect(try await FixtureCoordinator().queue(stateRoot: storage.stateRoot).count == 1)
    let episode = try #require(await FixtureCoordinator().library(storage: storage).first)
    #expect(episode.id == first.id && episode.stage == .extracted && episode.settings.voice == "bf_emma")
    #expect(episode.settings.backendSettings["speed"]?.numericValue == 1.2)
    #expect(Files.samePath(episode.settings.audio, audio))
    #expect(!FileManager.default.fileExists(atPath: audio.path) && !FileManager.default.fileExists(atPath: scratch.path))
    do {
        _ = try await FixtureCoordinator().enqueue(reviewedArticle(changed: true), storage: storage, preferences: SpeechPreferences())
        Issue.record("Queued source revision was replaced")
    } catch { #expect(error is RelayError) }
    #expect(try await FixtureCoordinator().queue(stateRoot: storage.stateRoot).first == first)
}

@Test func queueRunsFIFOOfflineWithCapturedSettingsAndStableCompletedAudio() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let first = try await FixtureCoordinator().enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences(voice: .bella, speed: 1.25))
    let second = try await FixtureCoordinator().enqueue(reviewedArticle("two"), storage: storage, preferences: SpeechPreferences())
    let backend: @Sendable (Episode) throws -> any TTSBackend = { _ in SyntheticSpeechContractBackend("queued") }
    let result = try #require(try await FixtureCoordinator().runNextQueued(storage: storage, backend: backend))
    #expect(result.episode.id == first.id && result.episode.settings.voice == "af_bella")
    #expect(result.episode.settings.backendSettings["speed"]?.numericValue == 1.25)
    let next = try #require(try await FixtureCoordinator().runNextQueued(storage: storage, backend: backend))
    #expect(next.episode.id == second.id)
    #expect(try await FixtureCoordinator().runNextQueued(storage: storage, backend: backend) == nil)
    let completed = try await FixtureCoordinator().queue(stateRoot: storage.stateRoot)
    #expect(completed.isEmpty)
    let hash = try Files.hash(result.audioURL)
    let repeatResult = try await FixtureCoordinator().resume(storage: storage, articleID: first.id, backend: backend(result.episode))
    #expect(repeatResult.synthesizedChunks == 0)
    #expect(try Files.hash(result.audioURL) == hash)
    #expect(try await FixtureCoordinator().queue(stateRoot: storage.stateRoot).isEmpty)
    #expect(try String(contentsOf: next.feedURL, encoding: .utf8).components(separatedBy: "<item>").count == 3)
}

@Test func queueFailureAndCancellationRequireExplicitRetryAndKeepApprovedText() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let item = try await FixtureCoordinator().enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    do {
        _ = try await FixtureCoordinator().runQueued(item.id, storage: storage, backend: { _ in
            let running = try NativeStore(url: storage.profile.database, readOnly: true).queue()
            #expect(running.first?.state == .running && running.first?.attempts == 1)
            throw NSError(domain: "PRIVATE_TOKEN_AND_URL", code: 1)
        })
        Issue.record("Expected failure")
    } catch { #expect(error is NSError) }
    let failed = try #require(await FixtureCoordinator().queue(stateRoot: storage.stateRoot).first)
    #expect(failed.state == .failed && failed.attempts == 1 && failed.lastError?.contains("PRIVATE") == false)
    #expect(try await FixtureCoordinator().runNextQueued(storage: storage, backend: { _ in SyntheticSpeechContractBackend("unused") }) == nil)
    _ = try await FixtureCoordinator().retryQueued(item.id, stateRoot: storage.stateRoot)
    do {
        _ = try await FixtureCoordinator().runQueued(item.id, storage: storage, backend: { _ in throw CancellationError() })
        Issue.record("Expected cancellation")
    } catch { #expect(error is CancellationError) }
    #expect(try await FixtureCoordinator().queue(stateRoot: storage.stateRoot).first?.state == .paused)
    _ = try await FixtureCoordinator().retryQueued(item.id, stateRoot: storage.stateRoot)
    let result = try await FixtureCoordinator().runQueued(item.id, storage: storage, backend: { _ in
        let attempts = try NativeStore(url: storage.profile.database, readOnly: true).queue().first?.attempts
        #expect(attempts == 3)
        return SyntheticSpeechContractBackend("queued")
    })
    #expect(result.episode.id == item.id)
    #expect(try await FixtureCoordinator().queue(stateRoot: storage.stateRoot).isEmpty)
}

@Test func queueInterruptedClaimNeverRestartsWithoutOperatorRetry() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    var interrupted = try await FixtureCoordinator().enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    interrupted.state = .running; interrupted.attempts = 1
    do { try NativeStore(url: storage.profile.database).saveQueueItem(interrupted) }
    #expect(try await FixtureCoordinator().queue(stateRoot: storage.stateRoot).first?.state == .running)
    do {
        _ = try await FixtureCoordinator().runNextQueued(storage: storage, backend: { _ in Issue.record("Unexpected synthesis"); return SyntheticSpeechContractBackend("unused") })
        Issue.record("Stale claim was restarted")
    } catch { #expect(error is RelayError) }
    _ = try await FixtureCoordinator().retryQueued(interrupted.id, stateRoot: storage.stateRoot)
    let result = try await FixtureCoordinator().runNextQueued(storage: storage, backend: { _ in
        let attempts = try NativeStore(url: storage.profile.database, readOnly: true).queue().first?.attempts
        #expect(attempts == 2)
        return SyntheticSpeechContractBackend("queued")
    })
    #expect(result?.episode.id == interrupted.id)
    #expect(try await FixtureCoordinator().queue(stateRoot: storage.stateRoot).isEmpty)
}

@Test func legacyExcludedPausedQueueItemRetriesAndRunsWithoutAnIncludeStep() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let review = try reviewedArticle()
    let entry = ReadingListEntry(id: "safari:one", safariID: "one", url: review.page.originalURL, title: "One", addedAt: nil)
    _ = try await FixtureCoordinator().reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0), stateRoot: storage.stateRoot)
    let item = try await FixtureCoordinator().enqueue(review, storage: storage, preferences: SpeechPreferences(), sourceEntryID: entry.id)
    // Seed the state older builds left behind: a persisted exclusion and its paused queue row.
    do {
        let store = try NativeStore(url: storage.profile.database)
        var catalog = try store.catalog(); catalog.excludedIDs = [entry.id]; try store.saveCatalog(catalog)
        var paused = try #require(try store.queue().first)
        paused.state = .paused; paused.lastError = "This article is excluded. Include it before retrying."
        try store.saveQueueItem(paused)
    }
    let retried = try await FixtureCoordinator().retryQueued(item.id, stateRoot: storage.stateRoot)
    #expect(retried.state == .queued && retried.lastError == nil)
    let result = try await FixtureCoordinator().runNextQueued(storage: storage, backend: { _ in SyntheticSpeechContractBackend("queued") })
    #expect(result?.episode.id == item.id)
}

private final class CountingBatchBackend: TTSBackend, @unchecked Sendable {
    let identity: BackendIdentity
    private let lock = NSLock()
    private var preparedCount = 0, cancelledCount = 0
    var prepares: Int { lock.withLock { preparedCount } }
    var cancels: Int { lock.withLock { cancelledCount } }
    init(_ id: String) { identity = BackendIdentity(id: id, displayName: "Counting batch test", isMock: false) }
    func prepare() throws { lock.withLock { preparedCount += 1 } }
    func cancel() { lock.withLock { cancelledCount += 1 } }
    func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult {
        try SyntheticAudioBackend().synthesize(request, directory: directory)
    }
}
private final class BatchBackendLog: @unchecked Sendable {
    private let lock = NSLock()
    private var providers: [CountingBatchBackend] = []
    var constructed: [CountingBatchBackend] { lock.withLock { providers } }
    func append(_ provider: CountingBatchBackend) { lock.withLock { providers.append(provider) } }
}

@Test func queueBatchReusesPreparedBackendForMatchingIdentityAndCancelsOnce() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    _ = try await FixtureCoordinator().enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    _ = try await FixtureCoordinator().enqueue(reviewedArticle("two"), storage: storage, preferences: SpeechPreferences())
    let log = BatchBackendLog()
    let result = try await FixtureCoordinator().runQueuedBatch(storage: storage, backend: { _ in
        let provider = CountingBatchBackend("shared-identity"); log.append(provider); return provider
    })
    #expect(result.progress.completedArticles == 2 && log.constructed.count == 2)
    let active = try #require(log.constructed.first)
    // The matching candidate is discarded untouched; the reused provider prepares once per
    // article and is cancelled exactly once when the batch ends.
    #expect(active.prepares == 2 && active.cancels == 1)
    #expect(log.constructed[1].prepares == 0 && log.constructed[1].cancels == 0)
    #expect(try await FixtureCoordinator().queue(stateRoot: storage.stateRoot).isEmpty)
}

@Test func queueBatchReplacesBackendAcrossDifferingIdentities() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    _ = try await FixtureCoordinator().enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    _ = try await FixtureCoordinator().enqueue(reviewedArticle("two"), storage: storage, preferences: SpeechPreferences())
    let log = BatchBackendLog()
    let result = try await FixtureCoordinator().runQueuedBatch(storage: storage, backend: { _ in
        let provider = CountingBatchBackend("identity-\(log.constructed.count)"); log.append(provider); return provider
    })
    #expect(result.progress.completedArticles == 2 && log.constructed.count == 2)
    for provider in log.constructed { #expect(provider.prepares == 1 && provider.cancels == 1) }
    #expect(try await FixtureCoordinator().queue(stateRoot: storage.stateRoot).isEmpty)
}

@Test func competingWriterReportsBusyAfterBoundedRetry() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let item = try await FixtureCoordinator().enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    let owner = try NativeStore(url: storage.profile.database)
    do {
        _ = try NativeStore(url: storage.profile.database); Issue.record("Competing writer accepted")
    } catch {
        #expect(error as? RelayError == .writerBusy)
        #expect(error.localizedDescription == "Another native coordinator owns this fixture database.")
    }
    let start = ProcessInfo.processInfo.systemUptime
    do {
        _ = try await FixtureCoordinator().retryQueued(item.id, stateRoot: storage.stateRoot)
        Issue.record("Retry ran while another writer held the lock")
    } catch { #expect(error as? RelayError == .writerBusy) }
    #expect(ProcessInfo.processInfo.systemUptime - start >= 1.5)
    _ = owner
    #expect(try await FixtureCoordinator().queue(stateRoot: storage.stateRoot).first?.state == .queued)
}

@Test func helperErrorCodesMapDistinctMessagesAndRejectUnsafeDetail() {
    #expect(ExecutableSpeechBackend.helperFailure(code: "not_prepared", detail: nil)
        == .setup("Speech helper lost its prepared session; completed chunks are retained."))
    #expect(ExecutableSpeechBackend.helperFailure(code: "invalid_audio", detail: nil)
        == .artifact("The speech engine produced invalid audio; completed chunks are retained."))
    #expect(ExecutableSpeechBackend.helperFailure(code: "empty_audio", detail: nil)
        == .artifact("The speech engine produced no audio for one chunk; completed chunks are retained."))
    #expect(ExecutableSpeechBackend.helperFailure(code: "synthesis_failed", detail: "MemoryError")
        == .artifact("Speech synthesis failed inside the local engine (engine error: MemoryError); completed chunks are retained."))
    for unsafe in ["/private/var/model", "../secret", "a message with spaces", "token-with-dashes", String(repeating: "A", count: 41)] {
        let failure = ExecutableSpeechBackend.helperFailure(code: "synthesis_failed", detail: unsafe)
        #expect(failure == .artifact("Speech synthesis failed inside the local engine; completed chunks are retained."))
        #expect(!failure.localizedDescription.contains(unsafe))
    }
    #expect(ExecutableSpeechBackend.helperFailure(code: "missing_assets", detail: "MemoryError").localizedDescription.contains("Run explicit project-local setup."))
    #expect(ExecutableSpeechBackend.helperFailure(code: "unknown", detail: nil)
        == .artifact("Speech helper failed; completed chunks are retained."))
}

@Test func queueRemovalAndUnavailableAudioPreserveEpisodeAndNeverCreateDestination() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("unmounted/audio")
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let item = try await FixtureCoordinator().enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    do {
        _ = try await FixtureCoordinator().runQueued(item.id, storage: storage, backend: { _ in SyntheticSpeechContractBackend("queued") })
        Issue.record("Missing destination was created")
    } catch { #expect(error is RelayError) }
    #expect(!FileManager.default.fileExists(atPath: audio.path) && !FileManager.default.fileExists(atPath: storage.temporaryRoot.path))
    #expect(try await FixtureCoordinator().queue(stateRoot: storage.stateRoot).first?.state == .failed)
    try await FixtureCoordinator().removeFromQueue(item.id, stateRoot: storage.stateRoot)
    #expect(try await FixtureCoordinator().queue(stateRoot: storage.stateRoot).isEmpty)
    #expect(try await FixtureCoordinator().library(storage: storage).first?.id == item.id)
    let readded = try await FixtureCoordinator().enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    #expect(readded.id == item.id && readded.state == .queued)
}

@Test func nativeSchemaTwoUpgradePreservesSnapshotAndEpisodeBytes() throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("native.sqlite3")
    let id: String, record: String
    do {
        let store = try NativeStore(url: database)
        id = try store.episode(sourceKey: "retained", settings: PrototypeProfile.fixture(at: root)).id
        try store.saveSnapshot(articleID: id, data: Data("unchanged approved text".utf8))
        record = try #require(try store.query("SELECT record FROM episodes").first?.first)
        try store.execute("DROP TABLE reading_list_inventory"); try store.execute("DROP TABLE speech_queue")
        try store.execute("PRAGMA user_version=2")
    }
    let store = try NativeStore(url: database)
    #expect(try store.query("PRAGMA user_version").first?.first == "3")
    #expect(try store.query("SELECT record FROM episodes").first?.first == record)
    #expect(try store.snapshot(articleID: id) == Data("unchanged approved text".utf8))
    #expect(try store.catalog().entries.isEmpty)
    #expect(try store.queue().isEmpty)
}

@Test func queuedSpeechRefusesCompetingWriterBeforeClaimOrInference() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"), stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let item = try await FixtureCoordinator().enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    do {
        let writer = try NativeStore(url: storage.profile.database)
        do {
            _ = try await FixtureCoordinator().runQueued(item.id, storage: storage, backend: { _ in
                Issue.record("Inference started with a competing writer"); return SyntheticSpeechContractBackend("unused")
            })
            Issue.record("Competing writer accepted")
        } catch { #expect(error is RelayError) }
        #expect(try writer.queue().first?.state == .queued)
        #expect(try writer.queue().first?.attempts == 0)
    }
    #expect(try await FixtureCoordinator().queue(stateRoot: storage.stateRoot).first?.state == .queued)
    #expect(!FileManager.default.fileExists(atPath: storage.temporaryRoot.path))
}

@Test func queueBlockedSourceRefusalCreatesNeitherMetadataNorOutput() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let review = try reviewedArticle()
    let blocked = ReviewedSource(page: review.page, document: review.document, narration: review.narration, issue: .login)
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"), stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    do { _ = try await FixtureCoordinator().enqueue(blocked, storage: storage, preferences: SpeechPreferences()); Issue.record("Blocked page queued") }
    catch { #expect(error is RelayError) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test func readingListMultiSelectionRetainsInventoryOrderAndIncludesLegacyExclusions() throws {
    let entries = try ["one", "two", "three"].map { path in
        ReadingListEntry(id: path, safariID: path, url: try reviewedArticle(path).page.originalURL, title: path, addedAt: nil)
    }
    var catalog = ReadingListCatalog()
    catalog.reconcile(ReadingListSnapshot(entries: entries, skippedEntries: 0))
    catalog.excludedIDs = ["two"]
    #expect(catalog.selectedEntries(["three", "missing", "two", "one"]) == entries)
    #expect(catalog.selectedEntries([]).isEmpty)
}

@Test func readingListQueuePreparesSelectedArticlesWithoutReviewOrInferenceInListOrder() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"), stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let pages = try [reviewedArticle().page, reviewedArticle("two").page]
    let entries = pages.enumerated().map { index, page in
        ReadingListEntry(id: "entry-\(index)", safariID: nil, url: page.originalURL, title: "Article \(index)", addedAt: nil)
    }
    let coordinator = FixtureCoordinator()
    let catalog = try await coordinator.reconcile(ReadingListSnapshot(entries: entries, skippedEntries: 0), stateRoot: storage.stateRoot)
    var ids: [String] = []
    for entry in catalog.selectedEntries(Set(entries.map(\.id))) {
        let item = try await coordinator.enqueueReadingList(entry.id, storage: storage, preferences: SpeechPreferences(voice: .bella, speed: 1.2), fetch: { url in
            try #require(pages.first { $0.originalURL == url })
        })
        ids.append(item.id)
    }
    let queue = try await FixtureCoordinator().queue(stateRoot: storage.stateRoot)
    #expect(queue.map(\.id) == ids && queue.map(\.state) == [.queued, .queued] && queue.map(\.attempts) == [0, 0])
    let episodes = try await coordinator.library(storage: storage)
    #expect(episodes.allSatisfy { $0.stage == .extracted && $0.settings.voice == "af_bella" && $0.settings.backendSettings["speed"]?.numericValue == 1.2 })
    #expect(!FileManager.default.fileExists(atPath: storage.audioDirectory.path))
    #expect(!FileManager.default.fileExists(atPath: storage.temporaryRoot.path))
}

@Test func readingListQueueReusesSavedSourceOfflineAndBindsDiagnosticEntryWithoutChangingSettings() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"), stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let review = try reviewedArticle()
    let entry = ReadingListEntry(id: "saved", safariID: nil, url: review.page.originalURL, title: "Saved", addedAt: nil)
    let coordinator = FixtureCoordinator()
    _ = try await coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0), stateRoot: storage.stateRoot)
    let original = try await coordinator.enqueue(review, storage: storage, preferences: SpeechPreferences(voice: .emma, speed: 1.25))
    let reused = try await coordinator.enqueueReadingList(entry.id, storage: storage, preferences: SpeechPreferences(), fetch: { _ in
        Issue.record("Saved article fetched again"); throw SourceFetchError.network
    })
    #expect(reused.id == original.id && reused.sourceEntryID == entry.id)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).count == 1)
    try await coordinator.removeFromQueue(reused.id, stateRoot: storage.stateRoot)
    let readded = try await coordinator.enqueueReadingList(entry.id, storage: storage, preferences: SpeechPreferences(), fetch: { _ in
        Issue.record("Removed queue article fetched again"); throw SourceFetchError.network
    })
    #expect(readded.id == original.id && readded.state == .queued)
    let episode = try #require(await coordinator.library(storage: storage).first)
    #expect(episode.settings.voice == "bf_emma" && episode.settings.backendSettings["speed"]?.numericValue == 1.25)
    _ = try await coordinator.enqueueReadingList(entry.id, storage: storage, preferences: SpeechPreferences(), fetch: { _ in
        Issue.record("Saved article fetched again"); throw SourceFetchError.network
    })
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).count == 1)
}

@Test func readingListQueueRejectsUnavailableAndMismatchedSourceBeforeSaving() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"), stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let review = try reviewedArticle()
    let entry = ReadingListEntry(id: "one", safariID: nil, url: review.page.originalURL, title: "One", addedAt: nil)
    let coordinator = FixtureCoordinator()
    _ = try await coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0), stateRoot: storage.stateRoot)
    do {
        _ = try await coordinator.enqueueReadingList("missing", storage: storage, preferences: SpeechPreferences(), fetch: { _ in
            Issue.record("Unavailable entry fetched"); return review.page
        })
        Issue.record("Unavailable entry queued")
    } catch { #expect(error is RelayError) }
    let wrong = try reviewedArticle("different").page
    do {
        _ = try await coordinator.enqueueReadingList(entry.id, storage: storage, preferences: SpeechPreferences(), fetch: { _ in wrong })
        Issue.record("Mismatched article queued")
    } catch { #expect(error is RelayError) }
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    #expect(try await coordinator.library(storage: storage).isEmpty)
}

@Test func readingListQueueRetainsEarlierItemsWhenFetchIsBlockedFailsOrIsCancelled() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"), stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let one = try reviewedArticle().page, two = try reviewedArticle("two").page
    let entries = [one, two].enumerated().map { ReadingListEntry(id: String($0.offset), safariID: nil, url: $0.element.originalURL, title: "Entry", addedAt: nil) }
    let coordinator = FixtureCoordinator()
    _ = try await coordinator.reconcile(ReadingListSnapshot(entries: entries, skippedEntries: 0), stateRoot: storage.stateRoot)
    let first = try await coordinator.enqueueReadingList("0", storage: storage, preferences: SpeechPreferences(), fetch: { _ in one })
    let html = "<html><title>Cookie consent</title><body>Consent required</body></html>"
    let blocked = FetchedPage(originalURL: two.originalURL, finalURL: two.finalURL, bytes: Data(html.utf8), html: html, contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast)
    for mode in 0..<3 {
        do {
            _ = try await coordinator.enqueueReadingList("1", storage: storage, preferences: SpeechPreferences(), fetch: { _ in
                if mode == 0 { return blocked }
                if mode == 1 { throw SourceFetchError.network }
                throw CancellationError()
            })
            Issue.record("Unusable source queued")
        } catch {
            if mode == 0 { #expect(error.localizedDescription.contains("Articles")) }
            if mode == 1 { #expect(error as? SourceFetchError == .network) }
            if mode == 2 { #expect(error is CancellationError) }
        }
        #expect(try await coordinator.queue(stateRoot: storage.stateRoot) == [first])
    }
}

@Test func readingListQueueIgnoresLegacyExclusionWhenSaving() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"), stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let page = try reviewedArticle().page
    let entry = ReadingListEntry(id: "one", safariID: nil, url: page.originalURL, title: "One", addedAt: nil)
    let coordinator = FixtureCoordinator()
    _ = try await coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0), stateRoot: storage.stateRoot)
    do {
        let store = try NativeStore(url: storage.profile.database)
        var catalog = try store.catalog(); catalog.excludedIDs = [entry.id]; try store.saveCatalog(catalog)
    }
    let item = try await coordinator.enqueueReadingList(entry.id, storage: storage, preferences: SpeechPreferences(), fetch: { _ in page })
    #expect(item.state == .queued && item.sourceEntryID == entry.id)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot) == [item])
    #expect(try await coordinator.library(storage: storage).count == 1)
}

@Test func resetQueuePreservesReadingListPlistHistoryAndAudio() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let plist = root.appendingPathComponent("reading-list.plist")
    try Files.write(try PropertyListSerialization.data(fromPropertyList: ["reading-list": ["entry"]], format: .binary, options: 0), to: plist)
    let entry = ReadingListEntry(id: "one", safariID: nil, url: try reviewedArticle("one", host: "synthetic.example").page.originalURL, title: "One", addedAt: nil)
    _ = try await coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0), stateRoot: storage.stateRoot)
    _ = try await coordinator.enqueue(reviewedArticle("one", host: "synthetic.example"), storage: storage, preferences: SpeechPreferences())
    var two = try await coordinator.enqueue(reviewedArticle("two", host: "synthetic.example"), storage: storage, preferences: SpeechPreferences())
    two.state = .running; two.attempts = 1
    let published = try await coordinator.runReviewed(root: storage.stateRoot, review: reviewedArticle("published", host: "synthetic.example"), backend: TwoArtifactBackend(), storage: storage)
    try { () throws -> Void in
        let store = try NativeStore(url: storage.profile.database)
        try store.saveQueueItem(two)
    }()
    let captured = try { () throws -> (records: [String], chunks: [String], snapshot: Data?, catalog: String) in
        let store = try NativeStore(url: storage.profile.database, readOnly: true)
        return (try store.query("SELECT record FROM episodes ORDER BY id").map { $0[0] },
                try store.query("SELECT checkpoint FROM chunks ORDER BY article_id,chunk_index").map { $0[0] },
                try store.snapshot(articleID: published.episode.id),
                String(decoding: try Files.json(try store.catalog()), as: UTF8.self))
    }()
    let plistBytes = try Data(contentsOf: plist)
    let audioBytes = try Data(contentsOf: published.audioURL)
    let feedBytes = try Data(contentsOf: published.feedURL)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).count == 2)
    try await coordinator.resetQueue(stateRoot: storage.stateRoot)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    try await coordinator.resetQueue(stateRoot: storage.stateRoot)
    let after = try { () throws -> (records: [String], chunks: [String], snapshot: Data?, catalog: String) in
        let store = try NativeStore(url: storage.profile.database, readOnly: true)
        return (try store.query("SELECT record FROM episodes ORDER BY id").map { $0[0] },
                try store.query("SELECT checkpoint FROM chunks ORDER BY article_id,chunk_index").map { $0[0] },
                try store.snapshot(articleID: published.episode.id),
                String(decoding: try Files.json(try store.catalog()), as: UTF8.self))
    }()
    #expect(after.records == captured.records && after.chunks == captured.chunks
        && after.snapshot == captured.snapshot && after.catalog == captured.catalog)
    #expect(try Data(contentsOf: plist) == plistBytes && FileManager.default.fileExists(atPath: plist.path))
    #expect(try Data(contentsOf: published.audioURL) == audioBytes)
    #expect(try Data(contentsOf: published.feedURL) == feedBytes)
}

@Test func resetQueueMissingForeignCancelledAndCompetingOwnerDoNotMutate() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let absent = root.appendingPathComponent("absent")
    try await FixtureCoordinator().resetQueue(stateRoot: absent)
    #expect(!FileManager.default.fileExists(atPath: absent.path))
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let item = try await coordinator.enqueue(reviewedArticle("one", host: "synthetic.example"), storage: storage, preferences: SpeechPreferences())
    let plist = root.appendingPathComponent("reading-list.plist")
    try Files.write(try PropertyListSerialization.data(fromPropertyList: ["reading-list": ["entry"]], format: .binary, options: 0), to: plist)
    let plistBytes = try Data(contentsOf: plist)
    let foreign = root.appendingPathComponent("foreign")
    try Files.directory(foreign)
    try Files.write(Data(ManagedSpeechStorage.markerText.utf8), to: foreign.appendingPathComponent(".voicerelay-library"))
    try Files.directory(PrototypeProfile.fixture(at: foreign).database.deletingLastPathComponent())
    try { () throws -> Void in
        let store = try NativeStore(url: PrototypeProfile.fixture(at: foreign).database)
        try store.execute("PRAGMA application_id=424242")
    }()
    do { try await coordinator.resetQueue(stateRoot: foreign); Issue.record("Foreign state reset") }
    catch { #expect(error is RelayError) }
    var handle: OpaquePointer?
    #expect(sqlite3_open(PrototypeProfile.fixture(at: foreign).database.path, &handle) == SQLITE_OK)
    #expect(sqlite3_exec(handle, "PRAGMA application_id=\(NativeStore.applicationID);PRAGMA user_version=\(NativeStore.schemaVersion + 1)", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(handle)
    do { try await coordinator.resetQueue(stateRoot: foreign); Issue.record("Newer schema reset") }
    catch { #expect(error is RelayError) }
    let cancelled = Task { try await coordinator.resetQueue(stateRoot: storage.stateRoot) }
    cancelled.cancel()
    do { try await cancelled.value; Issue.record("Cancelled reset ran") }
    catch { #expect(error is CancellationError) }
    let owner = try NativeStore(url: storage.profile.database)
    do { try await coordinator.resetQueue(stateRoot: storage.stateRoot); Issue.record("Competing owner reset") }
    catch { #expect(error is RelayError) }
    _ = owner
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot) == [item])
    #expect(try Data(contentsOf: plist) == plistBytes)
}

@Test func episodeVolumeIDDecodesAbsentAndCapturesOnPublication() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let result = try await FixtureCoordinator().runReviewed(root: storage.stateRoot, review: reviewedArticle("volume", host: "synthetic.example"), backend: TwoArtifactBackend(), storage: storage)
    let expected = (try? audio.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    #expect(result.episode.audioVolumeID == expected)
    var record = try #require(JSONSerialization.jsonObject(with: Files.json(result.episode)) as? [String: Any])
    record.removeValue(forKey: "audioVolumeID")
    let decoded = try JSONDecoder().decode(Episode.self, from: JSONSerialization.data(withJSONObject: record))
    #expect(decoded.audioVolumeID == nil)
}

private final class BatchProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [QueueBatchProgress] = []
    private var articles: [String] = []
    func append(_ value: QueueBatchProgress) { lock.withLock { updates.append(value) } }
    func complete(_ id: String) { lock.withLock { articles.append(id) } }
    var values: [QueueBatchProgress] { lock.withLock { updates } }
    var completedIDs: [String] { lock.withLock { articles } }
}

@Test func queueBatchReportsGlobalChunksAndEncodingUntilAllArticlesPublish() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let one = try reviewedArticle(), two = try reviewedArticle("two", changed: true)
    let coordinator = FixtureCoordinator()
    _ = try await coordinator.enqueue(one, storage: storage, preferences: SpeechPreferences())
    let second = try await coordinator.enqueue(two, storage: storage, preferences: SpeechPreferences())
    let expected = try #require(one.narration).chunks.count + (try #require(two.narration)).chunks.count
    let recorder = BatchProgressRecorder()
    let result = try await coordinator.runQueuedBatch(storage: storage, backend: { _ in SyntheticSpeechContractBackend("batch") }, onProgress: { recorder.append($0) })
    #expect(result.lastResult?.episode.id == second.id)
    #expect(result.progress.completedChunks == expected && result.progress.totalChunks == expected)
    #expect(result.progress.completedArticles == 2 && result.progress.fractionCompleted == 1)
    let updates = recorder.values
    #expect(updates.allSatisfy { $0.totalChunks == expected && $0.totalArticles == 2 })
    #expect(zip(updates, updates.dropFirst()).allSatisfy { $0.fractionCompleted <= $1.fractionCompleted })
    let encodings = updates.filter { $0.stage == .encoding }
    #expect(encodings.count == 2)
    #expect(encodings.map(\.currentArticleIndex) == [1, 2])
    #expect(result.progress.currentArticleIndex == nil)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    #expect(encodings.first?.completedChunks == one.narration?.chunks.count && encodings.first?.completedArticles == 0)
    #expect(encodings.last?.completedChunks == expected && encodings.last?.completedArticles == 1)
    #expect(encodings.allSatisfy { $0.fractionCompleted < 1 })
    let empty = try await coordinator.runQueuedBatch(storage: storage, backend: { _ in Issue.record("Completed batch invoked inference"); return SyntheticSpeechContractBackend("unused") })
    #expect(empty.lastResult == nil && empty.progress.totalArticles == 0 && empty.progress.totalChunks == 0)
}

@Test func queueBatchUpgradesLegacyNarrationAndCountsArticleBoundaries() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    try Files.directory(root.appendingPathComponent("audio"))
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"), stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator(), review = try reviewedArticle()
    let item = try await coordinator.enqueue(review, storage: storage, preferences: SpeechPreferences())
    let current = try #require(review.narration)
    // Simulate a valid older snapshot with only source-body chunks and matching hashes.
    do {
        let store = try NativeStore(url: storage.profile.database)
        let bytes = try #require(try store.snapshot(articleID: item.id))
        let snapshot = try JSONDecoder().decode(StoredExtraction.self, from: bytes)
        var files = snapshot.files
        let legacy = NarrationPlan(version: "conservative-2/legacy", chunks: current.chunks.filter { !$0.blockIndices.isEmpty }.enumerated().map {
            NarrationChunk(index: $0.offset, text: $0.element.text, blockIndices: $0.element.blockIndices)
        }, notices: current.notices)
        files["narration.json"] = try Files.json(legacy)
        var checkpoint = try #require(try JSONSerialization.jsonObject(with: files["extraction-checkpoint.json"]!) as? [String: Any])
        checkpoint["narrationVersion"] = legacy.version
        checkpoint["narrationHash"] = Files.hash(files["narration.json"]!)
        files["extraction-checkpoint.json"] = try JSONSerialization.data(withJSONObject: checkpoint)
        try store.saveSnapshot(articleID: item.id, data: Files.json(["files": files]))
    }
    let recorder = BatchProgressRecorder()
    let result = try await coordinator.runQueuedBatch(storage: storage, backend: { _ in SyntheticSpeechContractBackend("upgraded") }, onProgress: { recorder.append($0) })
    #expect(result.progress.totalChunks == current.chunks.count)
    #expect(result.progress.completedChunks == current.chunks.count && result.progress.fractionCompleted == 1)
    #expect(recorder.values.allSatisfy { $0.totalChunks == current.chunks.count })
    let bytes = try #require(try NativeStore(url: storage.profile.database, readOnly: true).snapshot(articleID: item.id))
    let upgraded = try JSONDecoder().decode(StoredExtraction.self, from: bytes).review()
    #expect(upgraded.narration?.version == Narration.version)
    #expect(upgraded.narration?.chunks.first?.text.contains("Source:") == true)
    #expect(upgraded.narration?.chunks.last?.text == "End of article.")
}

@Test func queueBatchCancellationPreservesEarlierGlobalProgressAndLaterWaitingItems() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let first = try await coordinator.enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    let second = try await coordinator.enqueue(reviewedArticle("two"), storage: storage, preferences: SpeechPreferences())
    _ = try await coordinator.enqueue(reviewedArticle("three"), storage: storage, preferences: SpeechPreferences())
    let recorder = BatchProgressRecorder()
    do {
        _ = try await coordinator.runQueuedBatch(storage: storage, backend: { episode in
            if episode.id == second.id { throw CancellationError() }
            return SyntheticSpeechContractBackend("batch")
        }, onArticleComplete: { recorder.complete($0.episode.id) }, onProgress: { recorder.append($0) })
        Issue.record("Cancelled batch completed")
    } catch { #expect(error is CancellationError) }
    let queue = try await coordinator.queue(stateRoot: storage.stateRoot)
    #expect(queue.map(\.state) == [.paused, .queued] && queue.first?.id == second.id)
    #expect(recorder.completedIDs == [first.id])
    let last = try #require(recorder.values.last)
    #expect(last.completedArticles == 1 && last.totalArticles == 3 && last.fractionCompleted < 1)
    #expect(last.completedChunks > 0 && last.completedChunks < last.totalChunks)
}

@Test func queueLegacyCompletionIsReverifiedAndMissingAudioKeepsItemUntilRecovery() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator(), review = try reviewedArticle()
    var item = try await coordinator.enqueue(review, storage: storage, preferences: SpeechPreferences())
    // A published episode alone is insufficient: this crash leaves local feed publication unfinished.
    do {
        _ = try await coordinator.runReviewed(root: storage.stateRoot, review: review,
            backend: SyntheticSpeechContractBackend("queued"), interruptAfter: .episodeCommitted, storage: storage)
        Issue.record("Expected publication interruption")
    } catch { #expect(error as? RelayError == .interrupted) }
    item.state = .completed // Simulate a row retained by the previous app.
    do { try NativeStore(url: storage.profile.database).saveQueueItem(item) }
    let media = audio.appendingPathComponent(item.id + ".m4a"), backup = root.appendingPathComponent("backup.m4a")
    try FileManager.default.moveItem(at: media, to: backup)
    do {
        _ = try await coordinator.runNextQueued(storage: storage, backend: { _ in throw RelayError.artifact("Synthetic regeneration failure") })
        Issue.record("Expected regeneration failure")
    } catch { #expect(error is RelayError) }
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).first?.state == .failed)
    #expect(try { () throws -> Stage? in
        let store = try NativeStore(url: storage.profile.database, readOnly: true)
        return try store.episodes().first(where: { $0.id == item.id })?.stage
    }() == .expired)
    #expect(try await coordinator.savedAudio(storage: storage).isEmpty)
    _ = try await coordinator.retryQueued(item.id, stateRoot: storage.stateRoot)
    let result = try #require(try await coordinator.runNextQueued(storage: storage, backend: { _ in SyntheticSpeechContractBackend("regenerated") }))
    #expect(result.synthesizedChunks > 0 && result.episode.id == item.id && result.localFeedCurrent)
    #expect(FileManager.default.fileExists(atPath: media.path))
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    let feed = String(decoding: try Data(contentsOf: storage.profile.feed), as: UTF8.self)
    #expect(feed.contains(item.id + ".m4a"))
    #expect(FileManager.default.fileExists(atPath: backup.path))
}

@Test(arguments: [Stage.encoding, .published])
func queueCancellationBeforeSuccessAcknowledgementRetainsItem(_ stage: Stage) async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let item = try await coordinator.enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    let operation = Task {
        try await coordinator.runQueued(item.id, storage: storage, backend: { _ in SyntheticSpeechContractBackend("queued") },
            onProgress: { update in if update.stage == stage { withUnsafeCurrentTask { $0?.cancel() } } })
    }
    if stage == .published {
        let result = try await operation.value
        #expect(result.episode.id == item.id)
        #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
        #expect(try await coordinator.library(storage: storage).first?.stage == .published)
        return
    }
    do { _ = try await operation.value; Issue.record("Cancelled item removed") }
    catch { #expect(error is CancellationError) }
    let retained = try #require(await coordinator.queue(stateRoot: storage.stateRoot).first)
    #expect(retained.id == item.id && retained.state == .paused)
    _ = try await coordinator.retryQueued(item.id, stateRoot: storage.stateRoot)
    let result = try await coordinator.runQueued(item.id, storage: storage, backend: { _ in SyntheticSpeechContractBackend("queued") })
    #expect(result.localFeedCurrent && result.episode.id == item.id)
    if stage == .published { #expect(result.synthesizedChunks == 0) }
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
}

@Test func agentContractRejectsVersionSizeAndInvalidCommandsWithoutCreatingStorage() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let state = root.appendingPathComponent("never-created")
    let endpoint = AgentEndpoint(stateRoot: state)
    let invalid: [(Data, AgentFailure)] = [
        (Data("not-json PRIVATE_SOURCE".utf8), .invalidRequest),
        (Data(repeating: 65, count: AgentWire.maximumBytes + 1), .payloadTooLarge),
        (try JSONEncoder().encode(AgentRequest(command: .snapshot, version: 99)), .unsupportedVersion),
        (try JSONEncoder().encode(AgentRequest(command: .enqueue(entryIDs: []))), .invalidRequest),
        (try JSONEncoder().encode(AgentRequest(command: .enqueue(entryIDs: ["same", "same"]))), .invalidRequest),
        (try JSONEncoder().encode(AgentRequest(command: .retry(articleID: "not-a-uuid"))), .invalidRequest)
    ]
    for (data, expected) in invalid {
        let raw = await endpoint.handle(data)
        let response = try AgentWire.decodeResponse(raw, requestID: UUID())
        #expect(response.failure == expected && response.snapshot == nil)
        #expect(!String(decoding: raw, as: UTF8.self).contains("PRIVATE_SOURCE"))
    }
    #expect(!FileManager.default.fileExists(atPath: state.path))
}

@Test func agentSnapshotIsReadOnlyAndMutatingContractCommandsAreUnavailable() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let state = root.appendingPathComponent("state"), endpoint = AgentEndpoint(stateRoot: state)
    let request = AgentRequest(command: .snapshot)
    let empty = try AgentWire.decodeResponse(await endpoint.handle(AgentWire.encode(request)), requestID: request.requestID)
    #expect(empty.snapshot?.articles == 0 && empty.snapshot?.supportedCommands == ["snapshot"] && empty.snapshot?.mode == "readOnlyFoundation")
    #expect(!FileManager.default.fileExists(atPath: state.path))
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"), stateRoot: state, temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator(), review = try reviewedArticle()
    let entry = ReadingListEntry(id: "private-entry", safariID: nil, url: review.page.originalURL, title: "PRIVATE TITLE", addedAt: nil)
    _ = try await coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0), stateRoot: state)
    let item = try await coordinator.enqueue(review, storage: storage, preferences: SpeechPreferences(), sourceEntryID: entry.id)
    let hash = try Files.hash(storage.profile.database)
    let raw = await endpoint.handle(try AgentWire.encode(request))
    let populated = try AgentWire.decodeResponse(raw, requestID: request.requestID)
    #expect(populated.snapshot?.articles == 1 && populated.snapshot?.waiting == 1)
    #expect(!String(decoding: raw, as: UTF8.self).contains("articles.example") && !String(decoding: raw, as: UTF8.self).contains("PRIVATE TITLE"))
    for command: AgentCommand in [.reconcile, .enqueue(entryIDs: [entry.id]), .generateAudio, .pause,
                                  .setExcluded(entryID: entry.id, excluded: true), .retry(articleID: item.id), .removeFromQueue(articleID: item.id)] {
        let mutation = AgentRequest(command: command)
        let response = try AgentWire.decodeResponse(await endpoint.handle(AgentWire.encode(mutation)), requestID: mutation.requestID)
        #expect(response.failure == .commandUnavailable && response.requestID == mutation.requestID)
    }
    #expect(try Files.hash(storage.profile.database) == hash)
    #expect(try await coordinator.queue(stateRoot: state).first == item)
    #expect(!FileManager.default.fileExists(atPath: storage.audioDirectory.path) && !FileManager.default.fileExists(atPath: storage.temporaryRoot.path))
}

@Test func agentContractRefusesForeignStorageAndUncorrelatedOrAmbiguousResponses() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let state = root.appendingPathComponent("state"), database = PrototypeProfile.fixture(at: state).database
    try Files.directory(database.deletingLastPathComponent())
    try Files.write(Data("foreign PRIVATE STATE".utf8), to: database)
    let before = try Files.hash(database), request = AgentRequest(command: .snapshot)
    let response = try AgentWire.decodeResponse(await AgentEndpoint(stateRoot: state).handle(AgentWire.encode(request)), requestID: request.requestID)
    #expect(response.failure == .storageUnavailable && response.snapshot == nil)
    #expect(try Files.hash(database) == before)
    #expect(!FileManager.default.fileExists(atPath: database.appendingPathExtension("writer.lock").path))
    let wrong = AgentWire.encodeResponse(AgentResponse(requestID: UUID(), failure: .commandUnavailable))
    #expect(throws: AgentFailure.self) { try AgentWire.decodeResponse(wrong, requestID: request.requestID) }
    let ambiguous = AgentWire.encodeResponse(AgentResponse(requestID: request.requestID))
    #expect(throws: AgentFailure.self) { try AgentWire.decodeResponse(ambiguous, requestID: request.requestID) }
}

@Test func agentPeerRequirementRequiresTrustedMatchingTeamAndFixedIdentities() throws {
    for value in ["", "-", "short", "ABCDEFGHI\" or true", "abcd123456", "ABCDEFGHIé"] {
        #expect(throws: RelayError.self) { try AgentIdentity.peerRequirement(team: value) }
    }
    let app = try AgentIdentity.peerRequirement(team: "ABCD123456")
    #expect(app.contains(AgentIdentity.appIdentifier) && app.contains("anchor apple generic") && app.contains("ABCD123456"))
    #expect(try AgentIdentity.peerRequirement(team: "ABCD123456", agent: true).contains(AgentIdentity.agentIdentifier))
    #expect(AgentIdentity.machService == AgentIdentity.agentIdentifier)
}

@MainActor
private final class FakeAgentTransport: AgentTransport {
    var endpoint: AgentEndpoint?
    var autoReply: Result<Data, AgentClientFailure>?
    var activateError: AgentClientFailure?
    var failAfterSend: AgentClientFailure?
    var activated = false
    var invalidated = false
    var sent: [Data] = []
    private var failureHandler: (@Sendable (AgentClientFailure) -> Void)?
    private var replyHandler: (@Sendable (Result<Data, AgentClientFailure>) -> Void)?
    func activate(onFailure: @escaping @Sendable (AgentClientFailure) -> Void) throws {
        activated = true
        failureHandler = onFailure
        if let activateError { throw activateError }
    }
    func send(_ data: Data, reply: @escaping @Sendable (Result<Data, AgentClientFailure>) -> Void) {
        sent.append(data)
        replyHandler = reply
        if let endpoint { Task { reply(.success(await endpoint.handle(data))) } }
        else if let autoReply { Task { @MainActor in reply(autoReply) } }
        if let failAfterSend {
            let handler = failureHandler
            Task { @MainActor in handler?(failAfterSend) }
        }
    }
    func deliver(_ result: Result<Data, AgentClientFailure>) {
        guard let replyHandler else { return }
        Task { @MainActor in replyHandler(result) }
    }
    func fail(_ failure: AgentClientFailure) { failureHandler?(failure) }
    func invalidate() {
        invalidated = true
        failureHandler?(.invalidated)
    }
}

@Test @MainActor func agentClientSnapshotUsesFreshCorrelatedTransportAndCreatesNoState() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let state = root.appendingPathComponent("never-created")
    let transport = FakeAgentTransport()
    transport.endpoint = AgentEndpoint(stateRoot: state)
    var factoryCalls = 0
    let client = AgentClient { factoryCalls += 1; return transport }
    #expect(factoryCalls == 0)
    let snapshot = try await client.snapshot()
    #expect(factoryCalls == 1 && transport.activated && transport.invalidated)
    let request = try AgentWire.decodeRequest(try #require(transport.sent.first))
    #expect(request.command == .snapshot && request.version == AgentWire.version)
    #expect(snapshot.mode == "readOnlyFoundation" && snapshot.supportedCommands == ["snapshot"])
    #expect(snapshot.articles == 0 && snapshot.progress == nil)
    #expect(!FileManager.default.fileExists(atPath: state.path))
}

@Test @MainActor func agentClientMapsFixedTransportFailuresAndReconnectsExplicitly() async throws {
    var transports: [FakeAgentTransport] = []
    var failures: [AgentClientFailure?] = [.interrupted, .invalidated, nil]
    let client = AgentClient {
        let transport = FakeAgentTransport()
        let failure = failures.isEmpty ? nil : failures.removeFirst()
        transport.failAfterSend = failure
        if failure == nil { transport.autoReply = .failure(.unavailable) }
        transports.append(transport)
        return transport
    }
    do { _ = try await client.snapshot(); Issue.record("Interruption accepted") }
    catch { #expect(error as? AgentClientFailure == .interrupted) }
    do { _ = try await client.snapshot(); Issue.record("Invalidation accepted") }
    catch { #expect(error as? AgentClientFailure == .invalidated) }
    do { _ = try await client.snapshot(); Issue.record("Unavailable reply accepted") }
    catch { #expect(error as? AgentClientFailure == .unavailable) }
    #expect(transports.count == 3 && transports.allSatisfy { $0.activated && $0.invalidated && !$0.sent.isEmpty })
    let refused = FakeAgentTransport(); refused.activateError = .unavailable
    let blocked = AgentClient { refused }
    do { _ = try await blocked.snapshot(); Issue.record("Activation failure accepted") }
    catch { #expect(error as? AgentClientFailure == .unavailable) }
    #expect(refused.invalidated && refused.sent.isEmpty)
    let untrusted = FakeAgentTransport(); untrusted.activateError = .untrustedIdentity
    let refusedIdentity = AgentClient { untrusted }
    do { _ = try await refusedIdentity.snapshot(); Issue.record("Activation failure accepted") }
    catch { #expect(error as? AgentClientFailure == .untrustedIdentity) }
    #expect(untrusted.invalidated && untrusted.sent.isEmpty)
}

@Test @MainActor func agentClientTimesOutAndRejectsInvalidTimeoutsWithoutConnecting() async throws {
    let transport = FakeAgentTransport()
    var calls = 0
    let client = AgentClient { calls += 1; return transport }
    for timeout: Duration in [.zero, .milliseconds(-1), .seconds(31)] {
        do { _ = try await client.snapshot(timeout: timeout); Issue.record("Invalid timeout accepted") }
        catch { #expect(error as? AgentClientFailure == .invalidRequest) }
    }
    #expect(calls == 0 && !transport.activated)
    let started = Date()
    do { _ = try await client.snapshot(timeout: .milliseconds(30)); Issue.record("Missing reply accepted") }
    catch { #expect(error as? AgentClientFailure == .timedOut) }
    #expect(Date().timeIntervalSince(started) < 5)
    #expect(calls == 1 && transport.activated && transport.invalidated && !transport.sent.isEmpty)
}

@Test @MainActor func agentClientRejectsConcurrentRequestsAndIgnoresDuplicateAndStaleCallbacks() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let endpoint = AgentEndpoint(stateRoot: root.appendingPathComponent("state"))
    var transports: [FakeAgentTransport] = []
    let client = AgentClient { let transport = FakeAgentTransport(); transports.append(transport); return transport }
    let first = Task { @MainActor in try await client.snapshot() }
    for _ in 0..<200 {
        if transports.first?.sent.isEmpty == false { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let sent = try #require(transports.first?.sent.first)
    do { _ = try await client.snapshot(); Issue.record("Concurrent request accepted") }
    catch { #expect(error as? AgentClientFailure == .requestInProgress) }
    #expect(transports.count == 1 && !transports[0].invalidated)
    let raw = await endpoint.handle(sent)
    transports[0].deliver(.success(raw))
    let snapshot = try await first.value
    #expect(snapshot.mode == "readOnlyFoundation")
    transports[0].deliver(.success(raw))
    transports[0].fail(.interrupted)
    try await Task.sleep(for: .milliseconds(20))
    let second = Task { @MainActor in try await client.snapshot() }
    for _ in 0..<200 {
        if transports.count > 1 && !transports[1].sent.isEmpty { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let laterTransport = try #require(transports.count > 1 ? transports[1] : nil)
    let later = try #require(laterTransport.sent.first)
    transports[0].deliver(.success(raw))
    transports[0].fail(.invalidated)
    let fresh = await endpoint.handle(later)
    laterTransport.deliver(.success(fresh))
    laterTransport.deliver(.success(fresh))
    let current = try await second.value
    #expect(current.mode == "readOnlyFoundation")
    laterTransport.fail(.interrupted)
    try await Task.sleep(for: .milliseconds(20))
    #expect(transports.count == 2 && laterTransport.invalidated)
}

@Test @MainActor func agentClientCancelsPreCancelledAndInFlightAndIgnoresLateReplies() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let endpoint = AgentEndpoint(stateRoot: root.appendingPathComponent("state"))
    var transports: [FakeAgentTransport] = []
    let client = AgentClient { let transport = FakeAgentTransport(); transports.append(transport); return transport }
    func waitForSent(_ index: Int) async throws -> Data {
        for _ in 0..<200 {
            if transports.count > index && !transports[index].sent.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let transport = try #require(transports.count > index ? transports[index] : nil)
        return try #require(transport.sent.first)
    }
    client.cancel()
    let preCancelled = Task { @MainActor in try await client.snapshot() }
    preCancelled.cancel()
    do { _ = try await preCancelled.value; Issue.record("Pre-cancelled request connected") }
    catch { #expect(error is CancellationError) }
    #expect(transports.isEmpty)
    let inFlight = Task { @MainActor in try await client.snapshot() }
    let sent = try await waitForSent(0)
    inFlight.cancel()
    do { _ = try await inFlight.value; Issue.record("Cancelled request completed") }
    catch { #expect(error is CancellationError) }
    #expect(transports[0].invalidated)
    let afterCancel = Task { @MainActor in try await client.snapshot() }
    let secondSent = try await waitForSent(1)
    transports[0].deliver(.success(await endpoint.handle(sent)))
    transports[0].fail(.invalidated)
    transports[1].deliver(.success(await endpoint.handle(secondSent)))
    #expect(try await afterCancel.value.mode == "readOnlyFoundation")
    #expect(transports[1].invalidated)
    let cancelledAgain = Task { @MainActor in try await client.snapshot() }
    let thirdSent = try await waitForSent(2)
    client.cancel()
    do { _ = try await cancelledAgain.value; Issue.record("Cancelled request completed") }
    catch { #expect(error is CancellationError) }
    #expect(transports[2].invalidated)
    let fresh = Task { @MainActor in try await client.snapshot() }
    let fourthSent = try await waitForSent(3)
    transports[2].deliver(.success(await endpoint.handle(thirdSent)))
    transports[2].fail(.interrupted)
    transports[3].deliver(.success(await endpoint.handle(fourthSent)))
    #expect(try await fresh.value.mode == "readOnlyFoundation")
    #expect(transports[3].invalidated && transports.count == 4)
}

@Test @MainActor func agentClientValidatesCorrelatedResponsesAndPreservesAgentFailures() async throws {
    var transports: [FakeAgentTransport] = []
    let client = AgentClient { let transport = FakeAgentTransport(); transports.append(transport); return transport }
    func exchange(_ raw: (UUID) throws -> Data) async throws -> (any Error)? {
        let index = transports.count
        let attempt = Task { @MainActor in try await client.snapshot() }
        for _ in 0..<200 {
            if transports.count > index && !transports[index].sent.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let transport = try #require(transports.count > index ? transports[index] : nil)
        let sent = try #require(transport.sent.first)
        let request = try AgentWire.decodeRequest(sent)
        transport.deliver(.success(try raw(request.requestID)))
        do { _ = try await attempt.value; return nil }
        catch { #expect(transport.invalidated); return error }
    }
    #expect(try await exchange { _ in Data("not-json".utf8) } as? AgentClientFailure == .invalidResponse)
    #expect(try await exchange { _ in Data(repeating: 65, count: AgentWire.maximumBytes + 1) } as? AgentClientFailure == .invalidResponse)
    #expect(try await exchange { id in try JSONSerialization.data(withJSONObject:
        ["version": 99, "requestID": id.uuidString, "failure": "commandUnavailable"]) } as? AgentClientFailure == .invalidResponse)
    #expect(try await exchange { _ in try JSONSerialization.data(withJSONObject:
        ["version": 1, "requestID": UUID().uuidString, "failure": "commandUnavailable"]) } as? AgentClientFailure == .invalidResponse)
    #expect(try await exchange { _ in try JSONSerialization.data(withJSONObject:
        ["version": 1, "failure": "commandUnavailable"]) } as? AgentClientFailure == .invalidResponse)
    #expect(try await exchange { id in try JSONSerialization.data(withJSONObject:
        ["version": 1, "requestID": id.uuidString]) } as? AgentClientFailure == .invalidResponse)
    let counts: [String: Any] = ["mode": "readOnlyFoundation", "supportedCommands": ["snapshot"],
        "articles": 0, "waiting": 0, "processing": 0, "paused": 0, "failed": 0, "completed": 0]
    #expect(try await exchange { id in try JSONSerialization.data(withJSONObject:
        ["version": 1, "requestID": id.uuidString, "snapshot": counts, "failure": "storageUnavailable"]) }
        as? AgentClientFailure == .invalidResponse)
    #expect(try await exchange { id in
        var snapshot = counts; snapshot["supportedCommands"] = ["snapshot", "pause"]
        return try JSONSerialization.data(withJSONObject: ["version": 1, "requestID": id.uuidString, "snapshot": snapshot])
    } as? AgentClientFailure == .invalidResponse)
    for field in ["articles", "waiting", "processing", "paused", "failed", "completed"] {
        #expect(try await exchange { id in
            var snapshot = counts; snapshot[field] = -1
            return try JSONSerialization.data(withJSONObject: ["version": 1, "requestID": id.uuidString, "snapshot": snapshot])
        } as? AgentClientFailure == .invalidResponse)
    }
    #expect(try await exchange { id in
        var snapshot = counts; snapshot["mode"] = "managedExclusive"
        return try JSONSerialization.data(withJSONObject: ["version": 1, "requestID": id.uuidString, "snapshot": snapshot])
    } as? AgentClientFailure == .invalidResponse)
    let progress = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
        QueueBatchProgress(stage: .encoding, completedChunks: 1, totalChunks: 2, completedArticles: 0, totalArticles: 1)))
    #expect(try await exchange { id in
        var snapshot = counts; snapshot["progress"] = progress
        return try JSONSerialization.data(withJSONObject: ["version": 1, "requestID": id.uuidString, "snapshot": snapshot])
    } as? AgentClientFailure == .invalidResponse)
    #expect(try await exchange { id in AgentWire.encodeResponse(AgentResponse(requestID: id, failure: .storageUnavailable)) }
        as? AgentFailure == .storageUnavailable)
    #expect(try await exchange { id in AgentWire.encodeResponse(AgentResponse(requestID: id, failure: .commandUnavailable)) }
        as? AgentFailure == .commandUnavailable)
    #expect(transports.count == 18)
}

@Test func xcodeProjectAppSourcesUseUniqueBuildFileReferences() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let projectText = String(decoding: try Data(contentsOf:
        root.appendingPathComponent("VoiceRelay.xcodeproj/project.pbxproj")), as: UTF8.self)
    let definitions = try NSRegularExpression(
        pattern: "(?m)^\\s*([A-F0-9]{24})\\s*(?:/\\*[^\\n]*\\*/\\s*)?=\\s*\\{")
    let uuids = definitions.matches(in: projectText, range: NSRange(projectText.startIndex..., in: projectText))
        .compactMap { Range($0.range(at: 1), in: projectText).map { String(projectText[$0]) } }
    #expect(uuids.count == Set(uuids).count)
    let plist = try #require(PropertyListSerialization.propertyList(
        from: Data(projectText.utf8), options: [], format: nil) as? [String: Any])
    let objects = try #require(plist["objects"] as? [String: [String: Any]])
    let target = try #require(objects.values.first {
        $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == "VoiceRelay" })
    var sourcePaths: [String] = []
    for phaseID in try #require(target["buildPhases"] as? [String]) {
        guard let phase = objects[phaseID], phase["isa"] as? String == "PBXSourcesBuildPhase" else { continue }
        for fileID in try #require(phase["files"] as? [String]) {
            let buildFile = try #require(objects[fileID])
            #expect(buildFile["isa"] as? String == "PBXBuildFile")
            let referenceID = try #require(buildFile["fileRef"] as? String)
            let reference = try #require(objects[referenceID])
            #expect(reference["isa"] as? String == "PBXFileReference")
            #expect(reference["lastKnownFileType"] as? String == "sourcecode.swift")
            sourcePaths.append(try #require(reference["path"] as? String))
        }
    }
    let appSources = try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("Sources/VoiceRelayApp").path)
        .filter { $0.hasSuffix(".swift") }.map { "Sources/VoiceRelayApp/\($0)" }
    #expect(sourcePaths.count == appSources.count)
    #expect(Set(sourcePaths) == Set(appSources))
}

@Test func xcodeProjectLoadsOptionalPrivateSigningForBothConfigurations() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let projectData = try Data(contentsOf: root.appendingPathComponent("VoiceRelay.xcodeproj/project.pbxproj"))
    let plist = try #require(PropertyListSerialization.propertyList(
        from: projectData, options: [], format: nil) as? [String: Any])
    let objects = try #require(plist["objects"] as? [String: [String: Any]])
    let projectID = try #require(plist["rootObject"] as? String)
    let project = try #require(objects[projectID])
    let listID = try #require(project["buildConfigurationList"] as? String)
    let list = try #require(objects[listID])
    let configurations = try #require(list["buildConfigurations"] as? [String])
    var names: Set<String> = []
    for configurationID in configurations {
        let configuration = try #require(objects[configurationID])
        names.insert(try #require(configuration["name"] as? String))
        let referenceID = try #require(configuration["baseConfigurationReference"] as? String)
        let reference = try #require(objects[referenceID])
        #expect(reference["path"] as? String == "Packaging/Signing.xcconfig")
    }
    #expect(names == ["Debug", "Release"])
    let signing = try String(contentsOf: root.appendingPathComponent("Packaging/Signing.xcconfig"), encoding: .utf8)
    #expect(signing.split(separator: "\n").filter { !$0.hasPrefix("//") } == ["#include? \"../Signing.local.xcconfig\""])
    // Shared build settings must not acquire a developer's private team identifier.
    for object in objects.values {
        if let settings = object["buildSettings"] as? [String: Any] {
            #expect(settings["DEVELOPMENT_TEAM"] == nil)
        }
    }
}

private final class GateSpeechBackend: TTSBackend, @unchecked Sendable {
    let identity = BackendIdentity(id: "gated-queue-test", displayName: "Gated synthetic speech", isMock: false)
    private let lock = NSLock()
    private var open = false
    private var entered = false
    var synthesizeEntered: Bool { lock.withLock { entered } }
    func openGate() { lock.withLock { open = true } }
    func prepare() throws {}
    func cancel() {}
    func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult {
        lock.withLock { entered = true }
        let deadline = Date().addingTimeInterval(15)
        while !lock.withLock({ open }) && !Task.isCancelled && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        try Task.checkCancellation()
        return try SyntheticAudioBackend().synthesize(request, directory: directory)
    }
}

private final class PendingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int
    init(_ value: Int) { self.value = value }
    func set(_ next: Int) { lock.withLock { value = next } }
    var count: Int { lock.withLock { value } }
}

private func awaitCondition(_ deadline: TimeInterval = 60, _ condition: () -> Bool) async throws -> Bool {
    let end = Date().addingTimeInterval(deadline)
    while Date() < end {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Test func pipelineLeaseBlocksCompetingWorkerAndReleasesDeterministically() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    _ = try await FixtureCoordinator().enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    let first = try PipelineLease(database: storage.profile.database)
    do {
        _ = try PipelineLease(database: storage.profile.database)
        Issue.record("A second worker lease was granted")
    } catch let error as RelayError {
        #expect(error.localizedDescription == "Another speech worker is processing this library.")
    }
    first.release()
    let second = try PipelineLease(database: storage.profile.database)
    second.release()
    let lockFile = storage.profile.database.appendingPathExtension("speech.lock")
    #expect(FileManager.default.fileExists(atPath: lockFile.path))
}

@Test func enqueueCommitsWhileSpeechWorkerIsBlocked() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let first = try await coordinator.enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    let gate = GateSpeechBackend()
    let drain = Task {
        try await coordinator.drainQueue(storage: storage, backend: { _ in gate })
    }
    #expect(try await awaitCondition { gate.synthesizeEntered })
    let second = try await coordinator.enqueue(reviewedArticle("two"), storage: storage, preferences: SpeechPreferences())
    let midQueue = try await FixtureCoordinator().queue(stateRoot: storage.stateRoot)
    #expect(midQueue.map(\.id) == [first.id, second.id])
    #expect(midQueue.first?.state == .running)
    gate.openGate()
    let result = try await drain.value
    #expect(result.progress.completedArticles == 2 && result.failedItems.isEmpty)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
}

@Test func queueDrainWaitsForPendingPreparationsAndProcessesLateCommits() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    _ = try await coordinator.enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    let pending = PendingCounter(1)
    let recorder = BatchProgressRecorder()
    let drain = Task {
        try await coordinator.drainQueue(storage: storage, backend: { _ in SyntheticSpeechContractBackend("drain") },
            pendingPreparationCount: { pending.count }, onProgress: { recorder.append($0) })
    }
    #expect(try await awaitCondition { (try? NativeStore(url: storage.profile.database, readOnly: true).queue().isEmpty) == true })
    let second = try await coordinator.enqueue(reviewedArticle("two"), storage: storage, preferences: SpeechPreferences())
    pending.set(0)
    let result = try await drain.value
    #expect(result.progress.completedArticles == 2 && result.lastResult?.episode.id == second.id)
    #expect(result.failedItems.isEmpty)
    #expect(recorder.values.contains { $0.pendingPreparations > 0 })
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    #expect(try await coordinator.library(storage: storage).allSatisfy { $0.stage == .published })
}

@Test func queueDrainWithOnlyPendingWorkProcessesCommittedArticle() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let pending = PendingCounter(1)
    let recorder = BatchProgressRecorder()
    let drain = Task {
        try await coordinator.drainQueue(storage: storage, backend: { _ in SyntheticSpeechContractBackend("drain") },
            pendingPreparationCount: { pending.count }, onProgress: { recorder.append($0) })
    }
    #expect(try await awaitCondition { recorder.values.contains { $0.pendingPreparations > 0 } })
    let late = try await coordinator.enqueue(reviewedArticle("late"), storage: storage, preferences: SpeechPreferences())
    pending.set(0)
    let result = try await drain.value
    #expect(result.progress.completedArticles == 1 && result.lastResult?.episode.id == late.id)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
}

@Test func queueDrainWaitingForPendingRefusesSecondDrain() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let pending = PendingCounter(1)
    let recorder = BatchProgressRecorder()
    let drain = Task {
        try await coordinator.drainQueue(storage: storage, backend: { _ in SyntheticSpeechContractBackend("drain") },
            pendingPreparationCount: { pending.count }, onProgress: { recorder.append($0) })
    }
    #expect(try await awaitCondition { recorder.values.contains { $0.pendingPreparations > 0 } })
    do {
        _ = try await coordinator.drainQueue(storage: storage, backend: { _ in SyntheticSpeechContractBackend("unused") })
        Issue.record("A second drain ran while the first waited for preparations")
    } catch { #expect(error is RelayError) }
    pending.set(0)
    let result = try await drain.value
    #expect(result.progress.completedArticles == 0 && result.failedItems.isEmpty)
}

@Test func queueDrainContinuesAfterArticleFailureAndReportsFailedItems() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let first = try await coordinator.enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    let second = try await coordinator.enqueue(reviewedArticle("two"), storage: storage, preferences: SpeechPreferences())
    let third = try await coordinator.enqueue(reviewedArticle("three"), storage: storage, preferences: SpeechPreferences())
    let result = try await coordinator.drainQueue(storage: storage, backend: { episode in
        if episode.id == second.id { throw RelayError.artifact("Synthetic second-article failure") }
        return SyntheticSpeechContractBackend("drain")
    })
    #expect(result.progress.completedArticles == 2)
    #expect(result.lastResult?.episode.id == third.id)
    #expect(result.failedItems.map(\.id) == [second.id])
    let queue = try await coordinator.queue(stateRoot: storage.stateRoot)
    #expect(queue.map(\.id) == [second.id] && queue.first?.state == .failed)
    let library = try await coordinator.library(storage: storage)
    #expect(library.first(where: { $0.id == first.id })?.stage == .published)
    #expect(library.first(where: { $0.id == third.id })?.stage == .published)
    #expect(FileManager.default.fileExists(atPath: library.first(where: { $0.id == first.id })!.settings.audio
        .appendingPathComponent(first.id + ".m4a").path))
}

@Test func queueStopAbandonsInterruptedWorkAndRestoresReadyRow() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let first = try await coordinator.enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    let second = try await coordinator.enqueue(reviewedArticle("two"), storage: storage, preferences: SpeechPreferences())
    let gate = GateSpeechBackend(), control = QueueRunControl()
    let drain = Task {
        try await coordinator.drainQueue(storage: storage, backend: { episode -> any TTSBackend in
            episode.id == second.id ? gate : SyntheticSpeechContractBackend("drain")
        }, control: control)
    }
    #expect(try await awaitCondition { gate.synthesizeEntered })
    // The next inference now starts while the first article is finalizing.
    #expect(try await coordinator.library(storage: storage).first(where: { $0.id == first.id })?.stage != .synthesizing)
    control.requestStop()
    drain.cancel()
    do { _ = try await drain.value; Issue.record("Stopped drain completed") }
    catch { #expect(error is CancellationError) }
    let queue = try await coordinator.queue(stateRoot: storage.stateRoot)
    #expect(queue.map(\.id) == [second.id])
    #expect(queue.first?.state == .queued && queue.first?.lastError == nil && queue.first?.attempts == 1)
    let workDirectory = storage.profile.work.appendingPathComponent(second.id)
    #expect(!FileManager.default.fileExists(atPath: workDirectory.path))
    #expect(try NativeStore(url: storage.profile.database, readOnly: true)
        .query("SELECT COUNT(*) FROM chunks WHERE article_id=?", [second.id]).first?.first == "0")
    #expect(try NativeStore(url: storage.profile.database, readOnly: true).snapshot(articleID: second.id) != nil)
    #expect(FileManager.default.fileExists(atPath: audio.appendingPathComponent(first.id + ".m4a").path))
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).first?.state == .queued)
    let rerun = try await coordinator.drainQueue(storage: storage, backend: { _ in SyntheticSpeechContractBackend("drain") })
    #expect(rerun.lastResult?.episode.id == second.id && rerun.failedItems.isEmpty)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
}

@Test func queueDrainRefusesSecondDrainAndParallelWorkerLease() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let item = try await coordinator.enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    let gate = GateSpeechBackend()
    let drain = Task { try await coordinator.drainQueue(storage: storage, backend: { _ in gate }) }
    #expect(try await awaitCondition { gate.synthesizeEntered })
    do {
        _ = try await coordinator.drainQueue(storage: storage, backend: { _ in SyntheticSpeechContractBackend("unused") })
        Issue.record("A second drain ran on the same coordinator")
    } catch { #expect(error is RelayError) }
    do {
        _ = try await FixtureCoordinator().runReviewed(root: storage.stateRoot, review: reviewedArticle("other"),
            backend: SyntheticSpeechContractBackend("unused"), storage: storage)
        Issue.record("A competing worker ran during the drain")
    } catch let error as RelayError {
        #expect(error.localizedDescription == "Another speech worker is processing this library.")
    }
    let extra = try await FixtureCoordinator().enqueue(reviewedArticle("extra"), storage: storage, preferences: SpeechPreferences())
    #expect(extra.id != item.id)
    gate.openGate()
    let result = try await drain.value
    #expect(result.failedItems.isEmpty && result.progress.completedArticles == 2)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
}

@Test func queueBulkRemovalIsAtomicAndPreservesSourceAndMedia() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let first = try await coordinator.enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    let second = try await coordinator.enqueue(reviewedArticle("two"), storage: storage, preferences: SpeechPreferences())
    let third = try await coordinator.enqueue(reviewedArticle("three"), storage: storage, preferences: SpeechPreferences())
    var running = second; running.state = .running; running.attempts = 1
    do { try NativeStore(url: storage.profile.database).saveQueueItem(running) }
    do {
        try await coordinator.removeFromQueue(ids: [second.id, first.id], stateRoot: storage.stateRoot)
        Issue.record("Removal containing the running row was accepted")
    } catch { #expect(error is RelayError) }
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).count == 3)
    try await coordinator.removeFromQueue(ids: [first.id, "missing-id", third.id], stateRoot: storage.stateRoot)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).map(\.id) == [second.id])
    let library = try await coordinator.library(storage: storage)
    #expect(library.map(\.id).sorted() == [first.id, second.id, third.id].sorted())
    #expect(try NativeStore(url: storage.profile.database, readOnly: true).snapshot(articleID: first.id) != nil)
    #expect(try NativeStore(url: storage.profile.database, readOnly: true).snapshot(articleID: third.id) != nil)
}

@Test func abandonedWorkPreservesPublishedMediaAndRejectsUnsafeRoots() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let item = try await coordinator.enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    let published = try await coordinator.resume(storage: storage, articleID: item.id, backend: SyntheticSpeechContractBackend("drain"))
    let audioBytes = try Data(contentsOf: published.audioURL)
    try await coordinator.abandonInterruptedWork(episodeID: item.id, storage: storage)
    #expect(try Data(contentsOf: published.audioURL) == audioBytes)
    #expect(try await coordinator.library(storage: storage).first?.stage == .published)
    let second = try await coordinator.enqueue(reviewedArticle("two"), storage: storage, preferences: SpeechPreferences())
    var working = try #require(await coordinator.library(storage: storage).first(where: { $0.id == second.id }))
    working.stage = .synthesizing; working.encodedHash = "placeholder"
    do { try NativeStore(url: storage.profile.database).save(working) }
    let work = storage.profile.work.appendingPathComponent(second.id)
    try Files.directory(work); try Files.write(Data("partial".utf8), to: work.appendingPathComponent("partial.bin"))
    try await coordinator.abandonInterruptedWork(episodeID: second.id, storage: storage)
    let cleaned = try #require(await coordinator.library(storage: storage).first(where: { $0.id == second.id }))
    #expect(cleaned.stage == .extracted && cleaned.encodedHash == nil)
    #expect(!FileManager.default.fileExists(atPath: work.path))
    #expect(try NativeStore(url: storage.profile.database, readOnly: true).snapshot(articleID: second.id) != nil)
    let outside = try temporary(); defer { try? FileManager.default.removeItem(at: outside) }
    let third = try await coordinator.enqueue(reviewedArticle("three"), storage: storage, preferences: SpeechPreferences())
    var linked = try #require(await coordinator.library(storage: storage).first(where: { $0.id == third.id }))
    linked.stage = .synthesizing
    do { try NativeStore(url: storage.profile.database).save(linked) }
    let linkedWork = storage.profile.work.appendingPathComponent(third.id)
    try FileManager.default.createSymbolicLink(at: linkedWork, withDestinationURL: outside)
    do {
        try await coordinator.abandonInterruptedWork(episodeID: third.id, storage: storage)
        Issue.record("Linked work directory was cleaned")
    } catch { #expect(error is RelayError) }
    #expect(FileManager.default.fileExists(atPath: outside.path))
    #expect(FileManager.default.fileExists(atPath: linkedWork.path))
}

private final class FirstChunkGateBackend: TTSBackend, @unchecked Sendable {
    let identity = BackendIdentity(id: "first-chunk-gate", displayName: "Gated synthetic chunk", isMock: false)
    private let lock = NSLock()
    private var calls = 0
    var blockedOnSecond: Bool { lock.withLock { calls >= 2 } }
    func prepare() throws {}
    func cancel() {}
    func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult {
        let call = lock.withLock { calls += 1; return calls }
        if call > 1 {
            let deadline = Date().addingTimeInterval(15)
            while !Task.isCancelled && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            try Task.checkCancellation()
        }
        return try SyntheticAudioBackend().synthesize(request, directory: directory)
    }
}

private final class SecondChunkFailBackend: TTSBackend, @unchecked Sendable {
    let identity = BackendIdentity(id: "second-chunk-fail", displayName: "Failing synthetic chunk", isMock: false)
    private let lock = NSLock()
    private var calls = 0
    func prepare() throws {}
    func cancel() {}
    func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult {
        let call = lock.withLock { calls += 1; return calls }
        if call > 1 { throw RelayError.artifact("Synthetic mid-run backend failure") }
        return try SyntheticAudioBackend().synthesize(request, directory: directory)
    }
}

private final class ArtifactOnCancelBackend: TTSBackend, @unchecked Sendable {
    let identity = BackendIdentity(id: "artifact-on-cancel", displayName: "Cancelling synthetic", isMock: false)
    private let lock = NSLock()
    private var entered = false
    var synthesizeEntered: Bool { lock.withLock { entered } }
    func prepare() throws {}
    func cancel() {}
    func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult {
        lock.withLock { entered = true }
        let deadline = Date().addingTimeInterval(15)
        while !Task.isCancelled && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        if Task.isCancelled { throw RelayError.artifact("Synthetic cancellation unwind failure") }
        return try SyntheticAudioBackend().synthesize(request, directory: directory)
    }
}

@Test func pipelineStoreInitWaitsOutBriefWriterContention() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    _ = try await FixtureCoordinator().enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    var holder: NativeStore? = try NativeStore(url: storage.profile.database)
    let created = Task { try PipelineStore(databaseURL: storage.profile.database) }
    usleep(150_000)
    _ = holder
    holder = nil
    _ = try await created.value
}

@Test func queueBatchProgressDecodesMissingPendingPreparations() throws {
    let legacy = Data("{\"stage\":\"SYNTHESIZING\",\"completedChunks\":2,\"totalChunks\":5,\"completedArticles\":1,\"totalArticles\":3,\"currentArticleIndex\":2}".utf8)
    let decoded = try JSONDecoder().decode(QueueBatchProgress.self, from: legacy)
    #expect(decoded.pendingPreparations == 0 && decoded.currentArticleIndex == 2)
    let roundtrip = try JSONDecoder().decode(QueueBatchProgress.self, from: JSONEncoder().encode(
        QueueBatchProgress(stage: .synthesizing, completedChunks: 2, totalChunks: 5,
                           completedArticles: 1, totalArticles: 3, currentArticleIndex: 2, pendingPreparations: 4)))
    #expect(roundtrip.pendingPreparations == 4 && roundtrip.currentArticleIndex == 2)
}

@Test func cancelledAdmissionRollsBackCommitAndLeavesNoRows() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let control = QueueAdmissionControl()
    await coordinator.setBeforeEnqueueCommit({ control.cancel() })
    do {
        _ = try await coordinator.enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences(),
                                          admissionControl: control)
        Issue.record("Cancelled admission committed")
    } catch { #expect(error is CancellationError) }
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    #expect(try await coordinator.library(storage: storage).isEmpty)
    #expect(try NativeStore(url: storage.profile.database, readOnly: true)
        .query("SELECT COUNT(*) FROM snapshots").first?.first == "0")
    await coordinator.setBeforeEnqueueCommit(nil)
    _ = try await coordinator.enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).count == 1)
}

@Test func admissionReceiptRemovalIsExactAndRefusesRunningRow() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let controlA = QueueAdmissionControl()
    let item = try await coordinator.enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences(),
                                             admissionControl: controlA)
    #expect(item.admissionID == controlA.id)
    #expect(try await coordinator.cancelAdmission(controlA.id, stateRoot: storage.stateRoot)?.id == item.id)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
    #expect(try await coordinator.library(storage: storage).count == 1)
    let controlB = QueueAdmissionControl()
    let again = try await coordinator.enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences(),
                                              admissionControl: controlB)
    #expect(again.admissionID == controlB.id)
    #expect(try await coordinator.cancelAdmission(controlA.id, stateRoot: storage.stateRoot) == nil)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).map(\.id) == [again.id])
    let controlC = QueueAdmissionControl()
    let duplicate = try await coordinator.enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences(),
                                                  admissionControl: controlC)
    #expect(duplicate.id == again.id && duplicate.admissionID == controlB.id)
    #expect(try await coordinator.cancelAdmission(controlC.id, stateRoot: storage.stateRoot) == nil)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).map(\.id) == [again.id])
    var running = again; running.state = .running
    do { try NativeStore(url: storage.profile.database).saveQueueItem(running) }
    do {
        _ = try await coordinator.cancelAdmission(controlB.id, stateRoot: storage.stateRoot)
        Issue.record("Running admission row was removed")
    } catch let error as RelayError {
        #expect(error.localizedDescription.contains("began processing"))
    }
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).first?.state == .running)
}

@Test func abandonInterruptedWorkRefusesHeldWorkerLease() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let item = try await coordinator.enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    var episode = try #require(await coordinator.library(storage: storage).first(where: { $0.id == item.id }))
    episode.stage = .synthesizing; episode.encodedHash = "placeholder"
    do { try NativeStore(url: storage.profile.database).save(episode) }
    let work = storage.profile.work.appendingPathComponent(item.id)
    try Files.directory(work); try Files.write(Data("partial".utf8), to: work.appendingPathComponent("partial.bin"))
    let lease = try PipelineLease(database: storage.profile.database)
    defer { lease.release() }
    do {
        try await coordinator.abandonInterruptedWork(episodeID: item.id, storage: storage)
        Issue.record("Cleanup ran while another worker held the lease")
    } catch let error as RelayError {
        #expect(error.localizedDescription == "Another speech worker is processing this library.")
    }
    #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent("partial.bin").path))
    #expect(try await coordinator.library(storage: storage).first?.stage == .synthesizing)
}

@Test func abandonInterruptedWorkRefusesLinkedWorkRoot() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let item = try await coordinator.enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    var episode = try #require(await coordinator.library(storage: storage).first(where: { $0.id == item.id }))
    episode.stage = .synthesizing
    do { try NativeStore(url: storage.profile.database).save(episode) }
    let sibling = storage.temporaryRoot.appendingPathComponent("sibling-\(UUID().uuidString)")
    let nested = sibling.appendingPathComponent(item.id)
    try Files.directory(nested)
    if FileManager.default.fileExists(atPath: storage.profile.work.path) {
        try FileManager.default.removeItem(at: storage.profile.work)
    }
    try FileManager.default.createSymbolicLink(at: storage.profile.work, withDestinationURL: sibling)
    do {
        try await coordinator.abandonInterruptedWork(episodeID: item.id, storage: storage)
        Issue.record("Linked work root was cleaned")
    } catch { #expect(error is RelayError) }
    #expect(FileManager.default.fileExists(atPath: nested.path))
    #expect(try await coordinator.library(storage: storage).first?.stage == .synthesizing)
}

@Test func abandonInterruptedWorkPreservesStagedPublicationBoundary() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    do {
        _ = try await coordinator.runReviewed(root: storage.stateRoot, review: reviewedArticle(),
            backend: SyntheticSpeechContractBackend("boundary"), interruptAfter: .audioPlaced, storage: storage)
        Issue.record("Interrupted boundary run completed")
    } catch let error as RelayError { #expect(error == .interrupted) }
    let episode = try #require(await coordinator.library(storage: storage).first)
    let destination = audio.appendingPathComponent(episode.id + ".m4a")
    let bytes = try Data(contentsOf: destination)
    try await coordinator.abandonInterruptedWork(episodeID: episode.id, storage: storage)
    #expect(try Data(contentsOf: destination) == bytes)
    let kept = try #require(await coordinator.library(storage: storage).first)
    #expect(kept.stage == .encoded && kept.encodedHash != nil && kept.publicationDate != nil)
    #expect(FileManager.default.fileExists(atPath: storage.profile.work.appendingPathComponent(episode.id).path))
}

@Test func queueStopAfterFirstCheckpointDiscardsOnlyOwnedWork() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let review = try reviewedArticle("two")
    let chunks = try #require(review.narration?.chunks.count)
    #expect(chunks >= 2)
    let first = try await coordinator.enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    let second = try await coordinator.enqueue(review, storage: storage, preferences: SpeechPreferences())
    let gate = FirstChunkGateBackend(), control = QueueRunControl()
    let drain = Task {
        try await coordinator.drainQueue(storage: storage, backend: { episode -> any TTSBackend in
            episode.id == second.id ? gate : SyntheticSpeechContractBackend("drain")
        }, control: control)
    }
    #expect(try await awaitCondition { gate.blockedOnSecond })
    // Validation/checkpoint of chunk 1 now overlaps synthesis of chunk 2.
    #expect(try await awaitCondition {
        (try? NativeStore(url: storage.profile.database, readOnly: true)
            .query("SELECT COUNT(*) FROM chunks WHERE article_id=?", [second.id]).first?.first) == "1"
    })
    let sibling = storage.profile.work.appendingPathComponent("unrelated.txt")
    try Files.write(Data("unrelated".utf8), to: sibling)
    control.requestStop()
    drain.cancel()
    do { _ = try await drain.value; Issue.record("Stopped drain completed") }
    catch { #expect(error is CancellationError) }
    let queue = try await coordinator.queue(stateRoot: storage.stateRoot)
    #expect(queue.map(\.id) == [second.id] && queue.first?.state == .queued && queue.first?.lastError == nil)
    #expect(try NativeStore(url: storage.profile.database, readOnly: true)
        .query("SELECT COUNT(*) FROM chunks WHERE article_id=?", [second.id]).first?.first == "0")
    #expect(!FileManager.default.fileExists(atPath: storage.profile.work.appendingPathComponent(second.id).path))
    #expect(FileManager.default.fileExists(atPath: sibling.path))
    #expect(FileManager.default.fileExists(atPath: audio.appendingPathComponent(first.id + ".m4a").path))
    #expect(FileManager.default.fileExists(atPath: storage.profile.feed.path))
    #expect(try NativeStore(url: storage.profile.database, readOnly: true).snapshot(articleID: second.id) != nil)
}

@Test func queueStopWithArtifactErrorStillAbandonsAndRestoresReady() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let item = try await coordinator.enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    let backend = ArtifactOnCancelBackend(), control = QueueRunControl()
    let drain = Task {
        try await coordinator.drainQueue(storage: storage, backend: { _ in backend }, control: control)
    }
    #expect(try await awaitCondition { backend.synthesizeEntered })
    control.requestStop()
    drain.cancel()
    do { _ = try await drain.value; Issue.record("Stopped drain completed") }
    catch { #expect(error is CancellationError) }
    let queue = try await coordinator.queue(stateRoot: storage.stateRoot)
    #expect(queue.first?.id == item.id && queue.first?.state == .queued && queue.first?.lastError == nil)
    #expect(!FileManager.default.fileExists(atPath: storage.profile.work.appendingPathComponent(item.id).path))
}

@Test func queueFailureAfterFirstCheckpointRetainsRowAndContinues() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let review = try reviewedArticle("two")
    #expect(try #require(review.narration?.chunks.count) >= 2)
    let first = try await coordinator.enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    let second = try await coordinator.enqueue(review, storage: storage, preferences: SpeechPreferences())
    let third = try await coordinator.enqueue(reviewedArticle("three"), storage: storage, preferences: SpeechPreferences())
    let failing = SecondChunkFailBackend()
    let result = try await coordinator.drainQueue(storage: storage, backend: { episode -> any TTSBackend in
        episode.id == second.id ? failing : SyntheticSpeechContractBackend("drain")
    })
    #expect(result.progress.completedArticles == 2 && result.lastResult?.episode.id == third.id)
    #expect(result.failedItems.map(\.id) == [second.id])
    let queue = try await coordinator.queue(stateRoot: storage.stateRoot)
    #expect(queue.map(\.id) == [second.id] && queue.first?.state == .failed)
    #expect(try NativeStore(url: storage.profile.database, readOnly: true)
        .query("SELECT COUNT(*) FROM chunks WHERE article_id=?", [second.id]).first?.first == "1")
    #expect(try await coordinator.library(storage: storage).first(where: { $0.id == first.id })?.stage == .published)
    #expect(try await coordinator.library(storage: storage).first(where: { $0.id == third.id })?.stage == .published)
}

@Test func abandonInterruptedWorkRefusesInaccessibleWork() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let coordinator = FixtureCoordinator()
    let item = try await coordinator.enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    var episode = try #require(await coordinator.library(storage: storage).first(where: { $0.id == item.id }))
    episode.stage = .synthesizing; episode.encodedHash = "placeholder"
    do { try NativeStore(url: storage.profile.database).save(episode) }
    do {
        try NativeStore(url: storage.profile.database)
            .execute("INSERT INTO chunks VALUES(?,?,?,?)", [item.id, "0", "fingerprint", "{}"])
    }
    let work = storage.profile.work.appendingPathComponent(item.id)
    try Files.directory(work); try Files.write(Data("partial".utf8), to: work.appendingPathComponent("partial.bin"))
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: storage.profile.work.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storage.profile.work.path) }
    do {
        try await coordinator.abandonInterruptedWork(episodeID: item.id, storage: storage)
        Issue.record("Inaccessible work storage was cleaned")
    } catch let error as RelayError {
        #expect(error.localizedDescription == "Unfinished working files are inaccessible. Restore temporary-storage access before discarding them; saved article text is preserved.")
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storage.profile.work.path)
    #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent("partial.bin").path))
    let kept = try #require(await coordinator.library(storage: storage).first(where: { $0.id == item.id }))
    #expect(kept.stage == .synthesizing && kept.encodedHash == "placeholder")
    #expect(try NativeStore(url: storage.profile.database, readOnly: true)
        .query("SELECT COUNT(*) FROM chunks WHERE article_id=?", [item.id]).first?.first == "1")
}

private func awaitSemaphore(_ sem: DispatchSemaphore, timeout: DispatchTime) -> Bool {
    sem.wait(timeout: timeout) == .success
}

private final class SharedReaderGate: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var failed: String?
    var failure: String? { lock.withLock { failed } }
    func markFailure(_ value: String) {
        lock.withLock { failed = value }
        ready.signal(); done.signal()
    }
}

private func holdSharedReader(_ database: URL, gate: SharedReaderGate) {
    var raw: OpaquePointer?
    guard sqlite3_open_v2(database.path, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let raw else {
        gate.markFailure("reader-open-failed")
        return
    }
    var code = sqlite3_exec(raw, "BEGIN", nil, nil, nil)
    if code == SQLITE_OK { code = sqlite3_exec(raw, "SELECT record FROM episodes LIMIT 1", nil, nil, nil) }
    guard code == SQLITE_OK else {
        sqlite3_exec(raw, "ROLLBACK", nil, nil, nil)
        sqlite3_close(raw)
        gate.markFailure("reader-lock-failed")
        return
    }
    gate.ready.signal()
    _ = gate.release.wait(timeout: .now() + 15)
    sqlite3_exec(raw, "ROLLBACK", nil, nil, nil)
    sqlite3_close(raw)
    gate.done.signal()
}

@Test func sqliteCommitWaitsForConcurrentReader() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let item = try await FixtureCoordinator().enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    let database = storage.profile.database
    let gate = SharedReaderGate()
    Thread { holdSharedReader(database, gate: gate) }.start()
    defer {
        gate.release.signal()
        _ = awaitSemaphore(gate.done, timeout: .now() + 15)
    }
    #expect(awaitSemaphore(gate.ready, timeout: .now() + 10) && gate.failure == nil)
    Thread { usleep(150_000); gate.release.signal() }.start()
    var writer: NativeStore? = try NativeStore(url: database)
    try writer?.saveQueueItem(item)
    writer = nil
}

@Test func sqliteCommitProbeReportsBusyCode() throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("probe.sqlite")
    var setup: OpaquePointer?
    #expect(sqlite3_open_v2(database.path, &setup, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
    #expect(sqlite3_exec(setup, "CREATE TABLE episodes(id TEXT PRIMARY KEY, record TEXT NOT NULL)", nil, nil, nil) == SQLITE_OK)
    #expect(sqlite3_exec(setup, "INSERT INTO episodes VALUES('probe','{}')", nil, nil, nil) == SQLITE_OK)
    #expect(sqlite3_exec(setup, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(setup)
    let gate = SharedReaderGate()
    Thread { holdSharedReader(database, gate: gate) }.start()
    defer {
        gate.release.signal()
        _ = awaitSemaphore(gate.done, timeout: .now() + 15)
    }
    #expect(awaitSemaphore(gate.ready, timeout: .now() + 10) && gate.failure == nil)
    var raw: OpaquePointer?
    #expect(sqlite3_open_v2(database.path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
    let rc = sqlite3_exec(raw, "BEGIN IMMEDIATE; UPDATE episodes SET record=record; COMMIT;", nil, nil, nil)
    let extended = sqlite3_extended_errcode(raw)
    FileHandle.standardError.write(Data("sqlite-probe rc=\(rc) extended=\(extended)\n".utf8))
    sqlite3_close(raw)
    gate.release.signal()
    #expect(rc != SQLITE_OK && extended != SQLITE_OK)
}

private func rawExec(_ db: OpaquePointer?, _ sql: String) -> Bool {
    sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
}

private func seedLegacyDatabase(_ database: URL, version: Int, foreign: Bool = false) throws {
    var raw: OpaquePointer?
    try #require(sqlite3_open_v2(database.path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
    defer { sqlite3_close(raw) }
    if foreign {
        try #require(rawExec(raw, "CREATE TABLE legacy(id INTEGER)"))
        return
    }
    try #require(rawExec(raw, "CREATE TABLE episodes(id TEXT PRIMARY KEY, source_key TEXT NOT NULL UNIQUE, record TEXT NOT NULL)"))
    try #require(rawExec(raw, "CREATE TABLE chunks(article_id TEXT NOT NULL REFERENCES episodes(id), chunk_index INTEGER NOT NULL, fingerprint TEXT NOT NULL, checkpoint TEXT NOT NULL, PRIMARY KEY(article_id,chunk_index))"))
    try #require(rawExec(raw, "CREATE TABLE feed_status(singleton INTEGER PRIMARY KEY CHECK(singleton=1), pending INTEGER NOT NULL, local_hash TEXT)"))
    try #require(rawExec(raw, "INSERT INTO feed_status VALUES(1,1,NULL)"))
    if version >= 2 {
        try #require(rawExec(raw, "CREATE TABLE snapshots(article_id TEXT PRIMARY KEY REFERENCES episodes(id), record TEXT NOT NULL, hash TEXT NOT NULL)"))
    }
    try #require(rawExec(raw, "PRAGMA application_id=\(NativeStore.applicationID)"))
    try #require(rawExec(raw, "PRAGMA user_version=\(version)"))
}

@Test func readOnlyNativeStoreReadsEmptyLibraryAfterInitializationCloses() throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("library.sqlite")
    do { _ = try NativeStore(url: database) }
    #expect(FileManager.default.fileExists(atPath: database.path + "-wal"))
    #expect(FileManager.default.fileExists(atPath: database.path + "-shm"))
    let reader = try NativeStore(url: database, readOnly: true)
    #expect(try reader.catalog().entries.isEmpty)
    #expect(try reader.queue().isEmpty)
    #expect(try reader.episodes().isEmpty)
}

@Test func readOnlyNativeStoreReadsAfterLastWriterClosed() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let database = storage.profile.database
    do {
        _ = try await FixtureCoordinator().enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    }
    let reader = try NativeStore(url: database, readOnly: true)
    #expect(try reader.query("SELECT COUNT(*) FROM episodes").first?.first == "1")
    #expect(try reader.queue().count == 1)
}

@Test func readOnlyNativeStoreRefusesWrites() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let item = try await FixtureCoordinator().enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    let reader = try NativeStore(url: storage.profile.database, readOnly: true)
    do {
        try reader.execute("INSERT INTO episodes VALUES('x','k','{}')")
        Issue.record("A read-only library connection committed a write")
    } catch { #expect(error is RelayError) }
    #expect(try reader.queue().map(\.id) == [item.id])
}

@Test func nativeVersionTwoUpgradePreservesWAL() throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("state/library.sqlite")
    try Files.directory(database.deletingLastPathComponent())
    try seedLegacyDatabase(database, version: 2)
    var writer: NativeStore? = try NativeStore(url: database)
    #expect(try writer?.query("PRAGMA user_version").first?.first == "3")
    #expect(try writer?.query("PRAGMA journal_mode").first?.first?.lowercased() == "wal")
    writer = nil
    let reader = try NativeStore(url: database, readOnly: true)
    #expect(try reader.queue().isEmpty)
    #expect(try reader.query("PRAGMA journal_mode").first?.first?.lowercased() == "wal")
}

@Test func foreignOrNewerDatabaseIsRefusedWithoutWALSidecar() throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let foreign = root.appendingPathComponent("foreign.sqlite")
    try seedLegacyDatabase(foreign, version: 0, foreign: true)
    do {
        _ = try NativeStore(url: foreign)
        Issue.record("Foreign database was adopted")
    } catch { #expect(error is RelayError) }
    #expect(!FileManager.default.fileExists(atPath: foreign.path + "-wal"))
    #expect(!FileManager.default.fileExists(atPath: foreign.path + "-shm"))
    let newer = root.appendingPathComponent("newer.sqlite")
    try seedLegacyDatabase(newer, version: 2)
    var raw: OpaquePointer?
    try #require(sqlite3_open_v2(newer.path, &raw, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
    try #require(rawExec(raw, "PRAGMA user_version=99"))
    sqlite3_close(raw)
    do {
        _ = try NativeStore(url: newer)
        Issue.record("Newer schema was adopted")
    } catch { #expect(error is RelayError) }
    #expect(!FileManager.default.fileExists(atPath: newer.path + "-wal"))
    #expect(!FileManager.default.fileExists(atPath: newer.path + "-shm"))
}

private func removalStorage() throws -> (URL, ManagedSpeechStorage) {
    let root = try temporary()
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    return (root, ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"),
                                       temporaryRoot: root.appendingPathComponent("scratch")))
}
private func publishedEpisode(_ tag: String, storage: ManagedSpeechStorage) async throws -> FixtureResult {
    try await FixtureCoordinator().runReviewed(root: storage.stateRoot, review: reviewedArticle(tag),
        backend: SyntheticSpeechContractBackend("removal"), storage: storage)
}

@Test func sqliteFailureReportsCodesWithoutContent() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"),
                                       temporaryRoot: root.appendingPathComponent("scratch"))
    _ = try await FixtureCoordinator().enqueue(reviewedArticle(), storage: storage, preferences: SpeechPreferences())
    let reader = try NativeStore(url: storage.profile.database, readOnly: true)
    do {
        try reader.execute("INSERT INTO episodes VALUES('x','k','{}')")
        Issue.record("A read-only library connection committed a write")
    } catch let error as RelayError {
        let message = error.localizedDescription
        #expect(message.contains("Native SQLite write failed (SQLite"))
        #expect(message.contains("Saved progress is retained"))
        #expect(!message.contains("INSERT") && !message.contains(root.path))
    }
}

@Test func articlePreviewURLResolvesSavedSnapshot() async throws {
    let (root, storage) = try removalStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let review = try reviewedArticle("preview")
    let result = try await coordinator.runReviewed(root: storage.stateRoot, review: review,
        backend: SyntheticSpeechContractBackend("preview"), storage: storage)
    let url = try await coordinator.articlePreviewURL(articleID: result.episode.id, stateRoot: storage.stateRoot)
    #expect(url == review.page.originalURL)
    let queuedReview = try reviewedArticle("queued")
    let item = try await coordinator.enqueue(queuedReview, storage: storage, preferences: SpeechPreferences())
    #expect(item.sourceEntryID == nil)
    #expect(try await coordinator.articlePreviewURL(articleID: item.id, stateRoot: storage.stateRoot)
        == URL(string: "https://articles.example/queued"))
}

@Test func articlePreviewURLRefusesMissingCorruptOrForeignState() async throws {
    let (root, storage) = try removalStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let result = try await publishedEpisode("kept", storage: storage)
    do {
        _ = try await coordinator.articlePreviewURL(articleID: UUID().uuidString.lowercased(), stateRoot: storage.stateRoot)
        Issue.record("A missing snapshot resolved a preview URL")
    } catch { #expect(error is RelayError) }
    let store = try NativeStore(url: storage.profile.database)
    try store.execute("UPDATE snapshots SET record=? WHERE article_id=?", [Data([0xFF]).base64EncodedString(), result.episode.id])
    do {
        _ = try await coordinator.articlePreviewURL(articleID: result.episode.id, stateRoot: storage.stateRoot)
        Issue.record("A corrupt snapshot resolved a preview URL")
    } catch { #expect(error is RelayError) }
    let foreign = try temporary(); defer { try? FileManager.default.removeItem(at: foreign) }
    do {
        _ = try await coordinator.articlePreviewURL(articleID: result.episode.id, stateRoot: foreign)
        Issue.record("A foreign library resolved a preview URL")
    } catch { #expect(error is RelayError) }
}

@Test func removeSavedAudioDeletesFileAndRetiresFeed() async throws {
    let (root, storage) = try removalStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let first = try await publishedEpisode("one", storage: storage)
    let second = try await publishedEpisode("two", storage: storage)
    let third = try await publishedEpisode("three", storage: storage)
    let queued = try await coordinator.enqueue(try reviewedArticle("queued-source"), storage: storage, preferences: SpeechPreferences())
    let removed = try await coordinator.removeSavedAudio(ids: [second.episode.id], storage: storage)
    #expect(removed == [second.episode.id])
    #expect(!FileManager.default.fileExists(atPath: second.audioURL.path))
    #expect(FileManager.default.fileExists(atPath: first.audioURL.path))
    #expect(FileManager.default.fileExists(atPath: third.audioURL.path))
    let feed = String(decoding: try Data(contentsOf: storage.profile.feed), as: UTF8.self)
    #expect(feed.contains(first.episode.id) && feed.contains(third.episode.id))
    #expect(!feed.contains(second.episode.id))
    let library = try await coordinator.library(storage: storage)
    let retired = try #require(library.first { $0.id == second.episode.id })
    #expect(retired.stage == .expired && retired.manualAudioDeletionRequested != true)
    #expect(try await coordinator.savedAudio(storage: storage).map(\.id).sorted() == [first.episode.id, third.episode.id].sorted())
    let reader = try NativeStore(url: storage.profile.database, readOnly: true)
    #expect(try reader.snapshot(articleID: second.episode.id) != nil)
    #expect(try await coordinator.queue(stateRoot: storage.stateRoot).map(\.id) == [queued.id])
}

@Test func removeSavedAudioBulkDeletesOnlyTargetedFiles() async throws {
    let (root, storage) = try removalStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    var results: [FixtureResult] = []
    for tag in ["a", "b", "c"] { results.append(try await publishedEpisode(tag, storage: storage)) }
    let ids = results.map { $0.episode.id }
    let removed = try await coordinator.removeSavedAudio(ids: [ids[0], ids[2]], storage: storage)
    #expect(Set(removed) == [ids[0], ids[2]])
    #expect(!FileManager.default.fileExists(atPath: results[0].audioURL.path))
    #expect(FileManager.default.fileExists(atPath: results[1].audioURL.path))
    #expect(!FileManager.default.fileExists(atPath: results[2].audioURL.path))
}

@Test func removeSavedAudioCapturedResetLeavesNewerFilesUntouched() async throws {
    let (root, storage) = try removalStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    var shown: [FixtureResult] = []
    for tag in ["a", "b", "c"] { shown.append(try await publishedEpisode(tag, storage: storage)) }
    let captured = shown.map { $0.episode.id }
    let newer = try await publishedEpisode("newer", storage: storage)
    _ = try await coordinator.removeSavedAudio(ids: captured, storage: storage)
    #expect(shown.allSatisfy { !FileManager.default.fileExists(atPath: $0.audioURL.path) })
    #expect(FileManager.default.fileExists(atPath: newer.audioURL.path))
    #expect(try await coordinator.savedAudio(storage: storage).map(\.id) == [newer.episode.id])
    #expect(String(decoding: try Data(contentsOf: storage.profile.feed), as: UTF8.self).contains(newer.episode.id))
}

@Test func removeSavedAudioRetainsDurableIntentAcrossFeedFailure() async throws {
    let (root, storage) = try removalStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let result = try await publishedEpisode("one", storage: storage)
    let feed = storage.profile.feed
    try FileManager.default.removeItem(at: feed)
    try Files.directory(feed)
    defer { try? FileManager.default.removeItem(at: feed) }
    do {
        _ = try await coordinator.removeSavedAudio(ids: [result.episode.id], storage: storage)
        Issue.record("Removal proceeded despite a blocked feed write")
    } catch { #expect(error is RelayError) }
    #expect(FileManager.default.fileExists(atPath: result.audioURL.path))
    let flagged = try #require(try await coordinator.library(storage: storage).first)
    #expect(flagged.stage == .expired && flagged.manualAudioDeletionRequested == true)
    #expect(try await coordinator.savedAudio(storage: storage).map(\.id) == [result.episode.id])
    try FileManager.default.removeItem(at: feed)
    let finished = try await coordinator.resumePendingAudioRemovals(storage: storage)
    #expect(finished == [result.episode.id])
    #expect(!FileManager.default.fileExists(atPath: result.audioURL.path))
    let settled = try #require(try await coordinator.library(storage: storage).first)
    #expect(settled.stage == .expired && settled.manualAudioDeletionRequested != true)
    #expect(try await coordinator.savedAudio(storage: storage).isEmpty)
}

@Test func removeSavedAudioUnlinkFailureKeepsRowVisibleAndRetries() async throws {
    guard geteuid() != 0 else { return }
    let (root, storage) = try removalStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let result = try await publishedEpisode("one", storage: storage)
    let folder = result.episode.settings.audio
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
    do {
        _ = try await coordinator.removeSavedAudio(ids: [result.episode.id], storage: storage)
        Issue.record("Removal proceeded despite a refused unlink")
    } catch { #expect(error is RelayError) }
    #expect(FileManager.default.fileExists(atPath: result.audioURL.path))
    let flagged = try #require(try await coordinator.library(storage: storage).first)
    #expect(flagged.stage == .expired && flagged.manualAudioDeletionRequested == true)
    #expect(try await coordinator.savedAudio(storage: storage).map(\.id) == [result.episode.id])
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
    _ = try await coordinator.resumePendingAudioRemovals(storage: storage)
    #expect(!FileManager.default.fileExists(atPath: result.audioURL.path))
}

@Test func removeSavedAudioReconcileDoesNotResurrectIntent() async throws {
    let (root, storage) = try removalStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let result = try await publishedEpisode("one", storage: storage)
    var flagged = result.episode
    flagged.stage = .expired; flagged.manualAudioDeletionRequested = true
    try NativeStore(url: storage.profile.database).save(flagged)
    let episode = try #require(try await coordinator.library(storage: storage).first)
    #expect(episode.stage == .expired && episode.manualAudioDeletionRequested == true)
    #expect(FileManager.default.fileExists(atPath: result.audioURL.path))
}

@Test func removeSavedAudioRetiresConfirmedMissingWithoutFilesystem() async throws {
    let (root, storage) = try removalStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let result = try await publishedEpisode("one", storage: storage)
    try FileManager.default.removeItem(at: result.audioURL)
    let removed = try await coordinator.removeSavedAudio(ids: [result.episode.id], storage: storage)
    #expect(removed == [result.episode.id])
    let episode = try #require(try await coordinator.library(storage: storage).first)
    #expect(episode.stage == .expired && episode.manualAudioDeletionRequested != true)
    #expect(!String(decoding: try Data(contentsOf: storage.profile.feed), as: UTF8.self).contains(result.episode.id))
}

@Test func removeSavedAudioRefusesUnavailableOrSubstitutedFiles() async throws {
    let (root, storage) = try removalStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let result = try await publishedEpisode("one", storage: storage)
    var foreign = result.episode
    foreign.audioVolumeID = "00000000-0000-0000-0000-000000000000"
    try NativeStore(url: storage.profile.database).save(foreign)
    do {
        _ = try await coordinator.removeSavedAudio(ids: [result.episode.id], storage: storage)
        Issue.record("Removal proceeded on an unavailable volume")
    } catch { #expect(error is RelayError) }
    var restored = result.episode; restored.audioVolumeID = nil
    try NativeStore(url: storage.profile.database).save(restored)
    try Files.write(Data("substituted".utf8), to: result.audioURL)
    do {
        _ = try await coordinator.removeSavedAudio(ids: [result.episode.id], storage: storage)
        Issue.record("Removal deleted a substituted file")
    } catch { #expect(error is RelayError) }
    let episode = try #require(try await coordinator.library(storage: storage).first)
    #expect(episode.stage == .published && episode.manualAudioDeletionRequested != true)
    #expect(String(decoding: try Data(contentsOf: result.audioURL), as: UTF8.self) == "substituted")
}

@Test func removeSavedAudioRefusesForeignLibraryAndCompetingWorker() async throws {
    let (root, storage) = try removalStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let result = try await publishedEpisode("one", storage: storage)
    let lease = try PipelineLease(database: storage.profile.database)
    do {
        _ = try await coordinator.removeSavedAudio(ids: [result.episode.id], storage: storage)
        Issue.record("Removal proceeded while a speech worker held the library")
    } catch { #expect(error is RelayError) }
    lease.release()
    #expect(FileManager.default.fileExists(atPath: result.audioURL.path))
    let foreign = try temporary(); defer { try? FileManager.default.removeItem(at: foreign) }
    try Files.directory(foreign)
    try Files.write(Data(ManagedSpeechStorage.markerText.utf8), to: foreign.appendingPathComponent(".voicerelay-library"))
    let foreignDB = foreign.appendingPathComponent("library.sqlite")
    try seedLegacyDatabase(foreignDB, version: 0, foreign: true)
    let foreignStorage = ManagedSpeechStorage(audioDirectory: storage.audioDirectory, stateRoot: foreign,
                                              temporaryRoot: storage.temporaryRoot)
    do {
        _ = try await coordinator.removeSavedAudio(ids: [result.episode.id], storage: foreignStorage)
        Issue.record("Removal proceeded on a foreign library")
    } catch { #expect(error is RelayError) }
    #expect(!FileManager.default.fileExists(atPath: foreignDB.path + "-wal"))
}

@Test func removeSavedAudioEmptySelectionIsNoop() async throws {
    let (root, storage) = try removalStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    #expect(try await coordinator.removeSavedAudio(ids: [], storage: storage) == [])
    #expect(!FileManager.default.fileExists(atPath: storage.stateRoot.path))
    do {
        _ = try await coordinator.removeSavedAudio(ids: ["missing"], storage: storage)
        Issue.record("Removal on a missing library returned success")
    } catch { #expect(error is RelayError) }
}

@Test func resumeRefusesUntilPendingRemovalResolves() async throws {
    let (root, storage) = try removalStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let result = try await publishedEpisode("regen", storage: storage)
    try FileManager.default.removeItem(at: result.audioURL)
    var flagged = result.episode
    flagged.stage = .expired
    flagged.manualAudioDeletionRequested = true
    try { () throws in
        let store = try NativeStore(url: storage.profile.database)
        try store.save(flagged)
    }()
    do {
        _ = try await coordinator.resume(storage: storage, articleID: flagged.id, backend: SyntheticSpeechContractBackend("regen"))
        Issue.record("Regeneration ran while a removal was still pending")
    } catch {
        #expect((error as? RelayError)?.localizedDescription
            == "Saved audio removal is unfinished. Reopen Saved Audio to finish it before regenerating.")
    }
    #expect(!FileManager.default.fileExists(atPath: result.audioURL.path))
    #expect(try await coordinator.resumePendingAudioRemovals(storage: storage) == [flagged.id])
    _ = try await coordinator.resume(storage: storage, articleID: flagged.id, backend: SyntheticSpeechContractBackend("regen"))
    #expect(FileManager.default.fileExists(atPath: result.audioURL.path))
    #expect(FileManager.default.fileExists(atPath: result.audioURL.path))
    #expect(try await coordinator.library(storage: storage).first?.stage == .published)
}

@Test func pendingRemovalResolverRefusesNonExpiredFlaggedRecord() async throws {
    let (root, storage) = try removalStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let result = try await publishedEpisode("flagged", storage: storage)
    let before = try Files.hash(result.audioURL)
    var flagged = result.episode
    flagged.manualAudioDeletionRequested = true
    try { () throws in
        let store = try NativeStore(url: storage.profile.database)
        try store.save(flagged)
    }()
    do {
        _ = try await coordinator.resumePendingAudioRemovals(storage: storage)
        Issue.record("The resolver mutated a flagged published record")
    } catch { #expect(error is RelayError) }
    #expect(try Files.hash(result.audioURL) == before)
    let episode = try await coordinator.library(storage: storage).first!
    #expect(episode.stage == .published && episode.manualAudioDeletionRequested == true)
    #expect(try String(contentsOf: result.feedURL, encoding: .utf8).contains(result.episode.id))
}

@Test func removeSavedAudioRefusesInPlaceEditBeforeUnlink() async throws {
    let (root, storage) = try removalStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let result = try await publishedEpisode("raced", storage: storage)
    await coordinator.setBeforeOwnedAudioUnlink { url in
        guard url == result.audioURL else { return }
        let handle = try? FileHandle(forWritingTo: url)
        try? handle?.write(contentsOf: Data(repeating: 0x2A, count: 4))
        try? handle?.close()
    }
    do {
        _ = try await coordinator.removeSavedAudio(ids: [result.episode.id], storage: storage)
        Issue.record("Removal deleted an in-place-modified file")
    } catch {
        #expect((error as? RelayError)?.localizedDescription.contains("changed during removal") == true)
    }
    await coordinator.setBeforeOwnedAudioUnlink(nil)
    #expect(FileManager.default.fileExists(atPath: result.audioURL.path))
    #expect(try await coordinator.savedAudio(storage: storage).map(\.id) == [result.episode.id])
    do {
        _ = try await coordinator.removeSavedAudio(ids: [result.episode.id], storage: storage)
        Issue.record("Removal deleted a file whose hash no longer matched")
    } catch { #expect(error is RelayError) }
    #expect(FileManager.default.fileExists(atPath: result.audioURL.path))
    let episode = try await coordinator.library(storage: storage).first!
    #expect(episode.stage == .expired && episode.manualAudioDeletionRequested == true)
}

@Test func pendingRemovalResolverReReadsUnderLease() async throws {
    let (root, storage) = try removalStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let result = try await publishedEpisode("stale", storage: storage)
    var flagged = result.episode
    flagged.stage = .expired
    flagged.manualAudioDeletionRequested = true
    try { () throws in
        let store = try NativeStore(url: storage.profile.database)
        try store.save(flagged)
    }()
    let regenerated = { () -> Episode in
        var e = flagged
        e.stage = .published
        e.manualAudioDeletionRequested = false
        return e
    }()
    let bytesBefore = try Files.hash(result.audioURL)
    let feedBefore = try String(contentsOf: result.feedURL, encoding: .utf8)
    await coordinator.setBeforeAudioRemovalLease {
        if let store = try? NativeStore(url: storage.profile.database) { try? store.save(regenerated) }
    }
    #expect(try await coordinator.resumePendingAudioRemovals(storage: storage) == [])
    await coordinator.setBeforeAudioRemovalLease(nil)
    #expect(try Files.hash(result.audioURL) == bytesBefore)
    #expect(try String(contentsOf: result.feedURL, encoding: .utf8) == feedBefore)
    let episode = try await coordinator.library(storage: storage).first!
    #expect(episode.stage == .published && episode.manualAudioDeletionRequested == false)
}

@Test func removeSavedAudioDerivesFromFreshLeasedSnapshot() async throws {
    let (root, storage) = try removalStorage(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let result = try await publishedEpisode("fresh", storage: storage)
    let published = result.episode
    await coordinator.setBeforeAudioRemovalLease {
        let url = result.audioURL
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.write(contentsOf: Data(repeating: 0x33, count: 8))
            try? handle.close()
        }
        var e = published
        e.audioHash = try? Files.hash(url)
        if let store = try? NativeStore(url: storage.profile.database) { try? store.save(e) }
    }
    #expect(try await coordinator.removeSavedAudio(ids: [result.episode.id], storage: storage) == [result.episode.id])
    await coordinator.setBeforeAudioRemovalLease(nil)
    #expect(!FileManager.default.fileExists(atPath: result.audioURL.path))
    let episode = try await coordinator.library(storage: storage).first!
    #expect(episode.stage == .expired && episode.manualAudioDeletionRequested == false)
}

@Test func sqliteErrorReportsBindingFailureCode() throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let writer = try NativeStore(url: root.appendingPathComponent("Native.sqlite"))
    do {
        try writer.execute("UPDATE feed_status SET pending=0 WHERE singleton=?", ["1", "2"])
        Issue.record("An out-of-range binding succeeded")
    } catch let error as RelayError {
        #expect(error.localizedDescription.contains("SQLite 25"))
        #expect(!error.localizedDescription.contains("feed_status"))
    }
}
