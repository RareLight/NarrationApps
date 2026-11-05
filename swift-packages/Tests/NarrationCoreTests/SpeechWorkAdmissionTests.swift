import XCTest
import Foundation
import Darwin
@testable import NarrationCore

final class SpeechWorkAdmissionTests: XCTestCase {
    func testCPUDemandRanksAppsButCannotOwnResidencyOrBlockItsOwnSpeech() throws {
        let registry = try SpeechWorkAdmission(root: root()), instance = UUID()
        let cpu = try registry.register(owner: .libro, instance: instance, rank: .libro, delivery: .file, purpose: .cpu)
        let speech = try registry.register(owner: .libro, instance: instance, rank: .libro, delivery: .file)
        let podcast = try registry.register(owner: .voiceRelay, instance: UUID(), rank: .podcast, delivery: .file)
        XCTAssertEqual(try registry.highest(), cpu.demand)
        XCTAssertEqual(try registry.highest(for: speech.demand), speech.demand)
        XCTAssertEqual(try registry.withHighest(speech.demand) { true }, true)
        XCTAssertNil(try registry.withHighest(podcast.demand) { true })
        XCTAssertThrowsError(try registry.tryAcquireResidency(for: cpu.demand)) { XCTAssertEqual($0 as? SpeechCoordinationFailure, .invalidDemand) }
        let old = try JSONEncoder().encode(speech.demand)
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("purpose"))
        XCTAssertNil(try JSONDecoder().decode(SpeechWorkDemand.self, from: old).purpose)
    }
    func testCPUExceptionCannotBypassAPIFIFOEvenWithinSameInstance() throws {
        let registry = try SpeechWorkAdmission(root: root()), instance = UUID()
        let cpu = try registry.register(owner: .voiceRelay, instance: instance, rank: .podcast, delivery: .file, purpose: .cpu)
        let first = try registry.register(owner: .voiceRelay, instance: instance, rank: .api, delivery: .file)
        let second = try registry.register(owner: .voiceRelay, instance: instance, rank: .api, delivery: .streaming)
        XCTAssertEqual(try registry.highest(for: second.demand), first.demand)
        XCTAssertNil(try registry.withHighest(second.demand) { true })
        if case .waitForBoundary(let head) = try registry.decision(for: cpu.demand) { XCTAssertEqual(head, first.demand) }
        else { XCTFail("Complete-file API must stop new background CPU units") }
        try first.withdraw()
        XCTAssertEqual(try registry.withHighest(second.demand) { true }, true)
        if case .cancelForStreamingAPI = try registry.decision(for: cpu.demand) {} else { XCTFail("Streaming priority lost") }
        XCTAssertThrowsError(try registry.register(owner: .voiceRelay, instance: instance, rank: .api, delivery: .file, purpose: .cpu))
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("admission-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func ticket(_ registry: SpeechWorkAdmission, _ rank: SpeechWorkRank, _ delivery: SpeechWorkDelivery = .file) throws -> SpeechWorkTicket {
        try registry.register(owner: rank == .libro ? .libro : .voiceRelay, instance: UUID(), rank: rank, delivery: delivery)
    }
    private final class Client {
        let process = Process(), input = Pipe(), output = Pipe(), exited = DispatchSemaphore(value: 0)
        var stopped = false
        init(root: URL, rank: SpeechWorkRank, delivery: SpeechWorkDelivery = .streaming) throws {
            guard let worker = ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"] else { throw XCTSkip("Build the fixture worker first.") }
            process.executableURL = URL(fileURLWithPath: worker)
            process.arguments = ["--work-admission", root.path, String(rank.rawValue), delivery.rawValue]
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            let signal = exited; process.terminationHandler = { _ in signal.signal() }
            try process.run()
            try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        }
        func demand(timeout: Double = 3) throws -> SpeechWorkDemand {
            var fd = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&fd, 1, Int32(timeout * 1000)) > 0 else { throw SpeechCoordinationFailure.timeout }
            let data = try XCTUnwrap(SpeechIPC.readPipe(output.fileHandleForReading))
            return try JSONDecoder().decode(SpeechWorkDemand.self, from: data)
        }
        func stop(crash: Bool = false) throws {
            if stopped { return }; stopped = true
            if crash { _ = kill(process.processIdentifier, SIGKILL) }
            try? input.fileHandleForWriting.close()
            guard exited.wait(timeout: .now() + 3) == .success, !process.isRunning else { throw SpeechCoordinationFailure.timeout }
        }
        deinit { try? stop(crash: true) }
    }
    func testThreeRanksAndAPIFIFORemainOrderedAcrossReopening() throws {
        let path = try root(), registry = try SpeechWorkAdmission(root: path)
        let podcast = try ticket(registry, .podcast), book = try ticket(registry, .libro)
        XCTAssertEqual(try registry.highest(), book.demand)
        let first = try ticket(registry, .api, .file), second = try ticket(registry, .api, .streaming)
        let reopened = try SpeechWorkAdmission(root: path)
        XCTAssertEqual(try reopened.highest(), first.demand)
        XCTAssertEqual(try registry.decision(for: book.demand), .waitForBoundary(first.demand))
        XCTAssertEqual(try registry.decision(for: first.demand), .run)
        try first.withdraw()
        XCTAssertEqual(try reopened.highest(), second.demand)
        XCTAssertEqual(try registry.decision(for: book.demand), .cancelForStreamingAPI(second.demand))
        try second.withdraw()
        XCTAssertEqual(try registry.decision(for: podcast.demand), .waitForBoundary(book.demand))
        try book.withdraw()
        XCTAssertEqual(try registry.highest(), podcast.demand)
    }
    func testWithdrawnAndForgedTokensCannotPassFinalFence() throws {
        let registry = try SpeechWorkAdmission(root: root())
        let book = try ticket(registry, .libro), api = try ticket(registry, .api, .streaming)
        var invoked = false
        XCTAssertNil(try registry.withHighest(book.demand) { invoked = true; return true })
        XCTAssertFalse(invoked)
        XCTAssertEqual(try registry.withHighest(api.demand) { true }, true)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(api.demand)) as? [String: Any])
        object["id"] = UUID().uuidString
        let stale = try JSONDecoder().decode(SpeechWorkDemand.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(try registry.withHighest(stale) { true })
        try api.withdraw()
        XCTAssertEqual(try registry.decision(for: api.demand), .withdrawn)
    }
    func testInvalidOwnerAndDeliveryNeverRegisterPriority() throws {
        let registry = try SpeechWorkAdmission(root: root()), podcast = try ticket(registry, .podcast)
        for (owner, rank, delivery) in [(SpeechWorkOwner.libro, SpeechWorkRank.api, SpeechWorkDelivery.streaming),
                                      (.voiceRelay, .libro, .file), (.voiceRelay, .podcast, .streaming)] {
            XCTAssertThrowsError(try registry.register(owner: owner, instance: UUID(), rank: rank, delivery: delivery)) {
                XCTAssertEqual($0 as? SpeechCoordinationFailure, .invalidDemand)
            }
        }
        XCTAssertEqual(try registry.highest(), podcast.demand)
    }
    func testCheckpointFenceUsesCurrentRankAndModeUnderTheRegistrationGate() throws {
        let registry = try SpeechWorkAdmission(root: root()), book = try ticket(registry, .libro)
        let fence = try SpeechAttemptFence(batch: UUID(), job: UUID()), token = try fence.begin()
        let file = try ticket(registry, .api, .file)
        XCTAssertTrue(try registry.withDecision(for: book.demand) { decision in
            XCTAssertEqual(decision, .waitForBoundary(file.demand))
            return try fence.commit(token, index: 0) {}
        })
        try file.withdraw()
        let stream = try ticket(registry, .api, .streaming)
        XCTAssertFalse(try registry.withDecision(for: book.demand) { decision in
            guard case .cancelForStreamingAPI(let winner) = decision else { return true }
            XCTAssertEqual(winner, stream.demand)
            fence.revoke(token)
            return try fence.commit(token, index: 1) { XCTFail("Revoked checkpoint published") }
        })
        XCTAssertEqual(fence.verifiedPrefix, 1)
    }
    func testCrossProcessCrashAndEOFCannotLeaveStalePriority() throws {
        let path = try root(), registry = try SpeechWorkAdmission(root: path), book = try ticket(registry, .libro)
        for crash in [false, true] {
            let child = try Client(root: path, rank: .api)
            let api = try child.demand()
            XCTAssertEqual(try registry.highest(), api)
            XCTAssertEqual(try registry.decision(for: book.demand), .cancelForStreamingAPI(api))
            try child.stop(crash: crash)
            XCTAssertEqual(try registry.highest(), book.demand)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent("ticket-" + api.id.uuidString).path))
        }
    }
    func testCrossProcessNotificationPromptsAuthoritativeKernelRecheck() async throws {
        let path = try root(), registry = try SpeechWorkAdmission(root: path)
        let wakeup = SpeechWorkWakeup(root: path, fallbackMilliseconds: 30_000)
        defer { wakeup.finish() }
        guard wakeup.notificationsAvailable else { throw XCTSkip("Notifications unavailable; fallback has separate coverage") }
        let client = try Client(root: path, rank: .api)
        defer { try? client.stop() }
        let demand = try client.demand()
        let event = try await withThrowingTaskGroup(of: SpeechWorkWakeup.Event?.self) { group in
            group.addTask { var iterator = wakeup.events.makeAsyncIterator(); return await iterator.next() }
            group.addTask { try await Task.sleep(for: .seconds(3)); throw SpeechFailure(.timeout) }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        XCTAssertEqual(event, .changed)
        XCTAssertEqual(try registry.highest(), demand)
        try client.stop()
        XCTAssertNil(try registry.highest())
    }
    func testHigherRankCannotAcquireResidencyUntilLowerOwnerReleasesKernelProtection() async throws {
        let path = try root(), registry = try SpeechWorkAdmission(root: path.appendingPathComponent("coordination"))
        let kernel = path.appendingPathComponent("kernel")
        let podcast = try ticket(registry, .podcast), book = try ticket(registry, .libro)
        XCTAssertNil(try registry.tryAcquireResidency(for: podcast.demand, inferenceFile: kernel))
        var legacy: InferenceLease? = try await InferenceLease.acquire(at: kernel)
        XCTAssertNil(try registry.tryAcquireResidency(for: book.demand, inferenceFile: kernel))
        withExtendedLifetime(legacy) {}; legacy = nil
        var resident = try XCTUnwrap(registry.tryAcquireResidency(for: book.demand, inferenceFile: kernel)) as InferenceLease?
        let api = try ticket(registry, .api, .streaming)
        XCTAssertEqual(try registry.decision(for: book.demand), .cancelForStreamingAPI(api.demand))
        XCTAssertNil(try registry.tryAcquireResidency(for: api.demand, inferenceFile: kernel))
        withExtendedLifetime(resident) {}; resident = nil // After helper drain/unload, never merely ticket withdrawal.
        let live = try XCTUnwrap(registry.tryAcquireResidency(for: api.demand, inferenceFile: kernel))
        XCTAssertNil(try registry.tryAcquireResidency(for: book.demand, inferenceFile: kernel))
        withExtendedLifetime(live) {}
    }
    func testNonblockingCompatibilityHandshakeReleasesPartialLocksOnEitherConflict() throws {
        let path = try root(), a = path.appendingPathComponent("legacy"), b = path.appendingPathComponent("current")
        for blocked in [a, b] {
            var blocker = try XCTUnwrap(InferenceLease.tryAcquire(at: blocked)) as InferenceLease?
            XCTAssertNil(try InferenceLease.tryAcquire(files: [a, b]))
            let other = blocked == a ? b : a
            var available = try XCTUnwrap(InferenceLease.tryAcquire(at: other)) as InferenceLease?
            withExtendedLifetime(available) {}; available = nil
            withExtendedLifetime(blocker) {}; blocker = nil
            var combined = try XCTUnwrap(InferenceLease.tryAcquire(files: [a, b])) as InferenceLease?
            XCTAssertNil(try InferenceLease.tryAcquire(at: a))
            XCTAssertNil(try InferenceLease.tryAcquire(at: b))
            withExtendedLifetime(combined) {}; combined = nil
        }
    }
    func testCompatibilityHandshakeRejectsEmptyOrDuplicateLockSets() throws {
        let path = try root().appendingPathComponent("kernel")
        XCTAssertThrowsError(try InferenceLease.tryAcquire(files: []))
        XCTAssertThrowsError(try InferenceLease.tryAcquire(files: [path, path]))
    }
    func testRegistrationAndFinalAdmissionOperationShareOneGate() throws {
        let path = try root(), registry = try SpeechWorkAdmission(root: path), book = try ticket(registry, .libro)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { finished.signal() }
            _ = try? registry.withHighest(book.demand) {
                entered.signal(); _ = release.wait(timeout: .now() + 2); return true
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let child = try Client(root: path, rank: .api)
        defer { release.signal(); try? child.stop(crash: true) }
        XCTAssertThrowsError(try child.demand(timeout: 0.1)) { XCTAssertEqual($0 as? SpeechCoordinationFailure, .timeout) }
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        let api = try child.demand()
        XCTAssertEqual(try registry.highest(), api)
        XCTAssertNil(try registry.withHighest(book.demand) { true })
    }
    func testStorageRefusesSymlinksHardlinksPermissionsAndUnrelatedFiles() throws {
        let path = try root(), registry = try SpeechWorkAdmission(root: path), book = try ticket(registry, .libro)
        let row = path.appendingPathComponent("ticket-" + book.demand.id.uuidString)
        let alias = path.appendingPathComponent("another-link")
        XCTAssertEqual(link(row.path, alias.path), 0)
        XCTAssertThrowsError(try registry.highest())
        XCTAssertEqual(unlink(alias.path), 0)
        XCTAssertEqual(chmod(row.path, 0o644), 0)
        XCTAssertThrowsError(try registry.highest())
        XCTAssertEqual(chmod(row.path, 0o600), 0)
        let symbolic = path.deletingLastPathComponent().appendingPathComponent("admission-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: symbolic) }
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: path)
        XCTAssertThrowsError(try SpeechWorkAdmission(root: symbolic))
        let unrelated = try root()
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let preserved = unrelated.appendingPathComponent("unrelated.txt")
        try Data("preserve".utf8).write(to: preserved)
        XCTAssertThrowsError(try SpeechWorkAdmission(root: unrelated))
        XCTAssertEqual(try Data(contentsOf: preserved), Data("preserve".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unrelated.appendingPathComponent("gate").path))
    }
    func testMalformedLiveMetadataFailsClosedWithoutChangingOtherTickets() throws {
        let path = try root(), registry = try SpeechWorkAdmission(root: path), book = try ticket(registry, .libro)
        let row = path.appendingPathComponent("ticket-" + book.demand.id.uuidString)
        let bytes = try Data(contentsOf: row)
        let handle = try FileHandle(forWritingTo: row); defer { try? handle.close() }
        try handle.truncate(atOffset: 0); try handle.write(contentsOf: Data("{}".utf8))
        XCTAssertThrowsError(try registry.highest())
        try handle.seek(toOffset: 0); try handle.write(contentsOf: bytes); try handle.truncate(atOffset: UInt64(bytes.count))
        XCTAssertEqual(try registry.highest(), book.demand)
    }
    func testCapacityMetadataBoundsAndPrivatePayload() throws {
        let path = try root(), registry = try SpeechWorkAdmission(root: path)
        var tickets: [SpeechWorkTicket] = []
        for _ in 0..<SpeechWorkAdmission.maximumTickets { tickets.append(try ticket(registry, .podcast)) }
        XCTAssertThrowsError(try ticket(registry, .api, .streaming)) { XCTAssertEqual($0 as? SpeechCoordinationFailure, .capacity) }
        let first = try XCTUnwrap(tickets.first)
        let row = path.appendingPathComponent("ticket-" + first.demand.id.uuidString)
        let bytes = try Data(contentsOf: row)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "id", "instance", "owner", "rank", "delivery", "order"])
        let handle = try FileHandle(forWritingTo: row); defer { try? handle.close() }
        try handle.truncate(atOffset: 0); try handle.write(contentsOf: Data(repeating: 32, count: SpeechWorkAdmission.maximumRecordBytes + 1))
        XCTAssertThrowsError(try registry.highest())
        try handle.seek(toOffset: 0); try handle.write(contentsOf: bytes); try handle.truncate(atOffset: UInt64(bytes.count))
        XCTAssertEqual(try registry.highest(), first.demand)
        try first.withdraw()
        let replacement = try ticket(registry, .api, .streaming)
        XCTAssertEqual(try registry.highest(), replacement.demand)
        withExtendedLifetime(tickets) {}
    }
}
