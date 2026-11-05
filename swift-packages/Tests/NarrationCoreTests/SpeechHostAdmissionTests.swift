import XCTest
import Foundation
@testable import NarrationCore

final class SpeechHostAdmissionTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> (URL, SpeechWorkAdmission) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("host-admission-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, try SpeechWorkAdmission(root: root.appendingPathComponent("admission")))
    }
    private func wait(_ predicate: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try !predicate() {
            guard ContinuousClock.now < deadline else { XCTFail("Host admission barrier timed out"); throw SpeechFailure(.timeout) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private final class Flag: @unchecked Sendable {
        let lock = NSLock(); private var stored = false
        var value: Bool { lock.withLock { stored } }
        func set() { lock.withLock { stored = true } }
    }
    private final class LeaseBox: @unchecked Sendable {
        let lock = NSLock(); private var lease: InferenceLease?
        init(_ lease: InferenceLease) { self.lease = lease }
        func release() { lock.withLock { lease = nil } }
    }
    func testInteractiveCallCannotBypassAPIRankAndCancellationWithdrawsDemand() async throws {
        let (root, registry) = try fixture()
        let api = try registry.register(owner: .voiceRelay, instance: UUID(), rank: .api, delivery: .streaming)
        let host = try SpeechHostAdmission(owner: .libro, root: root.appendingPathComponent("admission"), inferenceFile: root.appendingPathComponent("inference.lock"))
        let started = Flag()
        let task = Task {
            try await host.withContext {
                try await InferenceLease.withPriority(.interactive) {
                    let lease = try await InferenceLease.acquire()
                    defer { withExtendedLifetime(lease) {} }
                    started.set()
                }
            }
        }
        // The host has entered acquisition once it owns outstanding work.
        try await wait { host.observation.registered == 1 }
        XCTAssertFalse(started.value)
        task.cancel()
        do { try await task.value; XCTFail("Cancelled host launched") } catch is CancellationError {}
        XCTAssertFalse(started.value); XCTAssertEqual(try registry.highest(), api.demand)
        try api.withdraw(); XCTAssertNil(try registry.highest())
        await host.stopAndWait()
    }
    func testLibroHostPrecedesPodcastsAndContextOverridesLegacyBackgroundPriority() async throws {
        let (root, registry) = try fixture(), file = root.appendingPathComponent("inference.lock")
        let api = try registry.register(owner: .voiceRelay, instance: UUID(), rank: .api, delivery: .file)
        let podcast = try SpeechHostAdmission(owner: .voiceRelay, root: root.appendingPathComponent("admission"), inferenceFile: file)
        let libro = try SpeechHostAdmission(owner: .libro, root: root.appendingPathComponent("admission"), inferenceFile: file)
        let lower = Task { try await podcast.withContext { LeaseBox(try await InferenceLease.acquire(priority: .interactive)) } }
        try await wait { podcast.observation.registered == 1 }
        let higher = Task { try await libro.withContext { LeaseBox(try await InferenceLease.acquire(priority: .background)) } }
        try await wait { libro.observation.registered == 1 }
        // Both have registered before releasing API's FIFO head.
        try api.withdraw()
        let winner = try await higher.value
        XCTAssertEqual(try registry.highest()?.rank, .libro)
        XCTAssertNil(try InferenceLease.tryAcquire(at: file))
        winner.release()
        let background = try await lower.value
        XCTAssertEqual(try registry.highest()?.rank, .podcast)
        background.release()
        await libro.stopAndWait(); await podcast.stopAndWait()
        XCTAssertNil(try registry.highest())
    }
    func testQuitWaitsForActualPlatformLeaseAndDoesNotFakeQuiescence() async throws {
        let (root, registry) = try fixture(), file = root.appendingPathComponent("inference.lock")
        let host = try SpeechHostAdmission(owner: .voiceRelay, root: root.appendingPathComponent("admission"), inferenceFile: file)
        var lease: InferenceLease? = try await host.withContext { try await InferenceLease.acquire() }
        let api = try registry.register(owner: .voiceRelay, instance: UUID(), rank: .api, delivery: .streaming)
        let ended = Flag()
        let close = Task { await host.stopAndWait(); ended.set() }
        try await wait { host.observation.closed }
        XCTAssertFalse(ended.value)
        XCTAssertNil(try registry.tryAcquireResidency(for: api.demand, inferenceFile: file))
        do { _ = try await host.withContext { try await InferenceLease.acquire() }; XCTFail("Closed owner accepted work") } catch is CancellationError {}
        lease = nil; withExtendedLifetime(lease) {}
        await close.value; XCTAssertTrue(ended.value)
        let next = try registry.tryAcquireResidency(for: api.demand, inferenceFile: file)
        XCTAssertNotNil(next); withExtendedLifetime(next) {}
        try api.withdraw()
    }
    func testExplicitUnrelatedLockCannotEscapeCoordinatedContext() async throws {
        let (root, registry) = try fixture()
        let host = try SpeechHostAdmission(owner: .libro, root: root.appendingPathComponent("admission"), inferenceFile: root.appendingPathComponent("inference.lock"))
        do {
            _ = try await host.withContext { try await InferenceLease.acquire(at: root.appendingPathComponent("unrelated.lock")) }
            XCTFail("Mismatched exclusion accepted")
        } catch let error as SpeechFailure { XCTAssertEqual(error.code, .invalidInput) }
        XCTAssertNil(try registry.highest()); await host.stopAndWait()
    }
    func testMaintenanceWithdrawsQueuedHostDemandButJoinsActualPlatformLease() async throws {
        let (root, registry) = try fixture()
        let host = try SpeechHostAdmission(owner: .libro, root: root.appendingPathComponent("admission"), inferenceFile: root.appendingPathComponent("inference.lock"))
        var active: InferenceLease? = try await host.withContext { try await InferenceLease.acquire() }
        host.pauseAccepting()
        let queued = Task { try await host.withContext { LeaseBox(try await InferenceLease.acquire()) } }
        try await wait { host.observation.outstanding == 2 }
        let done = Flag(), join = Task { await host.waitForActiveLeases(); done.set() }
        XCTAssertFalse(done.value); XCTAssertEqual(host.observation.active, 1)
        active = nil; withExtendedLifetime(active) {}
        await join.value
        XCTAssertNil(try registry.highest()); XCTAssertEqual(host.observation.active, 0)
        host.resumeAccepting()
        let next = try await queued.value; next.release()
        await host.stopAndWait(); XCTAssertNil(try registry.highest())
    }
    func testQuitWhileMaintenancePausedCancelsPendingGrantWithoutResurrection() async throws {
        let (root, registry) = try fixture()
        let host = try SpeechHostAdmission(owner: .voiceRelay, root: root.appendingPathComponent("admission"), inferenceFile: root.appendingPathComponent("inference.lock"))
        host.pauseAccepting()
        let pending = Task { try await host.withContext { try await InferenceLease.acquire() } }
        try await wait { host.observation.outstanding == 1 }
        await host.stopAndWait(); host.resumeAccepting()
        do { _ = try await pending.value; XCTFail("Quit admitted paused work") } catch is CancellationError {}
        XCTAssertNil(try registry.highest()); XCTAssertTrue(host.observation.closed)
    }
}
