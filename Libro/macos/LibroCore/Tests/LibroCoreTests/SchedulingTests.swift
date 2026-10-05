import XCTest
import AVFoundation
import Darwin
@testable import LibroCore

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
        worker = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LIBRO_FIXTURE_WORKER"] ??
            macos.appendingPathComponent(".build/CoreTests/debug/LibroFixtureWorker").path)
        guard FileManager.default.isExecutableFile(atPath: worker.path) else {
            throw XCTSkip("Build LibroFixtureWorker with macos/scripts/check.sh before process tests.")
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
        WorkerConfiguration(executable: worker, environment: ["LIBRO_FIXTURE_MODE": mode, "LIBRO_FIXTURE_TRACE": trace.path],
                            requestTimeout: timeout, shutdownGrace: 0.05, terminationGrace: 0.05)
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
    func request(_ inputs: [InputDocument], serial: Bool = false, replaceExisting: Bool = false) throws -> BatchRequest {
        .init(documents: try BatchPlanner.plan(inputs, output: output), outputDirectory: output,
              workspace: root, settings: .init(), serial: serial, replaceExisting: replaceExisting)
    }
    func samples(_ destination: URL? = nil) throws -> [Int16] {
        let file = try AVAudioFile(forReading: destination ?? self.destination, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.int16ChannelData?[0]), count: Int(file.length)))
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

@MainActor
final class SchedulingTests: XCTestCase {
    private func render(_ fixture: ProcessFixture, count: Int, mode: String = "success", serial: Bool = false,
                        log: ProgressLog = ProgressLog(), beforePublication: @escaping @Sendable () throws -> Void = {}) async throws {
        try await ChunkScheduler(configuration: fixture.configuration(mode)).render(
            chunks: (0..<count).map { "Public fixture chunk \($0)." }, batchID: UUID(), jobID: UUID(),
            workspace: fixture.root, settings: .init(), serial: serial, destination: fixture.destination,
            beforePublication: beforePublication, progress: { log.append($0) })
    }

    func testThreeChunkThresholdSerialOverrideAndWhitespaceOmission() async throws {
        for (count, serial, expectedWorkers) in [(2, false, 1), (3, false, 2), (5, true, 1)] {
            let fixture = try ProcessFixture(); defer { fixture.remove() }
            let log = ProgressLog()
            try await render(fixture, count: count, serial: serial, log: log)
            XCTAssertEqual(try fixture.records().filter { $0["event"] as? String == "initialize" }.count, expectedWorkers)
            XCTAssertEqual(log.snapshot.first?.workerCount, expectedWorkers)
            XCTAssertEqual(try fixture.samples().count, count * 4)
            try fixture.assertClean()
        }
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        try await ChunkScheduler(configuration: fixture.configuration()).render(chunks: ["One.", "\u{a0}\n", "Two."],
            batchID: UUID(), jobID: UUID(), workspace: fixture.root, settings: .init(), serial: false, destination: fixture.destination)
        XCTAssertEqual(try fixture.samples().count, 8)
        XCTAssertEqual(try fixture.records().filter { $0["event"] as? String == "initialize" }.count, 1)
        try fixture.assertClean()
    }

    func testOrderedIncrementalResultsAndTwelveChunkBackpressure() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let log = ProgressLog()
        try await render(fixture, count: 25, mode: "slowFirst", log: log)
        let expected = (0..<25).flatMap { index in Array(repeating: Int16(Float(index + 1) / 100 * 32767), count: 4) }
        XCTAssertEqual(try fixture.samples(), expected)
        let records = try fixture.records()
        let starts = records.filter { $0["event"] as? String == "generate" }
        let results = records.filter { $0["event"] as? String == "result" }
        let firstResult = try XCTUnwrap(results.first { $0["chunk"] as? Int == 0 }?["time"] as? Double)
        XCTAssertTrue(results.contains { ($0["chunk"] as? Int ?? 0) > 0 && ($0["time"] as? Double ?? .infinity) < firstResult })
        for lower in [12, 24] {
            let previousCompletion = results.filter { ($0["chunk"] as? Int ?? -1) < lower }.compactMap { $0["time"] as? Double }.max()!
            let nextStart = starts.filter { ($0["chunk"] as? Int ?? -1) >= lower }.compactMap { $0["time"] as? Double }.min()!
            XCTAssertGreaterThan(nextStart, previousCompletion)
        }
        XCTAssertEqual(records.filter { $0["event"] as? String == "initialize" }.count, 2)
        XCTAssertEqual(log.snapshot.filter { $0.phase == .chunkWritten }.map(\.completedChunks), Array(1...25))
        try fixture.assertClean()
    }

    func testWholeParallelAttemptIsDiscardedAndRetriedSeriallyOnce() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        try Data("previous audio".utf8).write(to: fixture.destination)
        let log = ProgressLog()
        try await render(fixture, count: 7, mode: "fallback", log: log)
        let attempts = log.snapshot.filter { $0.phase == .attemptStarted }
        XCTAssertEqual(attempts.map(\.attemptNumber), [1, 2])
        XCTAssertEqual(attempts.map(\.workerCount), [2, 1])
        XCTAssertEqual(attempts.map(\.completedChunks), [0, 0])
        XCTAssertNotEqual(attempts[0].identity.attempt, attempts[1].identity.attempt)
        let initializations = try fixture.records().filter { $0["event"] as? String == "initialize" }
        XCTAssertEqual(initializations.count, 3)
        let retryChunks = try fixture.records().filter { $0["event"] as? String == "generate" && $0["attempt"] as? String == attempts[1].identity.attempt.uuidString }
        XCTAssertEqual(retryChunks.compactMap { $0["chunk"] as? Int }, Array(0..<7))
        XCTAssertEqual(try fixture.samples(), (0..<7).flatMap { Array(repeating: Int16(Float($0 + 1) / 100 * 32767), count: 4) })
        try fixture.assertClean()
    }

    func testMalformedControlAndPCMOrCrashRetryOnlyOnceAndPreserveOutput() async throws {
        for mode in ["malformed", "oversized", "nan", "shortPCM", "symlinkPCM", "rate", "channels", "frames", "path", "crash"] {
            let fixture = try ProcessFixture(); defer { fixture.remove() }
            let previous = Data("complete prior WAV fixture".utf8)
            try previous.write(to: fixture.destination)
            let log = ProgressLog()
            do { try await render(fixture, count: 4, mode: mode, log: log); XCTFail("Expected \(mode) failure") }
            catch let failure as SpeechFailure { XCTAssertTrue(failure.code.permitsSerialRetry, mode) }
            XCTAssertEqual(log.snapshot.filter { $0.phase == .attemptStarted }.map(\.workerCount), [2, 1], mode)
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
            } catch let failure as SpeechFailure { XCTAssertFalse(failure.code.permitsSerialRetry) }
            XCTAssertEqual(log.snapshot.filter { $0.phase == .attemptStarted }.count, 1)
            XCTAssertEqual(try Data(contentsOf: fixture.destination), previous)
            try fixture.assertClean()
        }
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let obstruction = fixture.output.appendingPathComponent("folder")
        try Data([1]).write(to: obstruction)
        do {
            try await ChunkScheduler(configuration: fixture.configuration()).render(chunks: ["One.", "Two.", "Three."],
                batchID: UUID(), jobID: UUID(), workspace: fixture.root, settings: .init(), serial: false,
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
                                       settings: .init(), serial: true, destination: fixture.destination)
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
                settings: .init(), serial: false, destination: cancelled.destination)
        }
        try await waitForRecord(cancelled, name: "generate")
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertEqual(try cancelled.records().filter { $0["event"] as? String == "initialize" }.count, 2)
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
        XCTAssertEqual(log.snapshot.filter { $0.phase == .attemptStarted }.count, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), previous)
        try fixture.assertClean()
        let task = Task {
            try Task.checkCancellation()
            try await self.render(fixture, count: 3)
        }
        task.cancel()
        do { try await task.value; XCTFail("Expected queued cancellation") }
        catch is CancellationError {}
        XCTAssertEqual(try fixture.records().filter { $0["event"] as? String == "launch" }.count, 2)
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
                settings: .init(), serial: false, destination: fixture.destination, progress: {
                    log.append($0)
                    if $0.phase == .publishing { cancellation.cancel() }
                })
        }
        cancellation.set(task)
        defer { cancellation.set(nil) }
        do { try await task.value; XCTFail("Expected actual task cancellation at publication") }
        catch is CancellationError {}
        XCTAssertEqual(log.snapshot.filter { $0.phase == .attemptStarted }.count, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), previous)
        try fixture.assertClean()
    }

    func testSequentialDocumentsContinueAfterInvalidInputAndFinishAfterPublication() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let one = try fixture.input("one.txt", text: String(repeating: "A complete public sentence with useful words. ", count: 12))
        let bad = try fixture.input("bad.txt", text: "[1]  \n")
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
        let firstPIDs = records.filter { $0["job"] as? String == one.id.uuidString && $0["event"] as? String == "initialize" }.compactMap { $0["pid"] as? Int }
        let firstExits = records.filter { firstPIDs.contains($0["pid"] as? Int ?? 0) && $0["event"] as? String == "exit" }.compactMap { $0["time"] as? Double }
        let secondStart = try XCTUnwrap(records.first { $0["job"] as? String == two.id.uuidString && $0["event"] as? String == "initialize" }?["time"] as? Double)
        XCTAssertEqual(firstExits.count, 2)
        XCTAssertTrue(firstExits.allSatisfy { $0 < secondStart })
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

    func testInitializationFailureStopsOtherWorkerWithoutWaitingForItsDeadline() async throws {
        let fixture = try ProcessFixture(); defer { fixture.remove() }
        let started = ContinuousClock.now
        let log = ProgressLog()
        do {
            try await ChunkScheduler(configuration: fixture.configuration("initializeFailureAndStall", timeout: .seconds(30))).render(
                chunks: ["One.", "Two.", "Three."], batchID: UUID(), jobID: UUID(), workspace: fixture.root,
                settings: .init(), serial: false, destination: fixture.destination, progress: { log.append($0) })
            XCTFail("Expected initialization failure")
        } catch let failure as SpeechFailure { XCTAssertEqual(failure.code, .invalidInput) }
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        XCTAssertEqual(log.snapshot.filter { $0.phase == .attemptStarted }.count, 1)
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
        let request = try fixture.request([fixture.input("one.txt"), fixture.input("two.txt"), fixture.input("three.txt")], serial: true)
        let coordinator = QueueCoordinator(configuration: fixture.configuration("secondPrepareStall", timeout: .seconds(30)))
        let task = Task { try await coordinator.run(request) }
        try await waitForRecord(fixture, name: "initialize", count: 2)
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
        XCTAssertEqual(log.snapshot.filter { $0.phase == .attemptStarted }.count, 1)
        XCTAssertEqual(log.snapshot.first { $0.phase == .attemptStarted }?.workerCount, 2)
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
        XCTAssertEqual(log.snapshot.filter { $0.phase == .attemptStarted }.count, 1)
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
