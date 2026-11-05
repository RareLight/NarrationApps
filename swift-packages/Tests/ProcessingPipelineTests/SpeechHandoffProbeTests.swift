import XCTest
import Foundation
import Darwin
import NarrationCore
@testable import ProcessingPipeline

final class SpeechHandoffProbeTests: XCTestCase {
    func testCPUAdmissionRejectsVersionFiveHelperBeforeLoading() throws {
        let executable = try XCTUnwrap(ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"])
        let process = try SpeechProbeProcess(configuration: .init(executable: URL(fileURLWithPath: executable), arguments: ["--probe-version-five"], shutdownGrace: 0.1, terminationGrace: 0.1))
        defer { try? process.close() }
        try process.send(.initialize, .init(kind: .initialize, identity: job()))
        XCTAssertThrowsError(try process.next()) { XCTAssertEqual(($0 as? SpeechFailure)?.code, .incompatibleWorker) }
        try process.close()
    }
    private func setupProbe() throws -> (URL, SpeechProbeProcess) {
        guard let executable = ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"] else { throw XCTSkip("Build the fixture worker first.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let process = try SpeechProbeProcess(configuration: .init(executable: URL(fileURLWithPath: executable),
            arguments: ["--handoff-probe"], shutdownGrace: 0.1, terminationGrace: 0.1))
        addTeardownBlock { [weak process] in try? process?.close(); try? FileManager.default.removeItem(at: root) }
        let identity = AttemptIdentity(batch: UUID(), job: UUID())
        try process.send(.initialize, .init(kind: .initialize, identity: identity, spoolDirectory: root))
        XCTAssertEqual(try process.next().kind, .waitingForLease)
        XCTAssertEqual(try process.next().kind, .leaseAcquired)
        XCTAssertEqual(try process.next().kind, .loadingModel)
        XCTAssertEqual(try process.next().kind, .initialized)
        return (root, process)
    }
    private func job() -> AttemptIdentity { .init(batch: UUID(), job: UUID()) }
    func testHelperRechecksHighestDemandAtEveryUnitLaunch() throws {
        let executable = try XCTUnwrap(ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"])
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("launch-fence-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let scratch = try SpeechScratchLease(directory: root, create: true)
        defer { scratch.close() }
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try SpeechWorkAdmission(root: root.appendingPathComponent("admission")), instance = UUID()
        let lower = try registry.register(owner: .voiceRelay, instance: instance, rank: .podcast, delivery: .file)
        let lease = root.appendingPathComponent("inference.lock")
        let process = try SpeechProbeProcess(configuration: .init(executable: URL(fileURLWithPath: executable), arguments: ["--handoff-probe"]))
        defer { try? process.close() }
        let initialization = job()
        try process.send(.initialize, .init(kind: .initialize, identity: initialization, spoolDirectory: root),
            admission: .init(demand: lower.demand, root: root.appendingPathComponent("admission"), inferenceFile: lease))
        while try process.next().kind != .initialized {}
        let api = try registry.register(owner: .voiceRelay, instance: instance, rank: .api, delivery: .streaming)
        let stale = job()
        try process.send(.generate, .init(kind: .generate, identity: stale, text: "Must not start"),
            admission: .init(demand: lower.demand, root: root.appendingPathComponent("admission"), inferenceFile: lease))
        XCTAssertEqual(try process.next().kind, .revoked)
        XCTAssertEqual(try process.next().kind, .quiescent)
        XCTAssertEqual(try process.next().kind, .ready)
        let live = job()
        try process.send(.generate, .init(kind: .generate, identity: live, text: "Accepted"),
            admission: .init(demand: api.demand, root: root.appendingPathComponent("admission"), inferenceFile: lease))
        XCTAssertEqual(try finish(process, identity: live), 3)
    }
    private func cold(_ flags: [String], holdLoaded: Bool = false) throws -> (URL, SpeechProbeProcess, AttemptIdentity) {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for flag in flags { try Data().write(to: root.appendingPathComponent(flag)) }
        let process = try SpeechProbeProcess(configuration: .init(executable: URL(fileURLWithPath: path),
            arguments: ["--handoff-probe"], shutdownGrace: 0.15, terminationGrace: 0.1))
        addTeardownBlock { [weak process] in try? process?.close(); try? FileManager.default.removeItem(at: root) }
        let identity = job()
        try process.send(.initialize, .init(kind: .initialize, identity: identity, spoolDirectory: root), holdLoadedInitialization: holdLoaded)
        return (root, process, identity)
    }
    private func atLoad(_ process: SpeechProbeProcess) throws {
        XCTAssertEqual(try process.next().kind, .waitingForLease)
        XCTAssertEqual(try process.next().kind, .leaseAcquired)
        XCTAssertEqual(try process.next().kind, .loadingModel)
    }
    private func lockFile(_ root: URL) throws -> Int32 {
        let fd = open(root.appendingPathComponent("fixture-inference.lock").path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        return fd
    }
    func testCancelDuringLeaseWaitDoesNotAffectResidentOwner() throws {
        let (root, old) = try setupProbe()
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"])
        let process = try SpeechProbeProcess(configuration: .init(executable: URL(fileURLWithPath: path), arguments: ["--handoff-probe"]))
        defer { try? process.close() }
        let identity = job()
        try process.send(.initialize, .init(kind: .initialize, identity: identity, spoolDirectory: root))
        XCTAssertEqual(try process.next().kind, .waitingForLease)
        try process.send(.cancel, .init(kind: .cancel, identity: identity))
        XCTAssertEqual(try process.next().kind, .revoked)
        XCTAssertEqual(try process.next().kind, .initializationCancelled)
        let fd = try lockFile(root); defer { close(fd) }
        XCTAssertNotEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let work = job()
        try old.send(.generate, .init(kind: .generate, identity: work, text: "next"))
        XCTAssertEqual(try finish(old, identity: work), 3)
    }
    func testLoadCancellationAcknowledgesRevocationBeforeDrainButNeverReadyEarly() throws {
        let (root, process, identity) = try cold(["delay-load", "delay-load-drain"])
        try atLoad(process)
        try process.send(.cancel, .init(kind: .cancel, identity: identity))
        XCTAssertEqual(try process.next().kind, .revoked)
        XCTAssertThrowsError(try process.next(timeout: 0.1))
        let fd = try lockFile(root); defer { close(fd) }
        XCTAssertNotEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        try FileManager.default.removeItem(at: root.appendingPathComponent("delay-load-drain"))
        XCTAssertEqual(try process.next().kind, .unloaded)
        XCTAssertEqual(try process.next().kind, .initializationCancelled)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
    }
    func testEOFDuringLoadJoinsAndReleasesBeforeCancellationAcknowledgement() throws {
        let (root, process, _) = try cold(["delay-load"])
        try atLoad(process); try process.finishInput()
        XCTAssertEqual(try process.next().kind, .unloaded)
        XCTAssertEqual(try process.next().kind, .initializationCancelled)
        try process.close()
        let fd = try lockFile(root); defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
    }
    func testStaleLoadCancelCannotCancelInitializationOrNextJob() throws {
        let (root, process, _) = try cold(["delay-load"])
        try atLoad(process)
        try process.send(.cancel, .init(kind: .cancel, identity: job()))
        XCTAssertEqual(try process.next().kind, .ignored)
        try FileManager.default.removeItem(at: root.appendingPathComponent("delay-load"))
        XCTAssertEqual(try process.next().kind, .initialized)
        let work = job()
        try process.send(.generate, .init(kind: .generate, identity: work, text: "next"))
        XCTAssertEqual(try finish(process, identity: work), 3)
    }
    func testCancellationBeforeFirstLifecycleEventIsAcceptedAndNeverLoadsLate() throws {
        let (_, process, identity) = try cold(["delay-load"])
        try process.send(.cancel, .init(kind: .cancel, identity: identity))
        var revoked = false
        while true {
            let event = try process.next(timeout: 3)
            XCTAssertNotEqual(event.kind, .initialized)
            XCTAssertNotEqual(event.kind, .ready)
            if event.kind == .revoked { revoked = true }
            if event.kind == .initializationCancelled { break }
        }
        XCTAssertTrue(revoked)
    }
    func testPartialLoadAndResetFailureUnloadWithoutReadyOrReuse() throws {
        let (root, process, _) = try cold(["fail-load", "fail-reset"])
        try atLoad(process)
        XCTAssertEqual(try process.next().kind, .unloaded)
        XCTAssertEqual(try process.next().kind, .failure)
        try process.close()
        let fd = try lockFile(root); defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
    }
    func testGenerationResetFailureNeverReportsReadyAndRetainsLeaseUntilReap() throws {
        let (root, process) = try setupProbe(), identity = job()
        try Data().write(to: root.appendingPathComponent("fail-reset"))
        try process.send(.generate, .init(kind: .generate, identity: identity, text: "stall"))
        XCTAssertEqual(try process.next().kind, .started)
        try process.send(.cancel, .init(kind: .cancel, identity: identity))
        XCTAssertEqual(try process.next().kind, .revoked)
        XCTAssertEqual(try process.next().kind, .failure)
        let fd = try lockFile(root); defer { close(fd) }
        XCTAssertNotEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        try process.close()
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
    }
    func testConcurrentCloseCallersJoinSameHungLoaderReap() async throws {
        for _ in 0..<12 {
            let (root, process, _) = try cold(["stall-load"])
            try atLoad(process)
            async let first: Void = Task.detached { try process.close() }.value
            async let second: Void = Task.detached { try process.close() }.value
            _ = try await (first, second)
            XCTAssertEqual(kill(process.pid, 0), -1)
            let fd = try lockFile(root); defer { close(fd) }
            XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        }
    }
    func testDeinitAlsoObservesOwnedExitAndReapsHungLoader() throws {
        var owner: (URL, SpeechProbeProcess, AttemptIdentity)? = try cold(["stall-load"])
        let root = owner!.0, pid = owner!.1.pid
        try atLoad(owner!.1)
        weak var observed = owner!.1
        owner = nil
        // A currently executing weak timer callback may briefly retain its
        // owner; require bounded completion rather than a particular ARC thread.
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while kill(pid, 0) == 0 && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertNil(observed)
        XCTAssertEqual(kill(pid, 0), -1)
        let fd = try lockFile(root); defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
    }
    func testLoadedInitializationBarrierRetainsLeaseUntilCancellationJoinsUnload() throws {
        let (root, process, identity) = try cold([], holdLoaded: true)
        try atLoad(process)
        XCTAssertEqual(try process.next().kind, .loadedAwaitingAdmission)
        XCTAssertThrowsError(try process.next(timeout: 0.1))
        let fd = try lockFile(root); defer { close(fd) }
        XCTAssertNotEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        try process.send(.cancel, .init(kind: .cancel, identity: identity))
        XCTAssertEqual(try process.next().kind, .revoked)
        XCTAssertEqual(try process.next().kind, .unloaded)
        XCTAssertEqual(try process.next().kind, .initializationCancelled)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
    }
    func testLoadedInitializationBarrierEOFCleansBeforeTerminalAcknowledgement() throws {
        let (root, process, _) = try cold([], holdLoaded: true)
        try atLoad(process)
        XCTAssertEqual(try process.next().kind, .loadedAwaitingAdmission)
        try process.finishInput()
        XCTAssertEqual(try process.next().kind, .unloaded)
        XCTAssertEqual(try process.next().kind, .initializationCancelled)
        try process.close()
        let fd = try lockFile(root); defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
    }
    func testLoadedInitializationAdmissionAcknowledgementIsIdentityFenced() throws {
        let (_, process, identity) = try cold([], holdLoaded: true)
        try atLoad(process)
        XCTAssertEqual(try process.next().kind, .loadedAwaitingAdmission)
        try process.send(.acknowledge, .init(kind: .generate, identity: job(), chunk: 0))
        XCTAssertEqual(try process.next().kind, .ignored)
        XCTAssertThrowsError(try process.next(timeout: 0.1))
        try process.send(.acknowledge, .init(kind: .initialize, identity: identity, chunk: 0))
        XCTAssertEqual(try process.next().kind, .initialized)
        let work = job()
        try process.send(.generate, .init(kind: .generate, identity: work, text: "next"))
        XCTAssertEqual(try finish(process, identity: work), 3)
    }
    private func finish(_ process: SpeechProbeProcess, identity: AttemptIdentity) throws -> Int {
        var frames = 0, quiescent = false, completed = false
        while true {
            let event = try process.next(timeout: 3)
            XCTAssertEqual(event.identity, identity)
            switch event.kind {
            case .frame:
                XCTAssertEqual(event.frame?.chunk, frames); frames += 1
                try process.send(.acknowledge, .init(kind: .generate, identity: identity, chunk: event.frame?.chunk))
            case .quiescent: quiescent = true
            case .completed: XCTAssertTrue(quiescent); completed = true
            case .ready: XCTAssertTrue(completed); return frames
            case .started: break
            default: XCTFail("Unexpected \(event.kind)"); throw SpeechFailure(.protocolViolation)
            }
        }
    }
    func testCancellationJoinsResetsAndReusesSameWorkerForNextJob() throws {
        let (_, process) = try setupProbe(), first = job(), second = job()
        let pid = process.pid, worker = process.instance
        try process.send(.generate, .init(kind: .generate, identity: first, text: "stall"))
        XCTAssertEqual(try process.next().kind, .started)
        try process.send(.cancel, .init(kind: .cancel, identity: first))
        var events: [SpeechProbeEvent.Kind] = []
        while events.last != .ready { events.append(try process.next(timeout: 3).kind) }
        XCTAssertTrue(events.contains(.revoked)); XCTAssertTrue(events.contains(.quiescent))
        XCTAssertFalse(events.contains(.completed))
        try process.send(.generate, .init(kind: .generate, identity: second, text: "next"))
        XCTAssertEqual(try finish(process, identity: second), 3)
        // The final frame's acknowledgement belongs to the completed job;
        // it must settle before ready, not leak into the next request's events.
        let third = job()
        try process.send(.generate, .init(kind: .generate, identity: third, text: "after-completion"))
        XCTAssertEqual(try finish(process, identity: third), 3)
        XCTAssertEqual(process.pid, pid); XCTAssertEqual(process.instance, worker)
    }
    func testStalledConsumerDoesNotBlockCancellationAndOldAcknowledgeCannotCreditNewJob() throws {
        let (_, process) = try setupProbe(), first = job(), second = job()
        try process.send(.generate, .init(kind: .generate, identity: first, text: "frames"))
        XCTAssertEqual(try process.next().kind, .started)
        XCTAssertEqual(try process.next().kind, .frame)
        // No acknowledge: producer is blocked by the one-frame credit limit.
        try process.send(.cancel, .init(kind: .cancel, identity: first))
        var frames = 1, ready = false
        while !ready {
            let event = try process.next(timeout: 3)
            if event.kind == .frame { frames += 1 }
            ready = event.kind == .ready
        }
        XCTAssertEqual(frames, 1)
        try process.send(.generate, .init(kind: .generate, identity: second, text: "new"))
        XCTAssertEqual(try process.next().kind, .started)
        try process.send(.cancel, .init(kind: .cancel, identity: first))
        try process.send(.acknowledge, .init(kind: .generate, identity: first, chunk: 0))
        var ignored = 0, received = 0
        while true {
            let event = try process.next(timeout: 3)
            if event.kind == .ignored { ignored += 1 }
            if event.kind == .frame {
                received += 1
                try process.send(.acknowledge, .init(kind: .generate, identity: second, chunk: event.frame?.chunk))
            }
            if event.kind == .ready { break }
        }
        XCTAssertEqual(ignored, 2); XCTAssertEqual(received, 3)
    }
    func testResetMustFinishBeforeReadyAndLockRelease() throws {
        let (root, process) = try setupProbe(), identity = job()
        try Data().write(to: root.appendingPathComponent("delay-reset"))
        try process.send(.generate, .init(kind: .generate, identity: identity, text: "stall"))
        XCTAssertEqual(try process.next().kind, .started)
        try process.send(.cancel, .init(kind: .cancel, identity: identity))
        XCTAssertEqual(try process.next().kind, .revoked)
        XCTAssertThrowsError(try process.next(timeout: 0.1)) { XCTAssertEqual(($0 as? SpeechFailure)?.code, .timeout) }
        let fd = open(root.appendingPathComponent("fixture-inference.lock").path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        XCTAssertNotEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        try Data().write(to: root.appendingPathComponent("allow-reset"))
        XCTAssertEqual(try process.next().kind, .quiescent)
        XCTAssertEqual(try process.next().kind, .ready)
        try process.close()
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
    }
    func testEOFOrFallbackReapReleasesOnlyOwnedFixtureLock() throws {
        let (root, process) = try setupProbe(), identity = job()
        try Data().write(to: root.appendingPathComponent("delay-reset"))
        try process.send(.generate, .init(kind: .generate, identity: identity, text: "stall"))
        XCTAssertEqual(try process.next().kind, .started)
        // Deliberately hung reset exercises bounded owned-process fallback/reap.
        try process.close()
        let fd = open(root.appendingPathComponent("fixture-inference.lock").path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
    }
    func testReaderRejectsOversizedRecord() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 123, count: 70_000).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let reader = SpeechProbeReader(input: input)
        do { let _: SpeechProbeCommand? = try await reader.next(SpeechProbeCommand.self); XCTFail("Oversized record accepted") }
        catch { XCTAssertEqual((error as? SpeechFailure)?.code, .protocolViolation) }
    }

    func testInitializationFailureReturnsControlledCode() throws {
        guard let executable = ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"] else { throw XCTSkip("Build the fixture worker first.") }
        let process = try SpeechProbeProcess(configuration: .init(executable: URL(fileURLWithPath: executable), arguments: ["--handoff-probe"]))
        defer { try? process.close() }
        try process.send(.initialize, .init(kind: .initialize, identity: job()))
        let event = try process.next(timeout: 3)
        XCTAssertEqual(event.kind, .failure); XCTAssertEqual(event.failure, .invalidInput)
    }

    func testIncrementalModeIsBoundedCancellableAndReusesWorkerAfterStalledFrame() throws {
        let (_, process) = try setupProbe(), first = job(), second = job()
        try process.send(.generate, .init(kind: .generate, identity: first, text: "frames"), mode: .qwenIncremental)
        XCTAssertEqual(try process.next().kind, .started)
        XCTAssertEqual(try process.next().kind, .frame)
        try process.send(.cancel, .init(kind: .cancel, identity: first))
        while true {
            let event = try process.next(timeout: 3)
            XCTAssertNotEqual(event.kind, .frame)
            if event.kind == .ready { break }
        }
        try process.send(.generate, .init(kind: .generate, identity: second, text: "next"), mode: .qwenIncremental)
        XCTAssertEqual(try finish(process, identity: second), 12)
    }

    func testNewOwnerCannotAcquireBeforeOldOwnerReportsUnloaded() throws {
        let (root, old) = try setupProbe(), identity = job()
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"])
        let new = try SpeechProbeProcess(configuration: .init(executable: URL(fileURLWithPath: path), arguments: ["--handoff-probe"]))
        defer { try? new.close() }
        try old.send(.generate, .init(kind: .generate, identity: identity, text: "stall"))
        XCTAssertEqual(try old.next().kind, .started)
        try new.send(.initialize, .init(kind: .initialize, identity: job(), spoolDirectory: root))
        XCTAssertEqual(try new.next().kind, .waitingForLease)
        XCTAssertThrowsError(try new.next(timeout: 0.1)) { XCTAssertEqual(($0 as? SpeechFailure)?.code, .timeout) }
        try old.send(.cancel, .init(kind: .cancel, identity: identity))
        while try old.next().kind != .ready {}
        try old.finishInput()
        let unloaded = try old.next()
        XCTAssertEqual(unloaded.kind, .unloaded)
        let acquired = try new.next()
        XCTAssertEqual(acquired.kind, .leaseAcquired)
        XCTAssertGreaterThanOrEqual(acquired.time, unloaded.time)
        XCTAssertEqual(try new.next().kind, .loadingModel)
        XCTAssertEqual(try new.next().kind, .initialized)
        try old.close()
    }
}
