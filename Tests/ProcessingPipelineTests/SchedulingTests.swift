import XCTest
import Pronunciation
import AVFoundation
import Darwin
@testable import NarrationCore
@testable import DocumentProcessing
@testable import NativeSpeech
@testable import AudioOutput
@testable import ProcessingPipeline

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SpeechProgress] = []
    func append(_ value: SpeechProgress) { lock.withLock { values.append(value) } }
    var snapshot: [SpeechProgress] { lock.withLock { values } }
}

private final class TaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Error>?
    func set(_ task: Task<Void, Error>?) { lock.withLock { self.task = task } }
    func cancel() { lock.withLock { task?.cancel() } }
}

private struct ProcessFixture {
    let root: URL
    let output: URL
    let trace: URL
    let worker: URL
    var destination: URL { output.appendingPathComponent("audio.wav") }
    init() throws {
        var macos = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { macos.deleteLastPathComponent() }
        worker = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"] ??
            macos.appendingPathComponent("swift-packages/.build/debug/NarrationFixtureWorker").path)
        guard FileManager.default.isExecutableFile(atPath: worker.path) else {
            throw XCTSkip("Build NarrationFixtureWorker and set NARRATION_FIXTURE_WORKER before process tests.")
        }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Libro scheduling \(UUID().uuidString)")
            .resolvingSymlinksInPath()
        output = root.appendingPathComponent("output")
        trace = root.appendingPathComponent("trace")
        for folder in [output, trace, root.appendingPathComponent("models/.native/staging")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data([42]).write(to: root.appendingPathComponent("models/.native/staging/unrelated"))
    }
    func configuration(_ mode: String = "success", timeout: Duration = .seconds(2)) -> WorkerConfiguration {
        // Raw-chunk transport/fault fixtures deliberately exercise the retained
        // legacy/Soprano API. Accepted-policy coverage below uses the default contract.
        var configuration = WorkerConfiguration(executable: worker, environment: ["NARRATION_FIXTURE_MODE": mode, "NARRATION_FIXTURE_TRACE": trace.path],
                            requestTimeout: timeout, shutdownGrace: 0.05, terminationGrace: 0.05, inferenceLeaseFile: root.appendingPathComponent("inference.lock"))
        configuration.preparationPolicy = .legacy
        return configuration
    }
    func records() throws -> [[String: Any]] {
        try FileManager.default.contentsOfDirectory(at: trace, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }.flatMap { url in
                let bytes = try Data(contentsOf: url)
                var lines = bytes.split(separator: 10)
                if bytes.last != 10, !lines.isEmpty { lines.removeLast() }
                return try lines.map {
                    try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any]
                }
            }
    }
    func input(_ name: String, text: String = "A short public fixture sentence.") throws -> InputDocument {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return .init(source: url, kind: .text, relativePath: name)
    }
    func request(_ inputs: [InputDocument], replaceExisting: Bool = false) throws -> BatchRequest {
        .init(documents: try BatchPlanner.plan(inputs, output: output), outputDirectory: output,
              workspace: root, settings: .init(), replaceExisting: replaceExisting)
    }
    func samples(_ destination: URL? = nil) throws -> [Float] {
        let file = try AVAudioFile(forReading: destination ?? self.destination, commonFormat: .pcmFormatFloat32, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData?[0]), count: Int(file.length)))
    }
    func assertClean(file: StaticString = #filePath, line: UInt = #line) throws {
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("models/.native/staging").path)
        XCTAssertEqual(entries, ["unrelated"], file: file, line: line)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: output.path).contains { $0.hasPrefix(".libro-audio-") }, file: file, line: line)
        for launch in try records().filter({ $0["event"] as? String == "launch" }) {
            let pid = try XCTUnwrap(launch["pid"] as? Int32)
            XCTAssertEqual(kill(pid, 0), -1, "Owned fixture PID was not reaped", file: file, line: line)
            XCTAssertEqual(errno, ESRCH, file: file, line: line)
        }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class PreparationEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [BatchEvent] = []
    func append(_ value: BatchEvent) { lock.withLock { values.append(value) } }
    var snapshot: [BatchEvent] { lock.withLock { values } }
}

@MainActor
final class SchedulingTests: XCTestCase {
    func testConfiguredDictionaryIsAppliedOnceAndSnapshottedForTheWholeBatch() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let store = PronunciationStore(file: fixture.root.appendingPathComponent("pronunciation.json"))
        let saved = try store.save(entries: [.init(word: "SQLite", spelling: "sequel lite"), .init(word: "read", spelling: "reed"), .init(word: "reed", spelling: "red")], expectedRevision: nil)
        var configuration = fixture.configuration()
        configuration.pronunciationStore = store
        configuration.environment["NARRATION_FIXTURE_CAPTURE_TEXT"] = "1"
        let request = try fixture.request([fixture.input("first.txt", text: "SQLite read reed."), fixture.input("second.txt", text: "SQLite read reed.")])
        let firstID = request.documents[0].id
        let result = try await QueueCoordinator(configuration: configuration).run(request) { event in
            if case .document(_, let outcome) = event, outcome.id == firstID {
                _ = try? store.save(entries: [.init(word: "SQLite", spelling: "ess cue ell lite")], expectedRevision: saved.revision)
            }
        }
        XCTAssertEqual(result.successfulCount, 2)
        let texts = try fixture.records().filter { $0["event"] as? String == "generate" }.compactMap { $0["text"] as? String }
        XCTAssertEqual(texts, ["sequel lite reed red.", "sequel lite reed red."])
        XCTAssertEqual(try store.load().dictionary.entries.first?.spelling, "ess cue ell lite")
        XCTAssertEqual(try String(contentsOf: request.documents[0].input.source, encoding: .utf8), "SQLite read reed.")
        try fixture.assertClean()
    }

    func testCorruptDictionaryFailsBeforeStartingAnyWorker() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("pronunciation.json")
        let original = Data("corrupt dictionary".utf8); try original.write(to: file)
        var configuration = fixture.configuration(); configuration.pronunciationStore = .init(file: file)
        let request = try fixture.request([fixture.input("first.txt")])
        let result = try await QueueCoordinator(configuration: configuration).run(request)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertTrue(try fixture.records().isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), original)
        try fixture.assertClean()
    }

    func testPreparationEventsAreOrderedBoundToEachJobAndPrecedeSpeech() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let inputs = try [fixture.input("first.txt"), fixture.input("second.txt")]
        let request = try fixture.request(inputs)
        let events = PreparationEventLog()
        let result = try await QueueCoordinator(configuration: fixture.configuration()).run(request, events: { events.append($0) })
        XCTAssertEqual(result.successfulCount, 2)
        for job in request.documents {
            let values = events.snapshot.compactMap { event -> TextPreparationProgress? in
                if case .textPreparation(let value) = event, value.job == job.id { return value }
                return nil
            }
            XCTAssertFalse(values.isEmpty)
            XCTAssertEqual(values.map(\.sequence), Array(1...values.count))
            XCTAssertTrue(values.allSatisfy { $0.batch == request.id })
            XCTAssertEqual(values.first?.progress.stage, .readingFile)
            XCTAssertEqual(values.last?.progress.stage, .planningNarration)
            let firstSpeech = try XCTUnwrap(events.snapshot.firstIndex { event in
                if case .speech(let value) = event { return value.identity.job == job.id }
                return false
            })
            XCTAssertFalse(events.snapshot.dropFirst(firstSpeech).contains { event in
                if case .textPreparation(let value) = event { return value.job == job.id }
                return false
            })
        }
        try fixture.assertClean()
    }


    func testCoordinatorPublishesSelectedFormatsAndDoesNotRetryEncoderFailure() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let input = try fixture.input("formats.txt")
        var configuration = fixture.configuration()
        if let path = ProcessInfo.processInfo.environment["NARRATION_MP3_LIBRARY"] {
            configuration.mp3Library = URL(fileURLWithPath: path)
        }
        let coordinator = QueueCoordinator(configuration: configuration)
        for format in AudioOutputFormat.allCases where format != .mp3 || configuration.mp3Library != nil {
            let plans = try BatchPlanner.plan([input], output: fixture.output, format: format)
            let request = BatchRequest(documents: plans, outputDirectory: fixture.output, workspace: fixture.root,
                                       settings: .init(), outputFormat: format)
            let summary = try await coordinator.run(request)
            XCTAssertEqual(summary.successfulCount, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: plans[0].destination.path))
            XCTAssertGreaterThan(try AVAudioFile(forReading: plans[0].destination).length, 0)
        }
        var broken = WorkerConfiguration(executable: fixture.worker, environment: ["NARRATION_FIXTURE_TRACE": fixture.trace.path],
                                         mp3Library: fixture.root.appendingPathComponent("missing.dylib"))
        broken.preparationPolicy = .legacy
        let log = ProgressLog()
        let destination = fixture.output.appendingPathComponent("broken.mp3")
        let prior = Data("prior complete output".utf8)
        try prior.write(to: destination)
        do {
            try await ChunkScheduler(configuration: broken).render(chunks: ["One.", "Two.", "Three."],
                batchID: UUID(), jobID: UUID(), workspace: fixture.root, settings: .init(),
                destination: destination, outputFormat: .mp3, progress: { log.append($0) })
            XCTFail("Missing encoder must fail")
        } catch AudioOutputError.encoderUnavailable { }
        XCTAssertEqual(log.snapshot.filter { $0.phase == .started }.count, 1)
        XCTAssertEqual(try Data(contentsOf: destination), prior)
        try fixture.assertClean()
    }
    private func render(_ fixture: ProcessFixture, count: Int, mode: String = "success",
                        log: ProgressLog = ProgressLog(), beforePublication: @escaping @Sendable () throws -> Void = {}) async throws {
        try await ChunkScheduler(configuration: fixture.configuration(mode)).render(
            chunks: (0..<count).map { "Public fixture chunk \($0)." }, batchID: UUID(), jobID: UUID(),
            workspace: fixture.root, settings: .init(), destination: fixture.destination,
            beforePublication: beforePublication, progress: { log.append($0) })
    }

    func testEveryDocumentSizeUsesOneWorkerAndOmitsWhitespace() async throws {
        for count in [2, 3, 5, 25] {
            let fixture = try ProcessFixture(); defer { fixture.remove() }
            let log = ProgressLog()
            try await render(fixture, count: count, log: log)
            XCTAssertEqual(try fixture.records().filter { $0["event"] as? String == "initialize" }.count, 1)
            XCTAssertEqual(log.snapshot.filter { $0.phase == .started }.count, 1)
            XCTAssertEqual(try fixture.samples().count, count * 4)
            try fixture.assertClean()
        }
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        try await ChunkScheduler(configuration: fixture.configuration()).render(chunks: ["One.", "\u{a0}\n", "Two."],
            batchID: UUID(), jobID: UUID(), workspace: fixture.root, settings: .init(), destination: fixture.destination)
        XCTAssertEqual(try fixture.samples().count, 8)
        try fixture.assertClean()
    }

    func testMemoryGuardStopsOwnedWorkersWithoutRetryAndPreservesPriorAudio() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let previous = Data("previous complete audio".utf8)
        try previous.write(to: fixture.destination)
        var configuration = fixture.configuration("prepareStall")
        // Exceed the budget with a normal fixture process, never an actual large allocation.
        configuration.maximumFootprintBytes = 1
        let log = ProgressLog()
        do {
            try await ChunkScheduler(configuration: configuration).render(chunks: ["One.", "Two.", "Three."],
                batchID: UUID(), jobID: UUID(), workspace: fixture.root, settings: .init(),
                destination: fixture.destination, progress: { log.append($0) })
            XCTFail("Expected the worker memory guard")
        } catch let failure as SpeechFailure {
            XCTAssertEqual(failure.code, .memoryLimit)
        }
        XCTAssertEqual(log.snapshot.filter { $0.phase == .started }.count, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), previous)
        try fixture.assertClean()
    }

    func testFootprintReaderAndInvalidMemoryBudget() throws {
        XCTAssertGreaterThan(try XCTUnwrap(SpeechWorkerProcess.physicalFootprint(of: getpid())), 0)
        XCTAssertNil(SpeechWorkerProcess.physicalFootprint(of: -1))
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        var configuration = fixture.configuration()
        configuration.maximumFootprintBytes = 0
        XCTAssertThrowsError(try SpeechWorkerProcess(configuration: configuration,
            identity: .init(batch: UUID(), job: UUID()))) { error in
                XCTAssertEqual((error as? SpeechFailure)?.code, .invalidInput)
            }
        XCTAssertTrue(try fixture.records().isEmpty)
    }

    func testOrderedIncrementalResultsNeverDispatchAheadOfTheCurrentChunk() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let log = ProgressLog()
        try await render(fixture, count: 25, mode: "slowFirst", log: log)
        XCTAssertEqual(try fixture.samples(), (0..<25).flatMap { Array(repeating: Float($0 + 1) / 100, count: 4) })
        let records = try fixture.records()
        let starts = records.filter { $0["event"] as? String == "generate" }.sorted { ($0["time"] as! Double) < ($1["time"] as! Double) }
        let results = records.filter { $0["event"] as? String == "result" }.sorted { ($0["time"] as! Double) < ($1["time"] as! Double) }
        XCTAssertEqual(starts.compactMap { $0["chunk"] as? Int }, Array(0..<25))
        for index in 1..<25 { XCTAssertGreaterThan(starts[index]["time"] as! Double, results[index - 1]["time"] as! Double) }
        XCTAssertEqual(records.filter { $0["event"] as? String == "initialize" }.count, 1)
        XCTAssertEqual(log.snapshot.filter { $0.phase == .chunkWritten }.map(\.completedChunks), Array(1...25))
        try fixture.assertClean()
    }

    func testGenerationFailureIsNotReplayedAndPreservesPreviousAudio() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let previous = Data("previous audio".utf8)
        try previous.write(to: fixture.destination)
        let log = ProgressLog()
        do { try await render(fixture, count: 7, mode: "generationFailure", log: log); XCTFail("Expected generation failure") }
        catch let failure as SpeechFailure { XCTAssertEqual(failure.code, .generation) }
        XCTAssertEqual(log.snapshot.filter { $0.phase == .started }.count, 1)
        let records = try fixture.records()
        XCTAssertEqual(records.filter { $0["event"] as? String == "initialize" }.count, 1)
        XCTAssertEqual(records.filter { $0["event"] as? String == "generate" }.compactMap { $0["chunk"] as? Int }, [0, 1, 2, 3])
        XCTAssertEqual(try Data(contentsOf: fixture.destination), previous)
        try fixture.assertClean()
    }

    func testMalformedControlAndPCMOrCrashNeverReplayAndPreserveOutput() async throws {
        for mode in ["malformed", "oversized", "nan", "shortPCM", "symlinkPCM", "rate", "channels", "frames", "path", "crash"] {
            let fixture = try ProcessFixture(); defer { fixture.remove() }
            let previous = Data("complete prior WAV fixture".utf8)
            try previous.write(to: fixture.destination)
            let log = ProgressLog()
            do { try await render(fixture, count: 4, mode: mode, log: log); XCTFail("Expected \(mode) failure") }
            catch let failure as SpeechFailure { XCTAssertEqual(failure.code, mode == "crash" ? .workerExited : (["malformed", "oversized"].contains(mode) ? .protocolViolation : .generation), mode) }
            XCTAssertEqual(log.snapshot.filter { $0.phase == .started }.count, 1, mode)
            XCTAssertEqual(try Data(contentsOf: fixture.destination), previous, mode)
            try fixture.assertClean()
        }
    }

    func testStorageInvalidInputAndPublicationFailureNeverRetry() async throws {
        for mode in ["storage", "invalidInput", "success"] {
            let fixture = try ProcessFixture(); defer { fixture.remove() }
            let previous = Data("complete previous output".utf8)
            try previous.write(to: fixture.destination)
            let log = ProgressLog()
            do {
                try await render(fixture, count: 4, mode: mode, log: log, beforePublication: {
                    if mode == "success" { throw AudioOutputError.storage }
                })
                XCTFail("Expected \(mode) failure")
            } catch let failure as SpeechFailure { XCTAssertTrue([.storage, .invalidInput].contains(failure.code)) }
            XCTAssertEqual(log.snapshot.filter { $0.phase == .started }.count, 1)
            XCTAssertEqual(try Data(contentsOf: fixture.destination), previous)
            try fixture.assertClean()
        }
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let obstruction = fixture.output.appendingPathComponent("folder")
        try Data([1]).write(to: obstruction)
        do {
            try await ChunkScheduler(configuration: fixture.configuration()).render(chunks: ["One.", "Two.", "Three."],
                batchID: UUID(), jobID: UUID(), workspace: fixture.root, settings: .init(),
                destination: obstruction.appendingPathComponent("audio.wav"))
            XCTFail("Expected storage failure before launch")
        } catch let failure as SpeechFailure { XCTAssertEqual(failure.code, .storage) }
        XCTAssertEqual(try fixture.records().count, 0)
        try fixture.assertClean()
    }

    func testLateEventsAndDiagnosticFloodCannotCorruptOrBlockControl() async throws {
        for mode in ["stale", "flood"] {
            let fixture = try ProcessFixture(); defer { fixture.remove() }
            try await render(fixture, count: 5, mode: mode)
            XCTAssertEqual(try fixture.samples().count, 20)
            try fixture.assertClean()
        }
    }

    func testTimeoutAndForcedCancellationReapUncooperativeWorker() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let previous = Data("previous output".utf8)
        try previous.write(to: fixture.destination)
        let scheduler = ChunkScheduler(configuration: fixture.configuration("stall", timeout: .milliseconds(80)))
        let started = ContinuousClock.now
        do {
            try await scheduler.render(chunks: ["One."], batchID: UUID(), jobID: UUID(), workspace: fixture.root,
                                       settings: .init(), destination: fixture.destination)
            XCTFail("Expected timeout")
        } catch let failure as SpeechFailure { XCTAssertEqual(failure.code, .timeout) }
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        XCTAssertEqual(try Data(contentsOf: fixture.destination), previous)
        try fixture.assertClean()

        let cancelled = try ProcessFixture(); defer { cancelled.remove() }
        try previous.write(to: cancelled.destination)
        let task = Task {
            try await ChunkScheduler(configuration: cancelled.configuration("stall", timeout: .seconds(30))).render(
                chunks: ["One.", "Two.", "Three."], batchID: UUID(), jobID: UUID(), workspace: cancelled.root,
                settings: .init(), destination: cancelled.destination)
        }
        try await waitForRecord(cancelled, name: "generate")
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertEqual(try cancelled.records().filter { $0["event"] as? String == "initialize" }.count, 1)
        XCTAssertEqual(try Data(contentsOf: cancelled.destination), previous)
        try cancelled.assertClean()
    }

    func testCancellationBeforeDispatchAndAtPublicationBoundary() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let previous = Data("old output".utf8)
        try previous.write(to: fixture.destination)
        let log = ProgressLog()
        do {
            try await render(fixture, count: 4, log: log, beforePublication: { throw CancellationError() })
            XCTFail("Expected cancellation at publication")
        } catch is CancellationError {}
        XCTAssertEqual(log.snapshot.filter { $0.phase == .started }.count, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), previous)
        try fixture.assertClean()
        let task = Task {
            try Task.checkCancellation()
            try await self.render(fixture, count: 3)
        }
        task.cancel()
        do { try await task.value; XCTFail("Expected queued cancellation") }
        catch is CancellationError {}
        XCTAssertEqual(try fixture.records().filter { $0["event"] as? String == "launch" }.count, 1)
    }

    func testTaskCancellationAtPublishingEventPreventsAtomicReplacement() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let previous = Data("previous complete output".utf8)
        try previous.write(to: fixture.destination)
        let cancellation = TaskCancellation()
        let log = ProgressLog()
        let task = Task {
            try await ChunkScheduler(configuration: fixture.configuration()).render(
                chunks: ["One.", "Two.", "Three."], batchID: UUID(), jobID: UUID(), workspace: fixture.root,
                settings: .init(), destination: fixture.destination, progress: {
                    log.append($0)
                    if $0.phase == .publishing { cancellation.cancel() }
                })
        }
        cancellation.set(task)
        defer { cancellation.set(nil) }
        do { try await task.value; XCTFail("Expected actual task cancellation at publication") }
        catch is CancellationError {}
        XCTAssertEqual(log.snapshot.filter { $0.phase == .started }.count, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), previous)
        try fixture.assertClean()
    }

    func testSequentialDocumentsContinueAfterInvalidInputAndFinishAfterPublication() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let one = try fixture.input("one.txt", text: String(repeating: "A complete public sentence with useful words. ", count: 12))
        let bad = try fixture.input("bad.txt", text: "  \n")
        let two = try fixture.input("two.txt")
        let request = try fixture.request([one, bad, two])
        let coordinator = QueueCoordinator(configuration: fixture.configuration())
        let summary = try await coordinator.run(request)
        XCTAssertEqual(summary.documents.map(\.state), [.published, .failed, .published])
        XCTAssertEqual(summary.successfulCount, 2)
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertFalse(summary.cancelled)
        for outcome in summary.documents where outcome.state == .published { XCTAssertFalse(try fixture.samples(outcome.destination).isEmpty) }
        let records = try fixture.records()
        let initializations = records.filter { $0["event"] as? String == "initialize" }.sorted { ($0["time"] as! Double) < ($1["time"] as! Double) }
        XCTAssertEqual(initializations.count, 2)
        let firstPID = try XCTUnwrap(initializations.first?["pid"] as? Int)
        let firstExit = try XCTUnwrap(records.first { $0["pid"] as? Int == firstPID && $0["event"] as? String == "exit" }?["time"] as? Double)
        XCTAssertLessThan(firstExit, initializations[1]["time"] as! Double)
        try fixture.assertClean()
    }

    func testCoordinatorBudgetAndCancelWhilePreparingPreserveEarlierOutputs() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let inputs = [try fixture.input("one.txt"), try fixture.input("two.txt")]
        let original = Data("complete earlier output".utf8)
        try original.write(to: fixture.output.appendingPathComponent("one.wav"))
        let request = try fixture.request(inputs, replaceExisting: true)
        let coordinator = QueueCoordinator(configuration: fixture.configuration("prepareStall", timeout: .seconds(30)))
        let task = Task { try await coordinator.run(request) }
        try await waitForRecord(fixture, name: "initialize")
        do { _ = try await coordinator.run(request); XCTFail("Expected global budget rejection") }
        catch is CoordinatorError {}
        await coordinator.cancelAndWait()
        let summary = try await task.value
        XCTAssertTrue(summary.cancelled)
        XCTAssertEqual(summary.documents.map(\.state), [.cancelled, .cancelled])
        XCTAssertEqual(try Data(contentsOf: request.documents[0].destination), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.documents[1].destination.path))
        XCTAssertEqual(try fixture.records().filter { $0["event"] as? String == "launch" }.count, 1)
        try fixture.assertClean()
    }

    func testInitializationFailureReapsTheWorkerWithoutWaitingForItsDeadline() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let started = ContinuousClock.now
        let log = ProgressLog()
        do {
            try await ChunkScheduler(configuration: fixture.configuration("initializeFailure", timeout: .seconds(30))).render(
                chunks: ["One.", "Two.", "Three."], batchID: UUID(), jobID: UUID(), workspace: fixture.root,
                settings: .init(), destination: fixture.destination, progress: { log.append($0) })
            XCTFail("Expected initialization failure")
        } catch let failure as SpeechFailure { XCTAssertEqual(failure.code, .invalidInput) }
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        XCTAssertEqual(log.snapshot.filter { $0.phase == .started }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        try fixture.assertClean()
    }

    func testReplacementRequiresExplicitApprovalAndOnlyCoversExistingPlans() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let one = try fixture.input("one.txt")
        let two = try fixture.input("two.txt")
        let old = Data("previous complete audio".utf8)
        try old.write(to: fixture.output.appendingPathComponent("one.wav"))
        let coordinator = QueueCoordinator(configuration: fixture.configuration())
        do { _ = try await coordinator.run(fixture.request([one, two])); XCTFail("Expected replacement approval") }
        catch let error as PlanningError {
            if case .replacementRequired = error {} else { XCTFail("Unexpected planning failure") }
        }
        XCTAssertEqual(try fixture.records().count, 0)
        let request = try fixture.request([one, two], replaceExisting: true)
        XCTAssertEqual(request.approvedReplacements, [one.id])
        // A new output arriving after approval was never part of that approval.
        try old.write(to: request.documents[1].destination)
        do { _ = try await coordinator.run(request); XCTFail("Expected late output protection") }
        catch is PlanningError {}
        XCTAssertEqual(try Data(contentsOf: request.documents[0].destination), old)
        XCTAssertEqual(try Data(contentsOf: request.documents[1].destination), old)
        let confirmed = try fixture.request([one, two], replaceExisting: true)
        let result = try await coordinator.run(confirmed)
        XCTAssertEqual(result.successfulCount, 2)
        XCTAssertNotEqual(try Data(contentsOf: confirmed.documents[0].destination), old)
        try fixture.assertClean()
    }

    func testCancellationInLaterDocumentKeepsAlreadyPublishedAudio() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let request = try fixture.request([fixture.input("one.txt"), fixture.input("two.txt"), fixture.input("three.txt")])
        let coordinator = QueueCoordinator(configuration: fixture.configuration("secondDocumentStall", timeout: .seconds(30)))
        let task = Task { try await coordinator.run(request) }
        try await waitForRecord(fixture, name: "generate", count: 2)
        let first = try Data(contentsOf: request.documents[0].destination)
        XCTAssertFalse(first.isEmpty)
        await coordinator.cancelAndWait()
        let summary = try await task.value
        XCTAssertEqual(summary.documents.map(\.state), [.published, .cancelled, .cancelled])
        XCTAssertTrue(summary.cancelled)
        XCTAssertEqual(try Data(contentsOf: request.documents[0].destination), first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.documents[1].destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.documents[2].destination.path))
        try fixture.assertClean()
    }

    func testOutputAppearingAtPublicationNeedsApprovalAndDoesNotRetry() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let input = try fixture.input("late.txt", text: String(repeating: "This public fixture needs several complete chunks. ", count: 16))
        let request = try fixture.request([input])
        let destination = request.documents[0].destination
        let previous = Data("complete audio arriving from another writer".utf8)
        let log = ProgressLog()
        let coordinator = QueueCoordinator(configuration: fixture.configuration())
        let result = try await coordinator.run(request) { event in
            if case .speech(let value) = event {
                log.append(value)
                if value.phase == .publishing { try? previous.write(to: destination) }
            }
        }
        XCTAssertEqual(result.documents.map(\.state), [.failed])
        XCTAssertEqual(result.successfulCount, 0)
        XCTAssertEqual(try Data(contentsOf: destination), previous)
        XCTAssertEqual(log.snapshot.filter { $0.phase == .started }.count, 1)
        try fixture.assertClean()
    }

    func testLateOutputAliasIsRejectedWithoutRetryOrExternalOverwrite() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("external.wav")
        let previous = Data("external complete audio".utf8)
        try previous.write(to: outside)
        let log = ProgressLog()
        do {
            try await render(fixture, count: 4, log: log, beforePublication: {
                try FileManager.default.createSymbolicLink(at: fixture.destination, withDestinationURL: outside)
            })
            XCTFail("Expected late alias rejection")
        } catch let failure as SpeechFailure { XCTAssertEqual(failure.code, .storage) }
        XCTAssertEqual(log.snapshot.filter { $0.phase == .started }.count, 1)
        XCTAssertEqual(try Data(contentsOf: outside), previous)
        try fixture.assertClean()
    }

    private func waitForRecord(_ fixture: ProcessFixture, name: String, count: Int = 1) async throws {
        for _ in 0..<200 {
            if try fixture.records().filter({ $0["event"] as? String == name }).count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Fixture did not reach \(name)")
    }
}

extension SchedulingTests {
    func testLegacyBatchReusesOneNativeSessionAndReapsIt() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let configuration = fixture.configuration()
        let one = try fixture.input("one.txt")
        let two = try fixture.input("two.txt")
        let summary = try await QueueCoordinator(configuration: configuration).run(fixture.request([one, two]))
        XCTAssertEqual(summary.successfulCount, 2)
        let records = try fixture.records()
        XCTAssertEqual(records.filter { $0["event"] as? String == "launch" }.count, 1)
        XCTAssertEqual(records.filter { $0["event"] as? String == "initialize" }.count, 1)
        XCTAssertEqual(records.filter { $0["event"] as? String == "generate" }.compactMap { $0["chunk"] as? Int }, [0, 1])
        XCTAssertEqual(try fixture.samples(fixture.output.appendingPathComponent("one.wav")), [Float](repeating: 0.01, count: 4))
        XCTAssertEqual(try fixture.samples(fixture.output.appendingPathComponent("two.wav")), [Float](repeating: 0.02, count: 4))
        try fixture.assertClean()
    }

    func testInferenceLeaseCancellationDoesNotReleaseAnotherOwner() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let path = fixture.root.appendingPathComponent("shared.lock")
        var held: InferenceLease? = try await InferenceLease.acquire(at: path)
        let waiting = Task { try await InferenceLease.acquire(at: path) }
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Waiting inference should cancel") }
        catch is CancellationError {}
        XCTAssertNotNil(held)
        let descriptor = open(path.path, O_RDWR | O_NOFOLLOW, 0)
        defer { close(descriptor) }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), -1)
        XCTAssertEqual(errno, EWOULDBLOCK)
        held = nil
        let reacquired = try await InferenceLease.acquire(at: path)
        withExtendedLifetime(reacquired) {}
    }

    func testPersistentSessionFailurePreservesPreviousAudioAndReleasesLease() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let configuration = fixture.configuration("invalidInput")
        let previous = Data([17, 18])
        try previous.write(to: fixture.destination)
        let session = try NativeSpeechSession(configuration: configuration, workspace: fixture.root,
                                               settings: .init(), leaseFile: configuration.inferenceLeaseFile)
        try await session.prepare()
        _ = try await session.synthesize(text: "First.", destination: fixture.output.appendingPathComponent("first.wav"))
        do {
            _ = try await session.synthesize(text: "Second.", destination: fixture.destination)
            XCTFail("Expected the second request to fail")
        } catch let failure as SpeechFailure { XCTAssertEqual(failure.code, .invalidInput) }
        XCTAssertEqual(try Data(contentsOf: fixture.destination), previous)
        let lease = try await InferenceLease.acquire(at: configuration.inferenceLeaseFile)
        withExtendedLifetime(lease) {}
        try fixture.assertClean()
    }
}

extension SchedulingTests {
    func testBackgroundRenderYieldsAfterCurrentChunkToInteractiveProcess() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let configuration = fixture.configuration("slowFirst")
        let session = try NativeSpeechSession(configuration: configuration, workspace: fixture.root,
            settings: .init(), leaseFile: configuration.inferenceLeaseFile)
        try await session.prepare()
        let rendering = Task {
            try await session.render(chunks: ["First.", "Second.", "Third."], destination: fixture.destination,
                identity: .init(batch: UUID(), job: UUID()))
        }
        defer { rendering.cancel() }
        try await waitForRecord(fixture, name: "generate")
        let foreground = Process()
        foreground.executableURL = fixture.worker
        foreground.arguments = ["--lease", configuration.inferenceLeaseFile.path, "interactive", "100",
                                fixture.trace.appendingPathComponent("foreground.jsonl").path]
        try foreground.run()
        defer { if foreground.isRunning { foreground.terminate(); foreground.waitUntilExit() } }
        try await waitForRecord(fixture, name: "acquired")
        try await rendering.value
        await session.close()
        foreground.waitUntilExit()
        XCTAssertEqual(foreground.terminationStatus, 0)
        let records = try fixture.records()
        let released = try XCTUnwrap(records.first { $0["event"] as? String == "released" }?["time"] as? Double)
        let nextChunk = try XCTUnwrap(records.first { $0["event"] as? String == "generate" && $0["chunk"] as? Int == 1 }?["time"] as? Double)
        XCTAssertGreaterThan(nextChunk, released)
        XCTAssertEqual(try fixture.samples(), [Float](repeating: 0.01, count: 4) + [Float](repeating: 0.02, count: 4) + [Float](repeating: 0.03, count: 4))
        try fixture.assertClean()
    }
}


extension SchedulingTests {
    func testOfflineSetupCheckInitializesSelectedModelWithoutDownloadingOrGeneratingAndReaps() async throws {
        for model in SpeechModel.allCases {
            let fixture = try ProcessFixture(); defer { fixture.remove() }
            let configuration = fixture.configuration()
            try await SpeechSetupCheck.run(configuration: configuration, workspace: fixture.root,
                settings: .init(model: model, voice: "af_bella", speed: 1.25))
            let records = try fixture.records()
            XCTAssertEqual(records.filter { $0["event"] as? String == "initialize" }.count, 1)
            XCTAssertFalse(records.contains { ["prepare", "generate"].contains($0["event"] as? String ?? "") })
            let initialization = try XCTUnwrap(records.first { $0["event"] as? String == "initialize" })
            XCTAssertEqual(initialization["model"] as? String, model.rawValue)
            XCTAssertEqual(initialization["voice"] as? String, "af_bella")
            XCTAssertEqual(initialization["speed"] as? Double, 1.25)
            let lease = try await InferenceLease.acquire(at: configuration.inferenceLeaseFile)
            withExtendedLifetime(lease) {}
            try fixture.assertClean()
        }
    }

    func testOfflineSetupCheckFailureAndCancellationReapAndReleaseLease() async throws {
        for cancel in [false, true] {
            let fixture = try ProcessFixture(); defer { fixture.remove() }
            let configuration = fixture.configuration(cancel ? "prepareStall" : "initializeFailure", timeout: .seconds(5))
            let task = Task { try await SpeechSetupCheck.run(configuration: configuration, workspace: fixture.root, settings: .init()) }
            if cancel { try await waitForRecord(fixture, name: "initialize"); task.cancel() }
            do { try await task.value; XCTFail("Unsuccessful check reported ready") }
            catch is CancellationError { XCTAssertTrue(cancel) }
            catch let failure as SpeechFailure { XCTAssertFalse(cancel); XCTAssertEqual(failure.code, .invalidInput) }
            let lease = try await InferenceLease.acquire(at: configuration.inferenceLeaseFile)
            withExtendedLifetime(lease) {}
            try fixture.assertClean()
        }
    }
}

@MainActor
final class PreparedSessionTests: XCTestCase {
    func testCandidatePreparationFreezesTotalsAndSynthesisDoesNotRunG2PAgain() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let settings = SpeechSettings()
        let policy = SpeechPreparationPolicy.longformPausesCandidate
        let projection = try NarrationPlanner.prepareForSpeech(.init(blocks: [
            .init(kind: .heading, text: "A heading"),
            .init(kind: .paragraph, text: String(repeating: "Read this short sentence. ", count: 55))
        ], extractorVersion: "fixture"), settings: settings, policy: policy)
        let session = try NativeSpeechSession(configuration: fixture.configuration(), workspace: fixture.root,
            settings: settings, leaseFile: fixture.root.appendingPathComponent("lease"), policy: policy)
        try await session.prepare()
        let prepared = try await session.prepareSpeech(projection)
        let progress = ProgressLog()
        try await session.render(plan: prepared, destination: fixture.destination, identity: .init(batch: UUID(), job: UUID()), progress: { progress.append($0) })
        await session.close()
        let records = try fixture.records()
        XCTAssertEqual(records.filter { $0["event"] as? String == "prepareText" }.count, prepared.utterances.count)
        XCTAssertEqual(records.filter { $0["event"] as? String == "generatePrepared" }.count, prepared.utterances.count)
        XCTAssertEqual(records.filter { $0["event"] as? String == "generate" }.count, 0)
        XCTAssertTrue(progress.snapshot.allSatisfy { $0.totalChunks == prepared.utterances.count })
        XCTAssertEqual(progress.snapshot.first?.completedChunks, 0)
        XCTAssertEqual(progress.snapshot.last?.completedChunks, prepared.utterances.count)
        try fixture.assertClean()
    }
    func testPreparedSpeechCannotBeReusedWithDifferentCapturedSpeed() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let policy = SpeechPreparationPolicy.longformCandidate
        let first = try NativeSpeechSession(configuration: fixture.configuration(), workspace: fixture.root,
            settings: .init(speed: 1), leaseFile: fixture.root.appendingPathComponent("lease"), policy: policy)
        try await first.prepare()
        let projection = try NarrationPlanner.prepareForSpeech(.init(blocks: [.init(kind: .paragraph, text: "A short sentence.")], extractorVersion: "fixture"), settings: .init(speed: 1), policy: policy)
        let plan = try await first.prepareSpeech(projection)
        await first.close()
        let second = try NativeSpeechSession(configuration: fixture.configuration(), workspace: fixture.root,
            settings: .init(speed: 1.1), leaseFile: fixture.root.appendingPathComponent("lease"), policy: policy)
        try await second.prepare()
        do {
            try await second.render(plan: plan, destination: fixture.destination, identity: .init(batch: UUID(), job: UUID()))
            XCTFail("Stale acoustic identity accepted")
        } catch let failure as SpeechFailure { XCTAssertEqual(failure.code, .invalidInput) }
        await second.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        try fixture.assertClean()
    }
    func testPreparedIPCStaysBoundedAndProtocolIsExplicitlyVersioned() throws {
        let identity = AttemptIdentity(batch: UUID(), job: UUID())
        let source = SpokenSourceRange(blockIndices: [0], location: 0, length: 1_000)
        let command = WorkerCommand(kind: .prepareText, identity: identity, chunk: 0,
            textWindow: .init(text: String(repeating: "𐐀", count: 1_000), source: source, boundaryAfter: .paragraph))
        XCTAssertLessThan(try SpeechIPC.encode(command).count, SpeechIPC.maximumRecordBytes)
        XCTAssertEqual(command.protocolVersion, 2)
        XCTAssertThrowsError(try SpeechIPC.encode(WorkerCommand(kind: .generate, identity: identity, chunk: 0, text: String(repeating: "a", count: 70_000))))
    }
}


extension SchedulingTests {
    func testAcceptedDefaultBatchPreparesOncePerPassageAndReusesOneWorker() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        var configuration = WorkerConfiguration(executable: fixture.worker,
            environment: ["NARRATION_FIXTURE_TRACE": fixture.trace.path, "NARRATION_FIXTURE_CAPTURE_TEXT": "1"],
            inferenceLeaseFile: fixture.root.appendingPathComponent("inference.lock"))
        let store = PronunciationStore(file: fixture.root.appendingPathComponent("pronunciation.json"))
        _ = try store.save(entries: [.init(word: "SQLite", spelling: "sequel lite")], expectedRevision: nil)
        configuration.pronunciationStore = store
        XCTAssertEqual(configuration.preparationPolicy, .longformPausesCandidate)
        let inputs = try [fixture.input("one.txt", text: "SQLite is useful."), fixture.input("two.txt", text: "SQLite remains useful.")]
        let summary = try await QueueCoordinator(configuration: configuration).run(fixture.request(inputs))
        XCTAssertEqual(summary.successfulCount, 2)
        let records = try fixture.records()
        XCTAssertEqual(records.filter { $0["event"] as? String == "launch" }.count, 1)
        XCTAssertEqual(records.filter { $0["event"] as? String == "initialize" }.count, 1)
        XCTAssertEqual(records.filter { $0["event"] as? String == "prepareText" }.count, 2)
        XCTAssertEqual(records.filter { $0["event"] as? String == "generatePrepared" }.count, 2)
        XCTAssertFalse(records.contains { $0["event"] as? String == "generate" })
        XCTAssertEqual(records.filter { $0["event"] as? String == "generatePrepared" }.compactMap { $0["text"] as? String },
            ["sequel lite is useful.", "sequel lite remains useful."])
        XCTAssertEqual(try fixture.samples(fixture.output.appendingPathComponent("one.wav")), [Float](repeating: 0.01, count: 4))
        XCTAssertEqual(try fixture.samples(fixture.output.appendingPathComponent("two.wav")), [Float](repeating: 0.02, count: 4))
        try fixture.assertClean()
    }
}
