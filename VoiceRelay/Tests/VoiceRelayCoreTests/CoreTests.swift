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
    #expect(fixture.backendSelector == "mock" && fixture.webdavURL == nil)
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
    #expect(plan.chunks.allSatisfy { $0.text.count <= 50 && !$0.blockIndices.isEmpty })
}

@Test func narrationHasBoundsUnicodeAndLosslessLongTokenFallback() throws {
    let text = "Café 2026 costs $42. " + String(repeating: "界", count: 137)
    let block = ContentBlock(kind: .paragraph, text: text)
    let a = SemanticArticle(title: "Bounded", originalURL: URL(string: "https://example.com")!, finalURL: URL(string: "https://example.com")!, canonicalURL: nil, author: nil, blocks: [block], warnings: [], extractorVersion: "test")
    let plan = try Narration.prepare(a, limit: 30)
    #expect(a.blocks[0].text == text)
    #expect(plan.chunks.allSatisfy { $0.text.count <= 30 && $0.blockIndices == [0] })
    #expect(plan.chunks.map(\.text).joined().filter { $0 == "界" }.count == 137)
    #expect(plan.chunks.map(\.text).joined().contains("Café 2026 costs $42."))
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

@Test func cancellationStopsBeforeFixtureMutation() async throws {
    let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
    let task = Task { try await FixtureCoordinator().run(root: root.appendingPathComponent("fixture")) }
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled work completed") }
    catch { #expect(error is CancellationError) }
}

private struct TwoArtifactBackend: TTSBackend {
    let identity = BackendIdentity(id: "test-two-artifacts-v1", displayName: "Two mock tones", isMock: true)
    func prepare() throws {}
    func cancel() {}
    func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult {
        let one = try MockToneBackend().synthesize(request, directory: directory)
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
private func speechHelper(at root: URL, mode: String = "normal", deadline: Double = 2) throws -> ExecutableSpeechBackend {
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
        prepareTimeout: 2, synthesisTimeout: deadline)
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
        try MockToneBackend().synthesize(request, directory: directory)
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
    #expect(throws: RelayError.self) { try FixtureWorkspace.prepare(root: folder, imported: nil) }
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
