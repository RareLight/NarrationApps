import Testing
import Foundation
import AVFoundation
import ProcessingPipeline
import NarrationCore
import Pronunciation
@testable import VoiceRelayCore

@Test(.enabled(if: ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"] != nil, "Run with the shared native fixture worker.")) func nativeSpeechAdapterPreparesOnceAndNeverRepacksFinalChunks() throws {
    guard let path = ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"] else {
        throw SkipNativeFixture.unavailable
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try Files.directory(root)
    defer { try? FileManager.default.removeItem(at: root) }
    let trace = root.appendingPathComponent("trace"); try Files.directory(trace)
    let worker = WorkerConfiguration(executable: URL(fileURLWithPath: path), environment: ["NARRATION_FIXTURE_TRACE": trace.path],
                                      inferenceLeaseFile: root.appendingPathComponent("inference.lock"))
    let backend = try NativeMLXBackend(configuration: KokoroConfiguration(projectRoot: root), worker: worker)
    defer { backend.cancel() }
    try backend.prepare(); try backend.prepare()
    let text = String(repeating: "Native narration keeps the original text. ", count: 45)
    let projection = try NarrationPlanner.prepareForSpeech(.init(blocks: [.init(kind: .paragraph, text: text)], extractorVersion: "fixture"), settings: .init(speed: 1))
    let plan = try backend.prepareNarration(projection)
    #expect(!plan.chunks.isEmpty)
    #expect(plan.chunks.allSatisfy { $0.preparedUtterance != nil })
    #expect(plan.chunks.flatMap { $0.text.split(whereSeparator: \.isWhitespace) } == projection.chunks.flatMap { $0.text.split(whereSeparator: \.isWhitespace) })
    var artifacts: [LosslessArtifact] = []
    for chunk in plan.chunks {
        let request = SynthesisRequest(text: chunk.text, language: "en-US", voice: "af_heart", articleID: "synthetic", chunkIndex: chunk.index,
            blockIndices: chunk.blockIndices, settings: ["speed": .integer(1)], preparedUtterance: chunk.preparedUtterance)
        let result = try backend.synthesize(request, directory: root)
        #expect(result.artifacts.count == 1)
        let decoded = try AVAudioFile(forReading: result.artifacts[0].url)
        #expect(decoded.length == 4 && decoded.fileFormat.sampleRate == 24_000)
        artifacts += result.artifacts
    }
    #expect(Set(artifacts.map(\.url)).count == plan.chunks.count)
    backend.cancel()
    let records = try FileManager.default.contentsOfDirectory(at: trace, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "jsonl" }
        .flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n") }
    #expect(records.filter { $0.contains("\"event\":\"launch\"") }.count == 1)
    #expect(records.filter { $0.contains("\"event\":\"initialize\"") }.count == 1)
    #expect(records.filter { $0.contains("\"event\":\"generatePrepared\"") }.count == plan.chunks.count)
    #expect(!records.contains { $0.contains("\"event\":\"generate\"") })
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("models/.native/staging").path).isEmpty)
}

private enum SkipNativeFixture: Error { case unavailable }

@Test func nativeWorkerCopyPhaseDoesNotNestTheAppWrapper() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let project = try Data(contentsOf: root.appendingPathComponent("VoiceRelay.xcodeproj/project.pbxproj"))
    let plist = try #require(PropertyListSerialization.propertyList(from: project, format: nil) as? [String: Any])
    let objects = try #require(plist["objects"] as? [String: [String: Any]])
    let phase = try #require(objects.values.first { $0["isa"] as? String == "PBXCopyFilesBuildPhase" && $0["name"] as? String == "Embed Native Worker" })
    // Destination 1 is already relative to the app wrapper; Contents/Helpers
    // must not include CONTENTS_FOLDER_PATH (which includes VoiceRelay.app).
    if let destination = phase["dstSubfolder"] as? String {
        // Current Xcode writes the symbolic destination; older projects use spec 1.
        #expect(destination == "Wrapper")
    } else {
        #expect(phase["dstSubfolderSpec"] as? String == "1")
    }
    #expect(phase["dstPath"] as? String == "Contents/Helpers")
}

@Test func typographyUsesItsIndependentPackage() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("VoiceRelay.xcodeproj/project.pbxproj"))
    let project = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    let objects = try #require(project["objects"] as? [String: [String: Any]])
    let target = try #require(objects.values.first { $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == "VoiceRelay" })
    let products = try #require(target["packageProductDependencies"] as? [String])
    let typography = try #require(products.compactMap { objects[$0] }.first { $0["productName"] as? String == "AppPresentation" })
    let reference = try #require(typography["package"] as? String)
    #expect(objects[reference]?["relativePath"] as? String == "../swift-packages/AppPresentation")
}


@Test func sharedNarrationSettingsAreLinkedOnlyIntoTheGUI() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("VoiceRelay.xcodeproj/project.pbxproj"))
    let project = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    let objects = try #require(project["objects"] as? [String: [String: Any]])
    for target in objects.values.filter({ $0["isa"] as? String == "PBXNativeTarget" }) {
        let products = (target["packageProductDependencies"] as? [String] ?? []).compactMap { objects[$0]?["productName"] as? String }
        if target["name"] as? String == "VoiceRelay" {
            #expect(products.contains("NarrationUI"))
            #expect(!products.contains("NativeSpeechEngine"))
        } else { #expect(!products.contains("NarrationUI")) }
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"] != nil, "Run with the shared native fixture worker.")) func nativePreparationAndDictionarySurvivePipelineWrapperAndReuseOneHelper() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try Files.directory(root); defer { try? FileManager.default.removeItem(at: root) }
    let trace = root.appendingPathComponent("trace"); try Files.directory(trace)
    let path = try #require(ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"])
    let worker = WorkerConfiguration(executable: URL(fileURLWithPath: path), environment: ["NARRATION_FIXTURE_TRACE": trace.path], inferenceLeaseFile: root.appendingPathComponent("lease"))
    let dictionary = try PronunciationDictionary(entries: [.init(word: "SQLite", spelling: "sequel lite")])
    let pipeline = SingleWorkerSpeechPipeline(database: root.appendingPathComponent("db"), debugLog: nil)
    defer { pipeline.close() }
    var expectedChunks = 0
    for index in 0..<2 {
        let native = try NativeMLXBackend(configuration: KokoroConfiguration(projectRoot: root), worker: worker, pronunciations: dictionary)
        let wrapper = try #require(pipeline.provider(native) as? any PreparedTTSBackend)
        #expect(wrapper.pronunciations.fingerprint == dictionary.fingerprint)
        let projection = try NarrationPlanner.prepareForSpeech(.init(blocks: [.init(kind: .paragraph, text: "SQLite reads this article.")], extractorVersion: "fixture"), settings: wrapper.speechSettings, pronunciations: wrapper.pronunciations)
        let plan = try wrapper.prepareNarration(projection)
        #expect(plan.chunks.map(\.text).joined(separator: " ").contains("sequel lite"))
        expectedChunks += plan.chunks.count
        for chunk in plan.chunks {
            _ = try wrapper.synthesize(.init(text: chunk.text, language: "en-US", voice: "af_heart", articleID: "article-\(index)", chunkIndex: chunk.index,
                blockIndices: chunk.blockIndices, settings: ["speed": .integer(1)], preparedUtterance: chunk.preparedUtterance), directory: root)
        }
    }
    pipeline.close()
    let records = try FileManager.default.contentsOfDirectory(at: trace, includingPropertiesForKeys: nil)
        .flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n") }
        .map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    #expect(records.filter { $0["event"] as? String == "launch" }.count == 1)
    #expect(records.filter { $0["event"] as? String == "generatePrepared" }.count == expectedChunks)
    #expect(records.filter { $0["event"] as? String == "prepareText" }.count == expectedChunks)
    #expect(!records.contains { $0["event"] as? String == "generate" })
}

@Test func audioAssemblyRejectsMixedPoliciesAndPreservesExplicitZero() throws {
    let file = URL(fileURLWithPath: "/tmp/unused-synthetic.wav")
    let legacy = LosslessArtifact(url: file, sampleRate: 24_000, channels: 1, format: "wav")
    let prepared = LosslessArtifact(url: file, sampleRate: 24_000, channels: 1, format: "wav", gapAfterSeconds: 0, assemblyPolicy: NarrationPausePolicy.candidateVersion)
    #expect(try AudioProcessor.scheduledGaps([legacy, legacy]) == nil)
    #expect(try AudioProcessor.scheduledGaps([prepared, prepared]) == [0, 0])
    #expect(throws: RelayError.self) { try AudioProcessor.scheduledGaps([legacy, prepared]) }
}

@Test func nativeSpeechProgressUsesFinalArticleTotalsAndLabelsProvisionalBatchCounts() {
    final class Values: @unchecked Sendable {
        let lock = NSLock(); var values: [QueueBatchProgress] = []
        func append(_ value: QueueBatchProgress) { lock.withLock { values.append(value) } }
    }
    let values = Values()
    let progress = SpeechDrainProgress { values.append($0) }
    progress.observe([("first", 20), ("second", 30)], pending: 0)
    progress.start("first", chunks: 20)
    #expect(values.values.last?.displayFraction == nil)
    progress.update("first", .init(stage: .synthesizing, completedChunks: 1, totalChunks: 8))
    #expect(values.values.last?.countsAreFinal == false)
    #expect(values.values.last?.currentArticleFraction == 1.0 / 9)
    // Later provisional counts cannot change an established acoustic total.
    progress.update("first", .init(stage: .encoding, completedChunks: 8, totalChunks: 20))
    #expect(values.values.last?.totalChunks == 38)
    progress.complete("first", chunks: 8)
    progress.start("second", chunks: 30)
    progress.update("second", .init(stage: .synthesizing, completedChunks: 0, totalChunks: 9))
    #expect(values.values.last?.countsAreFinal == true)
    #expect(values.values.last?.totalChunks == 17)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"] != nil, "Run with shared fixture worker."), arguments: [SpeechPreparationPolicy.legacy, .longformPausesCandidate]) func queuedNativeArticlesPrepareCheckpointAndPublishWithoutRepacking(_ policy: SpeechPreparationPolicy) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try Files.directory(root); defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appendingPathComponent("audio"); try Files.directory(audio)
    let storage = ManagedSpeechStorage(audioDirectory: audio, stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let trace = root.appendingPathComponent("trace"); try Files.directory(trace)
    let worker = WorkerConfiguration(executable: URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"])), environment: ["NARRATION_FIXTURE_TRACE": trace.path], inferenceLeaseFile: root.appendingPathComponent("lease"))
    let dictionary = try PronunciationDictionary(entries: [.init(word: "SQLite", spelling: "sequel lite")])
    let coordinator = FixtureCoordinator()
    for index in 0..<2 {
        let url = URL(string: "https://fixture.example/native-\(index)")!
        let html = "<html><head><title>Native article \(index)</title></head><body><article><h1>Native article \(index)</h1><p>" + String(repeating: "SQLite stores a careful reading of the river and the surrounding countryside. ", count: 12) + "</p></article></body></html>"
        let review = try ReviewedSource.prepare(FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html, contentType: "text/html", encoding: "utf-8", fetchedAt: .distantPast), chunkLimit: 1800)
        _ = try await coordinator.enqueue(review, storage: storage, preferences: SpeechPreferences(voice: .heart, speed: 1.25))
    }
    let result = try await coordinator.drainQueue(storage: storage, backend: { episode in
        try NativeMLXBackend(configuration: KokoroConfiguration(projectRoot: root, voice: episode.settings.voice ?? "af_heart", speed: episode.settings.backendSettings["speed"]?.numericValue ?? 1), worker: worker, pronunciations: dictionary, policy: policy, gapSeconds: episode.settings.gapSeconds)
    })
    #expect(result.failedItems.isEmpty && result.progress.completedArticles == 2)
    let episodes = try await coordinator.library(storage: storage)
    #expect(episodes.count == 2 && episodes.allSatisfy { $0.stage == .published })
    for episode in episodes {
        let database = try NativeStore(url: storage.profile.database, readOnly: true)
        let data = try database.snapshot(articleID: episode.id)
        let snapshot = try #require(data)
        let retained = try JSONDecoder().decode(StoredExtraction.self, from: snapshot)
        let narration = try #require(retained.files["narration.json"])
        let plan = try JSONDecoder().decode(NarrationPlan.self, from: narration)
        #expect(plan.chunks.allSatisfy { $0.preparedUtterance != nil })
        #expect(plan.chunks.contains { $0.text.contains("sequel lite") })
    }
    let records = try FileManager.default.contentsOfDirectory(at: trace, includingPropertiesForKeys: nil)
        .flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n") }
        .map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    #expect(records.filter { $0["event"] as? String == "launch" }.count == 1)
}
