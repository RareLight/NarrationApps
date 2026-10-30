import XCTest
@testable import NarrationCore
@testable import ProcessingPipeline

@MainActor
final class SpeechSetupValidationTests: XCTestCase {
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var inspectCalls: [SpeechSetupValidation.Target] = []
        private var checkCalls: [SpeechSetupValidation.Target] = []
        private var active = 0
        var maxActive = 0
        var inspectResult: Result<Bool, Error> = .success(true)
        var checkResult: Result<Void, Error> = .success(())
        var holdChecks: Bool {
            get { lock.withLock { held } }
            set { lock.withLock { held = newValue } }
        }
        private var held = false
        private let gate = DispatchSemaphore(value: 0)
        var inspectCount: Int { lock.withLock { inspectCalls.count } }
        var checkCount: Int { lock.withLock { checkCalls.count } }
        var checks: [SpeechSetupValidation.Target] { lock.withLock { checkCalls } }
        func inspect(_ target: SpeechSetupValidation.Target) async throws -> Bool {
            lock.withLock { inspectCalls.append(target) }
            return try inspectResult.get()
        }
        func check(_ target: SpeechSetupValidation.Target) async throws {
            let count = lock.withLock { () -> Int in
                checkCalls.append(target); active += 1
                maxActive = max(maxActive, active)
                return active
            }
            _ = count
            defer { lock.withLock { active -= 1 } }
            if holdChecks { await Task.detached { self.blockOnGate() }.value }
            try checkResult.get()
        }
        private func blockOnGate() { gate.wait() }
        func release() { lock.withLock { held = false }; gate.signal() }
    }
    private func target(_ model: SpeechModel = .qwen3, voice: String = "Ryan", root: String = "/tmp/v-\(UUID().uuidString)",
                        language: String? = nil, revision: Int = 0) -> SpeechSetupValidation.Target {
        .init(root: URL(fileURLWithPath: root), settings: .init(model: model, voice: voice, language: language), revision: revision)
    }
    private func validator(_ probe: Probe) -> SpeechSetupValidation {
        SpeechSetupValidation(inspect: probe.inspect, check: probe.check)
    }
    private func waitFor(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    func testSuccessfulCheckRunsOnceForSameTarget() async throws {
        let probe = Probe(), validation = validator(probe)
        let t = target()
        validation.update(target: t, permitted: true)
        validation.update(target: t, permitted: true)
        let ready = await waitFor { validation.result == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(probe.inspectCount, 1); XCTAssertEqual(probe.checkCount, 1)
        XCTAssertEqual(validation.target, t)
        XCTAssertFalse(validation.hasOwnedWork)
        validation.update(target: t, permitted: true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(probe.checkCount, 1)
    }

    func testModelVoiceLanguageRootAndRevisionChangesRecheck() async throws {
        let probe = Probe(), validation = validator(probe)
        var t = target()
        validation.update(target: t, permitted: true)
        let ready = await waitFor { validation.result == .ready }
        XCTAssertTrue(ready)
        for next in [target(.chatterbox), target(.qwen3, voice: "Other"), target(language: "German"),
                     target(root: "/tmp/other-\(UUID().uuidString)"), target(revision: 1)] {
            t = next
            validation.update(target: t, permitted: true)
            let settled = await waitFor { validation.result == .ready && validation.target == t }
        XCTAssertTrue(settled)
        }
        XCTAssertEqual(probe.checkCount, 6)
    }

    func testSpeedAndDeliveryChangesDoNotRecheck() async throws {
        let probe = Probe(), validation = validator(probe)
        let t = target()
        validation.update(target: t, permitted: true)
        let ready = await waitFor { validation.result == .ready }
        XCTAssertTrue(ready)
        var settings = t.settings
        settings.speed = 1.4; settings.styleInstruction = "calm"
        settings.savedChoices = [:]
        settings.retainReview = true; settings.seed = 7; settings.expandSpokenForms = true
        let same = SpeechSetupValidation.Target(root: t.root, settings: settings, revision: t.revision)
        validation.update(target: same, permitted: true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(probe.checkCount, 1)
    }

    func testMissingInventorySkipsCheckWithoutCreatingRoot() async throws {
        let probe = Probe(); probe.inspectResult = .success(false)
        let validation = validator(probe)
        validation.update(target: target(), permitted: true)
        let missing = await waitFor { validation.result == .notInstalled }
        XCTAssertTrue(missing)
        XCTAssertEqual(probe.checkCount, 0)
    }

    func testCheckFailureBecomesRepairAndNeverRetries() async throws {
        let probe = Probe()
        struct Fake: Error {}
        probe.checkResult = .failure(Fake())
        let validation = validator(probe)
        let t = target()
        validation.update(target: t, permitted: true)
        let failed = await waitFor { if case .failure = validation.result { return true }; return false }
        XCTAssertTrue(failed)
        for _ in 0..<3 { validation.update(target: t, permitted: true) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(probe.checkCount, 1)
    }

    func testInspectErrorIsFailureNotReady() async throws {
        let probe = Probe()
        struct Fake: Error {}
        probe.inspectResult = .failure(Fake())
        let validation = validator(probe)
        validation.update(target: target(), permitted: true)
        let failed = await waitFor { if case .failure = validation.result { return true }; return false }
        XCTAssertTrue(failed)
        XCTAssertEqual(probe.checkCount, 0)
    }

    func testForbiddenTargetIsDeferredAndResumes() async throws {
        let probe = Probe(), validation = validator(probe)
        let t = target()
        validation.update(target: t, permitted: false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(probe.checkCount, 0)
        validation.update(target: t, permitted: true)
        let ready = await waitFor { validation.result == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(probe.checkCount, 1)
    }

    func testTargetChangeCancelsOldWorkAndWaitsForJoin() async throws {
        let probe = Probe(); probe.holdChecks = true
        let validation = validator(probe)
        let first = target(), second = target(.orpheus)
        validation.update(target: first, permitted: true)
        let started = await waitFor { probe.checkCount == 1 }
        XCTAssertTrue(started)
        validation.update(target: second, permitted: true)
        probe.release()
        let secondReady = await waitFor { validation.result == .ready && validation.target == second }
        XCTAssertTrue(secondReady)
        XCTAssertEqual(probe.maxActive, 1)
        XCTAssertEqual(probe.checks.last, second)
        if case .failure = validation.result { XCTFail("stale failure stamped") }
    }

    func testABThenAResultsFromOldCheckCannotStamp() async throws {
        let probe = Probe(); probe.holdChecks = true
        let validation = validator(probe)
        let a = target(), b = target(.chatterbox)
        validation.update(target: a, permitted: true)
        let started = await waitFor { probe.checkCount == 1 }
        XCTAssertTrue(started)
        validation.update(target: b, permitted: true)
        validation.update(target: a, permitted: true)
        probe.release()
        let aReady = await waitFor { validation.result == .ready && validation.target == a }
        XCTAssertTrue(aReady)
        XCTAssertEqual(probe.maxActive, 1)
    }

    func testCompletedAThenHeldBThenARestartsAndFinishesReady() async throws {
        let probe = Probe(), validation = validator(probe)
        let a = target(), b = target(.chatterbox)
        validation.update(target: a, permitted: true)
        let aReady = await waitFor { validation.result == .ready }
        XCTAssertTrue(aReady)
        probe.holdChecks = true
        validation.update(target: b, permitted: true)
        let bStarted = await waitFor { probe.checkCount == 2 }
        XCTAssertTrue(bStarted)
        validation.update(target: a, permitted: true)
        probe.release()
        let aDone = await waitFor { validation.result == .ready && validation.target == a }
        XCTAssertTrue(aDone)
        XCTAssertEqual(probe.maxActive, 1)
        XCTAssertEqual(probe.checks.last, a)
        XCTAssertEqual(probe.checkCount, 3)
    }

    func testDefaultInspectReportsMissingWithoutCreatingRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("v-real-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = Probe()
        let validation = SpeechSetupValidation(inspect: SpeechSetupValidation.defaultInspect, check: probe.check)
        validation.update(target: .init(root: root, settings: .init(model: .qwen3, voice: "Ryan"), revision: 0), permitted: true)
        let missing = await waitFor { validation.result == .notInstalled }
        XCTAssertTrue(missing)
        XCTAssertEqual(probe.checkCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRecordAdoptsInstallResultWithoutRedundantCheck() async throws {
        let probe = Probe(), validation = validator(probe)
        let t = target()
        validation.update(target: t, permitted: false)
        validation.record(.ready, for: t)
        XCTAssertEqual(validation.result, .ready)
        validation.update(target: t, permitted: true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(probe.checkCount, 0)
    }

    func testStaleRecordCannotStampNewTarget() async throws {
        let probe = Probe(), validation = validator(probe)
        let old = target(), next = target(.chatterbox)
        validation.update(target: next, permitted: true)
        validation.record(.ready, for: old)
        XCTAssertNotEqual(validation.result, .ready)
        let ready = await waitFor { validation.result == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(probe.checks, [next])
    }

    func testExternalCancellationIsNeutralTerminalAndDoesNotRetry() async throws {
        let probe = Probe(); probe.checkResult = .failure(CancellationError())
        let validation = validator(probe)
        let t = target()
        validation.update(target: t, permitted: true)
        let idle = await waitFor { validation.result == .idle && probe.checkCount == 1 }
        XCTAssertTrue(idle)
        for _ in 0..<3 { validation.update(target: t, permitted: true) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(probe.checkCount, 1)
        XCTAssertFalse(validation.hasOwnedWork)
    }

    func testStopAndWaitJoinsAndPreventsResurrection() async throws {
        let probe = Probe(); probe.holdChecks = true
        let validation = validator(probe)
        validation.update(target: target(), permitted: true)
        let owned = await waitFor { probe.checkCount == 1 }
        XCTAssertTrue(owned)
        var waiterStarted = false, waiterDone = false
        let waiter = Task { @MainActor in
            waiterStarted = true
            await validation.waitForIdle()
            waiterDone = true
        }
        let joined = Task { @MainActor in await validation.stopAndWait() }
        let stopping = await waitFor { waiterStarted && validation.result == .idle }
        XCTAssertTrue(stopping)
        XCTAssertTrue(validation.hasOwnedWork)
        XCTAssertFalse(waiterDone)
        probe.release()
        await joined.value
        await waiter.value
        XCTAssertTrue(waiterDone)
        XCTAssertFalse(validation.hasOwnedWork)
        validation.update(target: target(.orpheus), permitted: true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(probe.checkCount, 1)
    }
}
