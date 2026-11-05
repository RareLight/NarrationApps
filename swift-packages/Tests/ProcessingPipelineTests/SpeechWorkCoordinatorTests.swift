import XCTest
import Foundation
import Darwin
import NarrationCore
import NativeSpeech
@testable import ProcessingPipeline

final class SpeechWorkCoordinatorTests: XCTestCase, @unchecked Sendable {
    private func fixture(_ owner: SpeechWorkOwner = .voiceRelay, shared: URL? = nil, environment: [String: String] = [:],
                         grace: Duration = .seconds(5)) throws -> (URL, SpeechWorkCoordinator) {
        let executable = try XCTUnwrap(ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"])
        let base = shared ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("coordinator-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let config = WorkerConfiguration(executable: URL(fileURLWithPath: executable), arguments: ["--handoff-probe"],
            environment: environment, shutdownGrace: 0.1, terminationGrace: 0.1, inferenceLeaseFile: base.appendingPathComponent("inference.lock"))
        let coordinator = try SpeechWorkCoordinator(owner: owner, configuration: config, root: base.appendingPathComponent("admission"), cancellationGrace: grace)
        addTeardownBlock { await coordinator.close(); if shared == nil { try? FileManager.default.removeItem(at: base) } }
        return (base, coordinator)
    }
    private func job(_ coordinator: SpeechWorkCoordinator, _ base: URL, rank: SpeechWorkRank = .podcast,
                     delivery: SpeechWorkDelivery = .file, eligible: @escaping @Sendable () -> Bool = { true }) async throws -> SpeechWorkJob {
        try await coordinator.openJob(identity: .init(batch: UUID(), job: UUID()), settings: .init(model: .soprano),
            workspace: base, rank: rank, delivery: delivery, eligible: eligible)
    }
    private func utterance(_ job: SpeechWorkJob, _ text: String = "A synthetic sentence.") -> PreparedUtterance {
        .init(text: text, phonemes: nil, tokenCount: 0, source: .init(blockIndices: [0], location: 0, length: text.utf16.count),
            boundaryAfter: .sentence, acousticIdentity: SpeechAcousticIdentity.make(settings: job.settings, policy: .nativeText))
    }
    private func generate(_ c: SpeechWorkCoordinator, _ j: SpeechWorkJob) async throws -> SpeechUnitResult {
        try await c.perform(.generate(utterance(j), .nativeText), job: j)
    }
    private func wait(_ predicate: @escaping () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while try await !predicate() {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out waiting for lifecycle barrier"); throw SpeechFailure(.timeout) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func hold(_ c: SpeechWorkCoordinator) async throws -> URL {
        let observation = await c.observation()
        let stage = try XCTUnwrap(observation.stage)
        try? FileManager.default.removeItem(at: stage.appendingPathComponent("generation-started"))
        try Data().write(to: stage.appendingPathComponent("hold-generation"))
        return stage
    }
    func testInitializeOnlyVerifiesResidencyWithoutGeneratingSpeech() async throws {
        let (base, c) = try fixture(), j = try await job(c, base)
        let result = try await c.perform(.initialize, job: j)
        guard case .initialized = result.value else { return XCTFail("Expected initialization only") }
        let observation = await c.observation()
        XCTAssertNotNil(observation.pid); XCTAssertTrue(observation.leaseAcquired)
        let stage = try XCTUnwrap(observation.stage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.appendingPathComponent("generation-started").path))
        XCTAssertEqual(j.fence.verifiedPrefix, 0)
    }
    func testCoordinatedSetupActuallyWaitsForModelInitializationAndReaps() async throws {
        let (base, c) = try fixture(environment: ["NARRATION_FIXTURE_LOAD_BARRIER": "1"])
        var configuration = WorkerConfiguration(executable: URL(fileURLWithPath: "/unused/setup-worker"))
        configuration.workCoordinator = c
        let captured = configuration
        let check = Task { try await SpeechSetupCheck.run(configuration: captured, workspace: base, settings: .init(model: .soprano)) }
        try await wait { await c.observation().leaseAcquired }
        let observation = await c.observation(), stage = try XCTUnwrap(observation.stage), pid = try XCTUnwrap(observation.pid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.appendingPathComponent("delay-load").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.appendingPathComponent("generation-started").path))
        try FileManager.default.removeItem(at: stage.appendingPathComponent("delay-load"))
        try await check.value
        let after = await c.observation()
        XCTAssertNil(after.pid); XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH)
    }
    func testHostPlatformWorkBlocksHelperInitializationUntilActualLeaseRelease() async throws {
        let (base, c) = try fixture()
        var lease: InferenceLease? = try await c.hostAdmission.withContext { try await InferenceLease.acquire() }
        let api = try await job(c, base, rank: .api, delivery: .streaming)
        let initialize = Task { try await c.perform(.initialize, job: api) }
        try await wait { await c.observation().loading }
        let before = await c.observation()
        XCTAssertFalse(before.leaseAcquired)
        lease = nil; withExtendedLifetime(lease) {}
        _ = try await initialize.value
        let after = await c.observation()
        XCTAssertTrue(after.leaseAcquired)
    }
    func testPreparationAndPCMUseSameResidentWorkerAndCommitOnce() async throws {
        let (base, c) = try fixture(), j = try await job(c, base)
        let text = "Exact synthetic source."
        let window = SpeechTextWindow(text: text, source: .init(blockIndices: [3], location: 7, length: text.utf16.count), boundaryAfter: .paragraph)
        let prepared = try await c.perform(.prepare(window, .nativeText), job: j)
        guard case .prepared(let values) = prepared.value else { return XCTFail("Expected prepared text") }
        XCTAssertEqual(values.map(\.text), [text]); XCTAssertEqual(values[0].source, window.source)
        let pid = await c.observation().pid
        let pcm = try await c.perform(.generate(values[0], .nativeText), job: j)
        guard case .audio(let samples) = pcm.value else { return XCTFail("Expected PCM") }
        XCTAssertEqual(samples, [0, 0.1, -0.1, 0])
        let after = await c.observation()
        XCTAssertEqual(after.pid, pid)
        var committed = 0
        XCTAssertTrue(try j.commit(pcm, index: 0) { committed += 1 })
        XCTAssertFalse(try j.commit(pcm, index: 0) { committed += 1 })
        XCTAssertEqual(committed, 1)
    }
    func testAllFrontendsDeferSpeechWeightsAndPromoteTheSameHelper() async throws {
        for model in SpeechModel.allCases {
            let (base, c) = try fixture()
            let settings = SpeechSettings(model: model, voice: model.defaultVoice)
            let j = try await c.openJob(identity: .init(batch: UUID(), job: UUID()), settings: settings, workspace: base, rank: .podcast)
            let policy = SpeechPreparationPolicy.selected(settings: settings, requested: .current)
            let text = "A complete synthetic preparation window."
            let window = SpeechTextWindow(text: text, source: .init(blockIndices: [0], location: 0, length: text.utf16.count), boundaryAfter: .paragraph)
            let prepared = try await c.perform(.prepare(window, policy), job: j)
            guard case .prepared(let utterances) = prepared.value else { return XCTFail("Expected frontend preparation") }
            let before = await c.observation(), stage = try XCTUnwrap(before.stage)
            XCTAssertTrue(FileManager.default.fileExists(atPath: stage.appendingPathComponent("frontend-initialized").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: stage.appendingPathComponent("speech-loaded").path))
            XCTAssertEqual(before.leaseAcquired, model == .kokoro)
            let audio = try await c.perform(.generate(try XCTUnwrap(utterances.first), policy), job: j)
            guard case .audio(let pcm) = audio.value else { return XCTFail("Expected promoted speech") }
            XCTAssertEqual(pcm, [0, 0.1, -0.1, 0])
            let after = await c.observation()
            XCTAssertEqual(after.pid, before.pid); XCTAssertTrue(after.leaseAcquired)
            XCTAssertTrue(FileManager.default.fileExists(atPath: stage.appendingPathComponent("speech-loaded").path))
            await c.closeJob(j); await c.close()
        }
    }
    func testCPUFrontendPreparesBehindCompatibilityLeaseButPromotionWaitsForIt() async throws {
        let (base, c) = try fixture(), j = try await job(c, base)
        var lease: InferenceLease? = try await InferenceLease.acquire(at: base.appendingPathComponent("inference.lock"))
        let text = "CPU tokenizer work does not require speech weights."
        let window = SpeechTextWindow(text: text, source: .init(blockIndices: [0], location: 0, length: text.utf16.count), boundaryAfter: .paragraph)
        _ = try await c.perform(.prepare(window, .nativeText), job: j)
        let before = await c.observation(), stage = try XCTUnwrap(before.stage)
        XCTAssertFalse(before.leaseAcquired)
        let promotion = Task { try await c.perform(.initialize, job: j) }
        do {
            try await wait { FileManager.default.fileExists(atPath: stage.appendingPathComponent("promotion-started").path) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: stage.appendingPathComponent("speech-loaded").path))
            lease = nil
            let initialized = try await promotion.value
            guard case .initialized = initialized.value else { return XCTFail("Expected explicit readiness") }
            let after = await c.observation()
            XCTAssertEqual(after.pid, before.pid); XCTAssertTrue(after.leaseAcquired)
        } catch { lease = nil; promotion.cancel(); _ = await promotion.result; throw error }
        withExtendedLifetime(lease) {}
    }
    func testCompatibleLiveDemandTakesOverFrontendPromotionBeforeLowerSpeech() async throws {
        let (base, c) = try fixture(), lower = try await job(c, base)
        let text = "A synthetic sentence."
        let window = SpeechTextWindow(text: text, source: .init(blockIndices: [0], location: 0, length: text.utf16.count), boundaryAfter: .paragraph)
        _ = try await c.perform(.prepare(window, .nativeText), job: lower)
        let before = await c.observation(), stage = try XCTUnwrap(before.stage)
        try FileManager.default.removeItem(at: stage.appendingPathComponent("generation-started"))
        let delay = stage.appendingPathComponent("delay-promotion")
        try Data().write(to: delay)
        let background = Task { try await self.generate(c, lower) }
        addTeardownBlock { background.cancel(); _ = await background.result }
        do {
            try await wait { await c.observation().leaseAcquired }
            let api = try await job(c, base, rank: .api, delivery: .streaming)
            try FileManager.default.removeItem(at: delay)
            _ = try await generate(c, api)
            let live = await c.observation()
            XCTAssertEqual(live.pid, before.pid)
            XCTAssertEqual(try String(contentsOf: stage.appendingPathComponent("generation-started"), encoding: .utf8), api.identity.job.uuidString)
            await c.closeJob(api)
            _ = try await background.value
            let resumed = await c.observation(); XCTAssertEqual(resumed.pid, before.pid)
        } catch { try? FileManager.default.removeItem(at: delay); background.cancel(); _ = await background.result; throw error }
    }
    func testStreamingPreemptionRetriesInsideOperationAndPreservesWarmWorker() async throws {
        let (base, c) = try fixture(), podcast = try await job(c, base)
        let initial = try await generate(c, podcast)
        XCTAssertTrue(try podcast.commit(initial, index: 0) {})
        let pid = await c.observation().pid, stage = try await hold(c)
        let lower = Task { try await self.generate(c, podcast) }
        try await wait { FileManager.default.fileExists(atPath: stage.appendingPathComponent("generation-started").path) }
        let api = try await job(c, base, rank: .api, delivery: .streaming)
        try await wait { FileManager.default.fileExists(atPath: stage.appendingPathComponent("generation-cancelled").path) }
        try FileManager.default.removeItem(at: stage.appendingPathComponent("hold-generation"))
        let response = try await generate(c, api)
        XCTAssertTrue(try api.commit(response, index: 0) {})
        let duringAPI = await c.observation()
        XCTAssertEqual(duringAPI.pid, pid)
        await c.closeJob(api)
        let resumed = try await lower.value
        XCTAssertGreaterThan(resumed.token.epoch, initial.token.epoch)
        XCTAssertTrue(try podcast.commit(resumed, index: 1) {})
        XCTAssertEqual(podcast.fence.verifiedPrefix, 2)
        let afterResume = await c.observation()
        XCTAssertEqual(afterResume.pid, pid)
    }
    func testLateValidationIsRejectedEvenBeforeObserverRevokesEpoch() async throws {
        let (base, c) = try fixture(), lower = try await job(c, base)
        let result = try await generate(c, lower)
        let api = try await job(c, base, rank: .api, delivery: .streaming)
        var published = false
        XCTAssertFalse(try lower.commit(result, index: 0) { published = true })
        XCTAssertFalse(published); XCTAssertEqual(lower.fence.verifiedPrefix, 0)
        await c.closeJob(api)
        let retry = try await generate(c, lower)
        XCTAssertTrue(try lower.commit(retry, index: 0) {})
    }
    func testCompleteFileYieldsAtBoundaryWithoutCancellingCurrentUnit() async throws {
        let (base, c) = try fixture(), lower = try await job(c, base)
        lower.discardResult(try await generate(c, lower))
        let stage = try await hold(c)
        let unit = Task { try await self.generate(c, lower) }
        try await wait { FileManager.default.fileExists(atPath: stage.appendingPathComponent("generation-started").path) }
        let api = try await job(c, base, rank: .api, delivery: .file)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.appendingPathComponent("generation-cancelled").path))
        try FileManager.default.removeItem(at: stage.appendingPathComponent("hold-generation"))
        let completed = try await unit.value
        XCTAssertTrue(try lower.commit(completed, index: 0) {})
        let response = try await generate(c, api)
        XCTAssertTrue(try api.commit(response, index: 0) {})
    }
    func testCrossAppIdleResidencyUnloadsBeforeOtherOwnerCanLoad() async throws {
        let (base, libro) = try fixture(.libro)
        let (_, relay) = try fixture(.voiceRelay, shared: base)
        let book = try await job(libro, base, rank: .libro)
        book.discardResult(try await generate(libro, book))
        let before = await libro.observation()
        let oldPID = try XCTUnwrap(before.pid)
        let api = try await job(relay, base, rank: .api, delivery: .streaming)
        api.discardResult(try await generate(relay, api))
        XCTAssertEqual(kill(oldPID, 0), -1)
        let unloaded = await libro.observation()
        XCTAssertNil(unloaded.pid)
        await relay.closeJob(api)
        book.discardResult(try await generate(libro, book))
        let resumed = await libro.observation()
        XCTAssertNotEqual(resumed.pid, oldPID)
    }
    func testManualPauseWithdrawsDemandAndStopCannotResume() async throws {
        let (base, c) = try fixture(.libro)
        let flag = Flag()
        let book = try await job(c, base, rank: .libro, eligible: { flag.enabled })
        book.discardResult(try await generate(c, book))
        flag.enabled = false
        let registry = try SpeechWorkAdmission(root: base.appendingPathComponent("admission"))
        try await wait { try registry.highest() == nil }
        let suspended = Task { try await self.generate(c, book) }
        await c.closeJob(book)
        flag.enabled = true
        do { _ = try await suspended.value; XCTFail("Stopped job resumed") } catch {}
        XCTAssertNil(try registry.highest())
    }
    func testCancellationReapsOwnedWorkerAndNeverReturnsAudio() async throws {
        let (base, c) = try fixture(), j = try await job(c, base)
        j.discardResult(try await generate(c, j))
        let stage = try await hold(c), observation = await c.observation()
        let pid = try XCTUnwrap(observation.pid)
        let task = Task { try await self.generate(c, j) }
        try await wait { FileManager.default.fileExists(atPath: stage.appendingPathComponent("generation-started").path) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled operation returned audio") } catch {}
        await c.closeJob(j)
        XCTAssertEqual(kill(pid, 0), -1)
    }
    func testQueuedAPIRequestsRemainFIFOWithoutTruncatingFirstResponse() async throws {
        let (base, c) = try fixture(), first = try await job(c, base, rank: .api, delivery: .file)
        first.discardResult(try await generate(c, first))
        let stage = try await hold(c)
        let responseA = Task { try await self.generate(c, first) }
        defer { responseA.cancel() }
        try await wait { FileManager.default.fileExists(atPath: stage.appendingPathComponent("generation-started").path) }
        let second = try await job(c, base, rank: .api, delivery: .streaming)
        let responseB = Task { try await self.generate(c, second) }
        defer { responseB.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        let active = await c.observation()
        XCTAssertEqual(active.active, first.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.appendingPathComponent("generation-cancelled").path))
        try FileManager.default.removeItem(at: stage.appendingPathComponent("hold-generation"))
        first.discardResult(try await responseA.value)
        let stillFirst = await c.observation()
        XCTAssertNotEqual(stillFirst.active, second.id)
        await c.closeJob(first)
        second.discardResult(try await responseB.value)
    }
    func testCompatibleSameAppDemandTransfersInitializationWithoutReload() async throws {
        let (base, c) = try fixture(environment: ["NARRATION_FIXTURE_LOAD_BARRIER": "1"])
        let lower = try await job(c, base)
        let background = Task { try await self.generate(c, lower) }
        defer { background.cancel() }
        try await wait {
            let state = await c.observation()
            return state.loading && state.leaseAcquired && state.stage.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("delay-load").path) } == true
        }
        let loading = await c.observation(), stage = try XCTUnwrap(loading.stage)
        let api = try await job(c, base, rank: .api, delivery: .streaming)
        try await Task.sleep(for: .milliseconds(150))
        let transferred = await c.observation()
        XCTAssertEqual(transferred.pid, loading.pid)
        XCTAssertTrue(transferred.loading)
        try FileManager.default.removeItem(at: stage.appendingPathComponent("delay-load"))
        api.discardResult(try await generate(c, api))
        let ready = await c.observation()
        XCTAssertEqual(ready.pid, loading.pid)
        await c.closeJob(api)
        lower.discardResult(try await background.value)
    }
    func testHungGenerationIsReapedBeforeReplacementAcquiresResidency() async throws {
        let (base, c) = try fixture(grace: .milliseconds(50)), lower = try await job(c, base)
        lower.discardResult(try await generate(c, lower))
        let old = await c.observation(), stage = try XCTUnwrap(old.stage), pid = try XCTUnwrap(old.pid)
        try FileManager.default.removeItem(at: stage.appendingPathComponent("generation-started"))
        try Data().write(to: stage.appendingPathComponent("stall-generation"))
        let hung = Task { try await self.generate(c, lower) }
        defer { hung.cancel() }
        try await wait { FileManager.default.fileExists(atPath: stage.appendingPathComponent("generation-started").path) }
        let api = try await job(c, base, rank: .api, delivery: .streaming)
        api.discardResult(try await generate(c, api))
        XCTAssertEqual(kill(pid, 0), -1)
        let replacement = await c.observation()
        XCTAssertNotEqual(replacement.pid, pid)
        await c.closeJob(lower)
        do { _ = try await hung.value; XCTFail("Stopped job resumed after reap") } catch {}
    }
    func testCancellationDuringResetIgnoresLateControlWithoutRetiringWarmWorker() async throws {
        let (base, c) = try fixture(), lower = try await job(c, base)
        let first = try await generate(c, lower)
        XCTAssertTrue(try lower.commit(first, index: 0) {})
        let before = await c.observation(), stage = try XCTUnwrap(before.stage)
        try FileManager.default.removeItem(at: stage.appendingPathComponent("reset-started"))
        try Data().write(to: stage.appendingPathComponent("delay-reset"))
        let unfinished = Task { try await self.generate(c, lower) }
        defer { unfinished.cancel() }
        try await wait { FileManager.default.fileExists(atPath: stage.appendingPathComponent("reset-started").path) }
        let api = try await job(c, base, rank: .api, delivery: .streaming)
        try await wait { await c.observation().cancelled }
        try Data().write(to: stage.appendingPathComponent("allow-reset"))
        api.discardResult(try await generate(c, api))
        await c.closeJob(api)
        let resumed = try await unfinished.value
        XCTAssertTrue(try lower.commit(resumed, index: 1) {})
        let after = await c.observation()
        XCTAssertEqual(after.pid, before.pid)
        XCTAssertGreaterThan(resumed.token.epoch, first.token.epoch)
    }
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true
        var enabled: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    }
    private final class MaintenanceGate: @unchecked Sendable {
        let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var entered = false, cancelled = false, ended = false, released = false
        var state: (entered: Bool, cancelled: Bool, ended: Bool) { lock.withLock { (entered, cancelled, ended) } }
        func run() async throws {
            defer { lock.withLock { ended = true } }
            await withTaskCancellationHandler {
                await withCheckedContinuation { value in
                    lock.withLock { entered = true; if released { value.resume() } else { continuation = value } }
                }
            } onCancel: { self.lock.withLock { self.cancelled = true } }
            try Task.checkCancellation()
        }
        func release() {
            let old = lock.withLock { released = true; let old = continuation; continuation = nil; return old }
            old?.resume()
        }
    }
    func testMaintenanceFencesPendingCheckpointReapsAndResumesCapturedJob() async throws {
        let (base, c) = try fixture(), lower = try await job(c, base)
        let committed = try await generate(c, lower)
        XCTAssertTrue(try lower.commit(committed, index: 0) {})
        let pending = try await generate(c, lower), observedPID = await c.residentProcessIdentifier
        let pid = try XCTUnwrap(observedPID)
        let gate = MaintenanceGate(); addTeardownBlock { gate.release() }
        let maintenance = Task { try await c.withMaintenance { try await gate.run() } }
        try await wait { gate.state.entered }
        XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH)
        XCTAssertFalse(try lower.commit(pending, index: 1) { XCTFail("Maintenance admitted an old checkpoint") })
        XCTAssertEqual(lower.fence.verifiedPrefix, 1)
        do { _ = try await job(c, base, rank: .api); XCTFail("Maintenance accepted API") }
        catch SpeechWorkAvailability.maintenance {}
        let resumed = Task { try await self.generate(c, lower) }
        gate.release(); try await maintenance.value
        let next = try await resumed.value
        XCTAssertGreaterThan(next.token.epoch, pending.token.epoch)
        XCTAssertTrue(try lower.commit(next, index: 1) {}); XCTAssertEqual(lower.fence.verifiedPrefix, 2)
    }
    func testMaintenanceCancelsActiveAPIBeforeInvokingOperation() async throws {
        let (base, c) = try fixture(), api = try await job(c, base, rank: .api, delivery: .streaming)
        _ = try await c.perform(.initialize, job: api)
        let observedPID = await c.residentProcessIdentifier
        let pid = try XCTUnwrap(observedPID), stage = try await hold(c)
        let active = Task { try await self.generate(c, api) }
        try await wait { FileManager.default.fileExists(atPath: stage.appendingPathComponent("generation-started").path) }
        try await c.withMaintenance {
            XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH)
        }
        do { _ = try await active.value; XCTFail("Maintenance completed interrupted API") } catch {}
        do { _ = try await generate(c, api); XCTFail("Maintenance replayed API") } catch is CancellationError {}
        await c.closeJob(api)
        let fresh = try await job(c, base, rank: .api)
        fresh.discardResult(try await generate(c, fresh))
    }
    func testQuitCancelsAndJoinsMaintenanceWithoutReopeningOwner() async throws {
        let (base, c) = try fixture(), gate = MaintenanceGate()
        addTeardownBlock { gate.release() }
        let work = Task { try await c.withMaintenance { try await gate.run() } }
        try await wait { gate.state.entered }
        let close = Task { await c.close() }
        try await wait { gate.state.cancelled }
        XCTAssertFalse(gate.state.ended)
        gate.release(); await close.value
        do { try await work.value; XCTFail("Quit maintenance did not cancel") } catch is CancellationError {}
        XCTAssertTrue(gate.state.ended)
        do { _ = try await job(c, base); XCTFail("Quit reopened owner") } catch {}
    }
    func testInstallerUsesMaintenanceAndFailureReopensNormalAdmission() async throws {
        let (base, c) = try fixture(), lower = try await job(c, base)
        _ = try await c.perform(.initialize, job: lower)
        let oldPID = await c.residentProcessIdentifier
        let trace = base.appendingPathComponent("installer-trace")
        try FileManager.default.createDirectory(at: trace, withIntermediateDirectories: true)
        var installer = WorkerConfiguration(executable: URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"])),
            environment: ["NARRATION_FIXTURE_TRACE": trace.path], shutdownGrace: 0.1, terminationGrace: 0.1)
        installer.workCoordinator = c
        try await ModelPreparation.run(configuration: installer, workspace: base, settings: lower.settings) { _ in
            if let oldPID { XCTAssertEqual(kill(oldPID, 0), -1); XCTAssertEqual(errno, ESRCH) }
        }
        let files = try FileManager.default.contentsOfDirectory(at: trace, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let events = try String(contentsOf: XCTUnwrap(files.first), encoding: .utf8)
        XCTAssertTrue(events.contains("prepare")); XCTAssertTrue(events.contains("exit"))
        installer.environment["NARRATION_FIXTURE_MODE"] = "assetInvalid"
        do { try await ModelPreparation.run(configuration: installer, workspace: base, settings: lower.settings); XCTFail("Invalid asset progress accepted") } catch {}
        let resumed = try await generate(c, lower)
        XCTAssertTrue(try lower.commit(resumed, index: 0) {})
        await c.closeJob(lower)
    }
}
