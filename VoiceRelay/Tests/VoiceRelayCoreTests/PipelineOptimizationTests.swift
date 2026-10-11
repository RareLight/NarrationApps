import Foundation
import Testing
@testable import VoiceRelayCore

private func workspace() throws -> (URL, ManagedSpeechStorage) {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("speech-pipeline-test-\(UUID())")
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    return (root, ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch")))
}
private func article(_ index: Int) throws -> ReviewedSource {
    let url = URL(string: "https://fixture.example/\(index)")!
    let bytes = try FixtureResource.html(), html = String(decoding: bytes, as: UTF8.self)
    return try ReviewedSource.prepare(FetchedPage(originalURL: url, finalURL: url, bytes: bytes, html: html,
        contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast), chunkLimit: 1800)
}
private func waitUntil(_ body: () throws -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 10
    while try !body() {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw RelayError.tool("Fixture timed out.") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private func floatWAV(_ samples: [Float], extraChunk: Bool = false) -> Data {
    var payload = Data()
    func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { payload.append(contentsOf: $0) } }
    func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { payload.append(contentsOf: $0) } }
    payload.append(Data("fmt ".utf8)); u32(16); u16(3); u16(1); u32(24000); u32(96000); u16(4); u16(32)
    if extraChunk { payload.append(Data("JUNK".utf8)); u32(3); payload.append(contentsOf: [1,2,3,0]) }
    payload.append(Data("data".utf8)); u32(UInt32(samples.count * 4))
    for sample in samples { u32(sample.bitPattern) }
    var result = Data("RIFF".utf8), length = UInt32(payload.count + 4).littleEndian
    withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
    result.append(Data("WAVE".utf8)); result.append(payload); return result
}
private final class TrackedSpeech: LookaheadTTSBackend, @unchecked Sendable {
    let identity = BackendIdentity(id: "pipeline-controlled-fixture", displayName: "Fixture only", isMock: false)
    private let lock = NSLock()
    private var active = 0
    private var requests: [(String, Int)] = []
    private var maximum = 0, preparations = 0, cancellations = 0, lookaheads = 0
    let blockedArticle: String?
    let pcm16: Bool
    init(blockedArticle: String? = nil, pcm16: Bool = false) { self.blockedArticle = blockedArticle; self.pcm16 = pcm16 }
    var stats: (calls: [(String, Int)], maximum: Int, prepares: Int, cancels: Int, ahead: Int) {
        lock.withLock { (requests, maximum, preparations, cancellations, lookaheads) }
    }
    func prepare() throws { lock.withLock { preparations += 1 } }
    func cancel() { lock.withLock { cancellations += 1 } }
    func synthesize(_ request: SynthesisRequest, directory: URL) throws -> SynthesisResult { try synthesize(request, directory: directory, next: nil) }
    func synthesize(_ request: SynthesisRequest, directory: URL, next: SynthesisRequest?) throws -> SynthesisResult {
        lock.withLock {
            active += 1; maximum = max(maximum, active); requests.append((request.articleID, request.chunkIndex))
            if next != nil { lookaheads += 1 }
        }
        defer { lock.withLock { active -= 1 } }
        if blockedArticle == request.articleID {
            while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
        }
        try Task.checkCancellation()
        let file = directory.appendingPathComponent("segment.wav")
        if pcm16 {
            _ = try ToolRunner.run("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "sine=frequency=330:sample_rate=24000:duration=0.1", "-c:a", "pcm_s16le", file.path], timeout: 5, directory: directory)
        } else {
            try Files.write(floatWAV((0..<2400).map { Float(sin(Double($0) * 0.1) * 0.1) }), to: file)
        }
        return SynthesisResult(artifacts: [LosslessArtifact(url: file, sampleRate: 24000, channels: 1, format: "wav")])
    }
}
private func gatedTool(root: URL, mode: String) throws -> URL {
    let tool = try #require(ToolRunner.locate(mode == "encoding" ? "ffmpeg" : "ffprobe"))
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let python = project.appendingPathComponent(".runtime/kokoro/.venv/bin/python")
    let config = String(decoding: try Files.json(["root": root.path, "tool": tool.path, "mode": mode]), as: UTF8.self)
    let script = """
    #!\(python.path)
    import json, os, pathlib, sys, time
    config = json.loads(\(String(reflecting: config)))
    root = pathlib.Path(config['root'])
    args = sys.argv[1:]
    matched = ('-c:a' in args and args[args.index('-c:a') + 1] == 'aac') if config['mode'] == 'encoding' else args[-1].endswith('.wav')
    if matched:
        with (root/'entered').open('a') as output: output.write(args[-1] + '\\n')
        deadline = time.monotonic() + 15
        while not (root/'release').exists() and time.monotonic() < deadline: time.sleep(0.005)
    os.execv(config['tool'], [config['tool']] + args)
    """
    let url = root.appendingPathComponent("gated-tool")
    try Files.write(Data(script.utf8), to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}
private func useTool(_ tool: URL, mode: String, storage: ManagedSpeechStorage) throws {
    let store = try NativeStore(url: storage.profile.database)
    for var episode in try store.episodes() {
        if mode == "encoding" { episode.settings.ffmpeg = tool.path }
        else { episode.settings.ffprobe = tool.path }
        try store.save(episode)
    }
}
private func entered(_ root: URL) -> [String] {
    ((try? String(contentsOf: root.appendingPathComponent("entered"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}

@Test(arguments: ["complete", "stop", "quit"])
func singleWorkerOverlapsEncodingBoundsWorkAndJoinsCancellation(_ action: String) async throws {
    let (root, storage) = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let first = try await coordinator.enqueue(article(1), storage: storage, preferences: SpeechPreferences())
    let second = try await coordinator.enqueue(article(2), storage: storage, preferences: SpeechPreferences())
    let third = try await coordinator.enqueue(article(3), storage: storage, preferences: SpeechPreferences())
    try useTool(gatedTool(root: root, mode: "encoding"), mode: "encoding", storage: storage)
    let backend = TrackedSpeech(blockedArticle: action == "complete" ? nil : second.id)
    let control = QueueRunControl(), log = DeliveryDebugLog(); log.enabled = true
    let drain = Task { try await coordinator.drainQueue(storage: storage, backend: { _ in backend }, control: control, debugLog: log) }
    defer { drain.cancel(); try? Files.write(Data(), to: root.appendingPathComponent("release")) }
    try await waitUntil { !entered(root).isEmpty && backend.stats.calls.contains { $0.0 == second.id } }
    let queue = try await coordinator.queue(stateRoot: storage.stateRoot)
    #expect(queue.first(where: { $0.id == first.id })?.state == .running)
    #expect(queue.first(where: { $0.id == second.id })?.state == .running)
    #expect(queue.first(where: { $0.id == third.id })?.state == .queued)
    #expect(entered(root).count == 1)
    #expect(backend.stats.maximum == 1 && backend.stats.prepares == 1 && backend.stats.ahead > 0)
    if action == "complete" {
        // A third article remains editable while the two bounded stages are occupied.
        try await waitUntil { log.text.contains("speech finalizer wait: started; ready items 1") }
        try await coordinator.removeFromQueue(third.id, stateRoot: storage.stateRoot)
    } else {
        if action == "stop" { control.requestStop() }
        drain.cancel()
    }
    try Files.write(Data(), to: root.appendingPathComponent("release"))
    if action == "complete" {
        let result = try await drain.value
        #expect(result.progress.completedArticles == 2 && result.lastResult?.episode.id == second.id && result.failedItems.isEmpty)
        #expect(entered(root).count == 2)
        #expect(try await coordinator.queue(stateRoot: storage.stateRoot).isEmpty)
        #expect(log.text.contains("speech timing: queue") && log.text.contains("speech timing: validation"))
        #expect(log.text.split(separator: "\n").contains { $0.contains("speech finalizer wait:") && $0.contains(" ms; ready items 0") })
        #expect(!log.text.contains(first.id) && !log.text.contains(root.path) && !log.text.contains("fixture.example"))
    } else {
        do { _ = try await drain.value; Issue.record("Cancelled drain returned successfully") }
        catch { #expect(error is CancellationError) }
        let remaining = try await coordinator.queue(stateRoot: storage.stateRoot)
        #expect(remaining.first(where: { $0.id == third.id })?.state == .queued)
        if action == "stop" {
            #expect(remaining.map(\.id) == [second.id, third.id])
            #expect(remaining.first?.state == .queued)
            #expect(FileManager.default.fileExists(atPath: storage.profile.audio.appendingPathComponent(first.id + ".m4a").path))
            #expect(!FileManager.default.fileExists(atPath: storage.profile.work.appendingPathComponent(second.id).path))
        } else {
            #expect(remaining.first(where: { $0.id == first.id })?.state == .paused)
            #expect(remaining.first(where: { $0.id == second.id })?.state == .paused)
            #expect(try NativeStore(url: storage.profile.database, readOnly: true)
                .query("SELECT COUNT(*) FROM chunks WHERE article_id=?", [first.id]).first?.first != "0")
        }
    }
    #expect(backend.stats.cancels == 1 && backend.stats.maximum == 1)
    let lease = try PipelineLease(database: storage.profile.database); lease.release()
}

@Test func singleWorkerOverlapsOneChunkValidationWithNextInference() async throws {
    let (root, storage) = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = FixtureCoordinator()
    let first = try await coordinator.enqueue(article(1), storage: storage, preferences: SpeechPreferences())
    try useTool(gatedTool(root: root, mode: "validation"), mode: "validation", storage: storage)
    let backend = TrackedSpeech(pcm16: true)
    let drain = Task { try await coordinator.drainQueue(storage: storage, backend: { _ in backend }) }
    defer { drain.cancel(); try? Files.write(Data(), to: root.appendingPathComponent("release")) }
    try await waitUntil { !entered(root).isEmpty && backend.stats.calls.count >= 2 }
    #expect(entered(root).count == 1 && backend.stats.maximum == 1)
    #expect(try NativeStore(url: storage.profile.database, readOnly: true)
        .query("SELECT COUNT(*) FROM chunks WHERE article_id=?", [first.id]).first?.first == "0")
    try Files.write(Data(), to: root.appendingPathComponent("release"))
    let result = try await drain.value
    #expect(result.progress.completedArticles == 1 && result.failedItems.isEmpty)
}

@Test func floatWaveStreamingPreservesSamplesAndSkipsUnknownPaddedChunks() throws {
    let (root, _) = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let samples: [Float] = [0, -0.01234567, 0.12345678, -0.9, 1.25]
    let file = root.appendingPathComponent("float.wav"), raw = root.appendingPathComponent("raw")
    try Files.write(floatWAV(samples, extraChunk: true), to: file)
    let wave = try #require(try FloatWave.inspect(file)); #expect(wave.info.channels == 1 && wave.info.sampleRate == 24000)
    try Files.write(Data(), to: raw)
    let output = try FileHandle(forWritingTo: raw); try wave.stream(to: output); try output.close()
    let actual = try Data(contentsOf: raw)
    for (index, sample) in samples.enumerated() {
        let word = actual.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)) }
        #expect(word == sample.bitPattern)
    }
    try Files.write(floatWAV([Float.nan]), to: file)
    #expect(throws: RelayError.self) { try FloatWave.inspect(file)?.stream() }
    var truncated = floatWAV(samples); truncated.removeLast()
    try Files.write(truncated, to: file)
    #expect(throws: RelayError.self) { try FloatWave.inspect(file) }
}

@Test func audioInspectionCacheReusesConfirmedBytesAndRejectsChangedBytes() throws {
    let (root, storage) = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("float.wav")
    try Files.write(floatWAV((0..<2400).map { Float(sin(Double($0) * 0.1) * 0.1) }), to: file)
    let tool = root.appendingPathComponent("inspection-tool")
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let python = project.appendingPathComponent(".runtime/kokoro/.venv/bin/python")
    let paths = String(decoding: try Files.json(["ffmpeg": try #require(ToolRunner.locate("ffmpeg")).path,
        "ffprobe": try #require(ToolRunner.locate("ffprobe")).path, "deny": root.appendingPathComponent("deny").path, "calls": root.appendingPathComponent("calls").path]), as: UTF8.self)
    let script = """
    #!\(python.path)
    import json, os, pathlib, sys
    config = json.loads(\(String(reflecting: paths)))
    with pathlib.Path(config['calls']).open('a') as output: output.write(json.dumps(sys.argv[1:]) + '\\n')
    if pathlib.Path(config['deny']).exists(): sys.exit(1)
    tool = config['ffprobe' if '-show_streams' in sys.argv else 'ffmpeg']
    os.execv(tool, [tool] + sys.argv[1:])
    """
    try Files.write(Data(script.utf8), to: tool)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
    var profile = storage.profile; profile.ffmpeg = tool.path; profile.ffprobe = tool.path
    let log = DeliveryDebugLog(); log.enabled = true
    let encoder = AudioProcessor(settings: profile, toolDirectory: root, diagnostics: SpeechDiagnostics(log: log))
    let artifact = LosslessArtifact(url: file, sampleRate: 24000, channels: 1, format: "wav")
    try encoder.validate(SynthesisResult(artifacts: [artifact]), within: root)
    let (encoded, info) = try encoder.encode([artifact], in: root)
    #expect(log.text.contains("speech encoding: audio \(String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), info.duration)) s"))
    #expect(log.text.contains("s per audio minute"))
    #expect(!log.text.contains(root.path) && !log.text.contains("float.wav"))
    let calls = try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8).split(separator: "\n")
    #expect(calls.count <= 3)
    #expect(!calls.contains { $0.contains(file.path) })
    #expect(calls.contains { $0.contains("-show_streams") } && calls.contains { $0.contains("null") })
    try Files.write(Data(), to: root.appendingPathComponent("deny"))
    // After full inspection, tool execution is denied. Only authenticated copies
    // in this article's processor can reuse that inspection.
    let fresh = AudioProcessor(settings: profile, toolDirectory: root)
    #expect(throws: RelayError.self) { try fresh.probe(encoded, final: true) }
    let copy = root.appendingPathComponent("copy.m4a")
    try FileManager.default.copyItem(at: encoded, to: copy)
    #expect(try encoder.probe(copy, final: true).byteLength == info.byteLength)
    try encoder.decode(copy)
    try Files.write(Data("damaged".utf8), to: copy)
    #expect(throws: RelayError.self) { try encoder.probe(copy, final: true) }
    #expect(throws: RelayError.self) { try encoder.decode(copy) }
}

@Test func encodingDiagnosticsReportDurationAndCostWithoutPrivateData() {
    let log = DeliveryDebugLog(), diagnostics = SpeechDiagnostics(log: log)
    diagnostics.recordEncoding(seconds: 14.3, audioDuration: 600)
    #expect(log.text.isEmpty)
    log.enabled = true
    diagnostics.recordEncoding(seconds: 14.3, audioDuration: 600)
    #expect(log.text.contains("speech encoding: audio 600.000 s, encode 14.300 s, 1.430 s per audio minute"))
    for (seconds, duration) in [(Double.nan, 600.0), (Double.infinity, 600.0), (-1.0, 600.0), (1.0, 0.0), (1.0, Double.nan)] {
        diagnostics.recordEncoding(seconds: seconds, audioDuration: duration)
    }
    #expect(log.text.components(separatedBy: "duration unavailable").count == 6)
    #expect(!log.text.contains("nan") && !log.text.contains("inf"))
    log.enabled = false
    let before = log.text
    diagnostics.recordEncoding(seconds: 1, audioDuration: 60)
    #expect(log.text == before)
}

@Test func finalizerDiagnosticsStayOptInAndTolerateUnavailableMetadata() throws {
    let (root, _) = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
    let missing = root.appendingPathComponent("missing.sqlite"), log = DeliveryDebugLog()
    let diagnostics = SpeechDiagnostics(log: log)
    #expect(diagnostics.beginFinalizerWait(database: missing) == nil && log.text.isEmpty)
    log.enabled = true
    let start = diagnostics.beginFinalizerWait(database: missing)
    #expect(start != nil)
    diagnostics.endFinalizerWait(start, database: missing)
    #expect(log.text.contains("speech finalizer wait: started; ready items unknown"))
    #expect(log.text.contains(" ms; ready items unknown"))
    #expect(!log.text.contains(root.path) && !log.text.contains("missing.sqlite"))
    #expect(!FileManager.default.fileExists(atPath: missing.path))
}

@Test func streamedArtifactCopyPreservesBytesPermissionsAndCancellation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-copy-\(UUID())")
    try Files.directory(root); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
    let bytes = Data((0..<(3 * 1024 * 1024)).map { UInt8($0 % 251) })
    try Files.write(bytes, to: source); try Files.copy(source, to: destination)
    #expect(try Files.hash(destination) == Files.hash(bytes))
    #expect((try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let task = Task { try await Task.sleep(for: .seconds(30)); try Files.copy(source, to: destination) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try Files.hash(destination) == Files.hash(bytes))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["destination", "source"])
    let completed = root.appendingPathComponent("completed")
    try Files.moveValidatedScratch(source, to: completed)
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(try Files.hash(completed) == Files.hash(bytes))
    // A failed source read never overwrites the previously committed destination.
    #expect(throws: (any Error).self) { try Files.copy(source, to: destination) }
    #expect(try Files.hash(destination) == Files.hash(bytes))
}
