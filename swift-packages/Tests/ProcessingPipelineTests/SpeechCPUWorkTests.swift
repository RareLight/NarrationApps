import XCTest
import Foundation
import NarrationCore
import NativeSpeech
import AudioOutput
import DocumentProcessing
@testable import ProcessingPipeline

final class SpeechCPUWorkTests: XCTestCase, @unchecked Sendable {
    private final class Gate: @unchecked Sendable {
        let condition = NSCondition()
        private var started = false, allowed = false, ended = false
        private var wait: SpeechWorkWait?
        var state: (started: Bool, ended: Bool, waiting: SpeechWorkWait?) {
            condition.lock(); defer { condition.unlock() }; return (started, ended, wait)
        }
        func hold() {
            condition.lock(); defer { condition.unlock() }; started = true
            while !allowed { condition.wait() }
        }
        func release() { condition.lock(); allowed = true; condition.broadcast(); condition.unlock() }
        func finish() { condition.lock(); ended = true; condition.unlock() }
        func report(_ value: SpeechWorkWait?) { condition.lock(); wait = value; condition.unlock() }
    }
    private func fixture() throws -> (URL, SpeechWorkCoordinator) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("cpu-work-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let worker = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"]))
        let c = try SpeechWorkCoordinator(owner: .voiceRelay, configuration: .init(executable: worker, arguments: ["--handoff-probe"],
            shutdownGrace: 0.1, terminationGrace: 0.1, inferenceLeaseFile: root.appendingPathComponent("inference.lock")), root: root.appendingPathComponent("admission"))
        addTeardownBlock { await c.close(); try? FileManager.default.removeItem(at: root) }
        return (root, c)
    }
    private func wait(_ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while try await !predicate() {
            guard ContinuousClock.now < deadline else { XCTFail("CPU barrier timed out"); throw SpeechFailure(.timeout) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func job(_ c: SpeechWorkCoordinator, _ root: URL, rank: SpeechWorkRank = .podcast,
                     purpose: SpeechWorkPurpose = .speech, gate: Gate? = nil) async throws -> SpeechWorkJob {
        try await c.openJob(identity: .init(batch: UUID(), job: UUID()), settings: .init(model: .soprano), workspace: root,
            rank: rank, delivery: rank == .api ? .streaming : .file, waiting: { gate?.report($0) }, purpose: purpose)
    }
    func testCPUOnlyDemandCannotLoadHelperAndDoesNotBlockSameAppSpeech() async throws {
        let (root, c) = try fixture(), gate = Gate()
        addTeardownBlock { gate.release() }
        let cpu = try await job(c, root, purpose: .cpu)
        let work = Task { try await SpeechCPUWork.run(job: cpu) { gate.hold(); return 42 } }
        try await wait { gate.state.started }
        let before = await c.observation(); XCTAssertNil(before.pid)
        do { _ = try await c.perform(.initialize, job: cpu); XCTFail("CPU ticket loaded weights") } catch let e as SpeechFailure { XCTAssertEqual(e.code, .invalidInput) }
        let speech = try await job(c, root)
        _ = try await c.perform(.initialize, job: speech)
        let after = await c.observation(); XCTAssertNotNil(after.pid)
        gate.release(); let value = try await work.value; XCTAssertEqual(value, 42)
        await c.closeJob(cpu); await c.closeJob(speech)
    }
    func testPausedBackgroundQueueCannotBlockAcceptedAPIEncoder() async throws {
        let (root, c) = try fixture(), gate = Gate()
        let cpu = try await job(c, root, purpose: .cpu, gate: gate)
        addTeardownBlock { gate.release() }
        let lower = Task { try await SpeechCPUWork.run(job: cpu) {
            XCTAssertFalse(Thread.isMainThread); gate.hold(); try AudioWorkCheckpoint.check(); return 7
        } }
        try await wait { gate.state.started }
        let api = try await job(c, root, rank: .api)
        gate.release(); try await wait { gate.state.waiting == .api }
        let live = try await SpeechCPUWork.run(job: api) { try AudioWorkCheckpoint.check(); return 19 }
        XCTAssertEqual(live, 19)
        await c.closeJob(api)
        let resumed = try await lower.value; XCTAssertEqual(resumed, 7)
    }
    func testQuitJoinsActualCPUUnitBeforeReturningAndAbortsOwnedWAV() async throws {
        let (root, c) = try fixture(), gate = Gate(), output = root.appendingPathComponent("unfinished.wav")
        addTeardownBlock { gate.release() }
        let cpu = try await job(c, root, purpose: .cpu)
        let work = Task { try await SpeechCPUWork.run(job: cpu) {
            let writer = try AtomicAudioWriter(destination: output); defer { writer.abort(); gate.finish() }
            try writer.append(samples: [0, 0.125, -0.25], sampleRate: 24_000)
            gate.hold(); try AudioWorkCheckpoint.check(); try writer.publish()
        } }
        try await wait { gate.state.started }
        let close = Task { await c.close() }
        try await wait { await c.observation().closed }
        XCTAssertFalse(gate.state.ended); XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        gate.release(); await close.value
        do { try await work.value; XCTFail("Quit published stale output") } catch is CancellationError {}
        XCTAssertTrue(gate.state.ended); XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    func testMaintenanceWaitsForCPUParkAndThenResumesWithoutDiscardingState() async throws {
        let (root, c) = try fixture(), gate = Gate(), maintenance = Gate()
        addTeardownBlock { gate.release(); maintenance.release() }
        let cpu = try await job(c, root, purpose: .cpu, gate: gate)
        let work = Task { try await SpeechCPUWork.run(job: cpu) {
            var samples: [Float] = [0.25, -0.5]
            gate.hold(); try AudioWorkCheckpoint.check(); samples.append(0.125); return samples
        } }
        try await wait { gate.state.started }
        let change = Task { try await c.withMaintenance {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async { maintenance.hold(); continuation.resume() }
            }
        } }
        try await wait { await c.observation().maintaining }
        XCTAssertFalse(maintenance.state.started)
        gate.release(); try await wait { maintenance.state.started && gate.state.waiting == .maintenance }
        maintenance.release(); try await change.value
        let samples = try await work.value; XCTAssertEqual(samples, [0.25, -0.5, 0.125])
    }
    func testCancellationWhileCPUWaitsDoesNotCancelAPI() async throws {
        let (root, c) = try fixture(), gate = Gate()
        let api = try await job(c, root, rank: .api), cpu = try await job(c, root, purpose: .cpu, gate: gate)
        let pending = Task { try await SpeechCPUWork.run(job: cpu) { XCTFail("Cancelled CPU work started") } }
        try await wait { gate.state.waiting == .api }
        pending.cancel()
        do { try await pending.value; XCTFail("CPU wait ignored cancellation") } catch is CancellationError {}
        let value = try await SpeechCPUWork.run(job: api) { 31 }; XCTAssertEqual(value, 31)
        await c.closeJob(api); await c.closeJob(cpu)
    }
    func testCooperativeWriterRetainsAllFloat32FramesAndGain() async throws {
        let (root, c) = try fixture()
        let cpu = try await job(c, root, purpose: .cpu)
        let samples = (0..<70_000).map { [Float(0), 0.0005, -0.75, 1.25][$0 % 4] }
        let output = root.appendingPathComponent("exact.wav")
        let decoded = try await SpeechCPUWork.run(job: cpu) {
            let writer = try AtomicAudioWriter(destination: output); defer { writer.abort() }
            try writer.append(samples: samples, sampleRate: 24_000); try writer.publish()
            var decoded: [Float] = []; try NativeAudio.decode(output) { decoded += $0 }
            return decoded
        }
        XCTAssertEqual(decoded, samples)
    }
    func testCoreDiagnosticsYieldToAPIAndKeepReadOnlyResults() async throws {
        let (root, c) = try fixture(), gate = Gate()
        let samples = (0..<192_000).map { Float($0 % 97) / 64 - 0.75 }
        let expected = try NarrationDiagnostics.inspect(samples: samples, sampleRate: 24_000, text: "A synthetic diagnostic passage.")
        let cpu = try await job(c, root, purpose: .cpu, gate: gate)
        let work = Task { try await SpeechCPUWork.run(job: cpu) {
            defer { gate.finish() }
            gate.hold()
            return try NarrationDiagnostics.inspect(samples: samples, sampleRate: 24_000, text: "A synthetic diagnostic passage.")
        } }
        var api: SpeechWorkJob?
        do {
            try await wait { gate.state.started }
            let accepted = try await job(c, root, rank: .api); api = accepted
            gate.release(); try await wait { gate.state.waiting == .api }
            XCTAssertFalse(gate.state.ended)
            let live = try await SpeechCPUWork.run(job: accepted) { 17 }; XCTAssertEqual(live, 17)
            await c.closeJob(accepted)
            let result = try await work.value; XCTAssertEqual(result, expected)
            await c.closeJob(cpu)
        } catch {
            gate.release(); work.cancel()
            if let api { await c.closeJob(api) }
            _ = await work.result; throw error
        }
    }
    func testCPUOnlyMetadataNeedsNoValidModelOrRuntimeDirectory() async throws {
        let (root, c) = try fixture(), absent = root.appendingPathComponent("no-model-runtime")
        var settings = SpeechSettings(); settings.speed = -1
        XCTAssertFalse(settings.isValid)
        let cpu = SpeechCPUContext(coordinator: c, settings: settings, workspace: absent, rank: .podcast)
        let result = try await cpu.run { 42 }; XCTAssertEqual(result, 42)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
        let observed = await c.observation(); XCTAssertNil(observed.pid)
    }
    func testDocumentReadWaitsForAPIAndCancelsBeforeOpeningItsSource() async throws {
        let (root, c) = try fixture(), gate = Gate()
        let api = try await job(c, root, rank: .api)
        let cpu = SpeechCPUContext(coordinator: c, settings: .init(), workspace: root, rank: .podcast, waiting: { gate.report($0) })
        let input = InputDocument(source: root.appendingPathComponent("unopened.txt"), kind: .text, relativePath: "unopened.txt")
        let read = Task {
            try await NarrationPreparationWork.$executor.withValue(cpu) { try await DocumentReader.readSemantic(input) }
        }
        do {
            try await wait { gate.state.waiting == .api }
            read.cancel()
            do { _ = try await read.value; XCTFail("Cancelled source read completed") } catch is CancellationError {}
            let live = try await SpeechCPUWork.run(job: api) { 23 }; XCTAssertEqual(live, 23)
            let observed = await c.observation(); XCTAssertNil(observed.pid)
            await c.closeJob(api)
        } catch { read.cancel(); await c.closeJob(api); _ = await read.result; throw error }
    }
    func testIntakeParksAtNextEntryForAPIAndResumesWithAllInputs() async throws {
        let (root, c) = try fixture(), gate = Gate()
        addTeardownBlock { gate.release() }
        let executable = try XCTUnwrap(ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"])
        let libro = try SpeechWorkCoordinator(owner: .libro,
            configuration: .init(executable: URL(fileURLWithPath: executable), arguments: ["--handoff-probe"],
                inferenceLeaseFile: root.appendingPathComponent("inference.lock")), root: root.appendingPathComponent("admission"))
        addTeardownBlock { await libro.close() }
        let inputs = root.appendingPathComponent("inputs")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        for index in 0..<120 { try Data("Synthetic intake".utf8).write(to: inputs.appendingPathComponent("\(index).txt")) }
        let cpu = SpeechCPUContext(coordinator: libro, settings: .init(), workspace: root, rank: .libro, waiting: { gate.report($0) })
        let work = Task { try await cpu.run {
            defer { gate.finish() }
            return try InputCollector.collect([inputs]) { count in if count == 100 { gate.hold() } }
        } }
        var api: SpeechWorkJob?
        do {
            try await wait { gate.state.started }
            let accepted = try await job(c, root, rank: .api); api = accepted
            gate.release(); try await wait { gate.state.waiting == .api }
            XCTAssertFalse(gate.state.ended)
            let live = try await SpeechCPUWork.run(job: accepted) { 29 }; XCTAssertEqual(live, 29)
            await c.closeJob(accepted)
            let result = try await work.value
            XCTAssertEqual(result.documents.count, 120); XCTAssertTrue(result.issues.isEmpty)
            XCTAssertEqual(Set(result.documents.map(\.source)).count, 120)
            let observed = await libro.observation(); XCTAssertNil(observed.pid)
        } catch { gate.release(); work.cancel(); if let api { await c.closeJob(api) }; _ = await work.result; throw error }
    }
    func testMaintenanceAdmissionRetryHonorsStopAndInterruptionBeforeStartingCPU() async throws {
        for useInterruption in [false, true] {
            let (root, c) = try fixture(), maintenance = Gate(), reported = Gate(), stop = Gate(), finished = Gate()
            let change = Task { try await c.withMaintenance {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async { maintenance.hold(); continuation.resume() }
                }
            } }
            let cpu = SpeechCPUContext(coordinator: c, settings: .init(), workspace: root, rank: .podcast, waiting: { reported.report($0) })
            var context = cpu
            if !useInterruption { context.cancelled = { stop.state.ended } }
            let captured = context
            let pending = Task {
                defer { finished.finish() }
                return try await captured.run(interruption: {
                    if useInterruption && stop.state.ended { throw CancellationError() }
                }) { XCTFail("Stopped preparation started during maintenance"); return 0 }
            }
            do {
                try await wait { maintenance.state.started && reported.state.waiting == .maintenance }
                stop.finish()
                try await wait { finished.state.ended }
                do { _ = try await pending.value; XCTFail("Maintenance retry ignored Stop") } catch is CancellationError {}
                XCTAssertNil(reported.state.waiting)
                maintenance.release(); try await change.value
            } catch {
                pending.cancel(); maintenance.release()
                _ = await pending.result; _ = await change.result; throw error
            }
        }
    }

}
