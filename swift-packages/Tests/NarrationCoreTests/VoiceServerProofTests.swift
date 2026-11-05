import XCTest
import Foundation
import Darwin

// VS00 intentionally launches only the existing model-free executable, in two
// client roles with private fake helpers. No app, HTTP, model or live lock access.
@MainActor
final class VoiceServerProofTests: XCTestCase {
    private final class Client {
        let process = Process()
        let input: FileHandle
        let output: FileHandle
        init(worker: String, root: URL, app: String) throws {
            process.executableURL = URL(fileURLWithPath: worker)
            process.arguments = ["--priority-proof", "client", root.path, app]
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin; process.standardOutput = stdout
            input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
            try process.run()
            try stdin.fileHandleForReading.close(); try stdout.fileHandleForWriting.close()
        }
        @discardableResult func send(_ action: String, id: String = "", rank: Int = 2,
            delivery: String = "streaming", epoch: Int = 0, delayed: Bool = false) throws -> [String: Any] {
            let command: [String: Any] = ["action": action, "id": id, "rank": rank,
                "delivery": delivery, "epoch": epoch, "delayed": delayed]
            try input.write(contentsOf: JSONSerialization.data(withJSONObject: command) + Data([10]))
            var bytes = Data()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while bytes.count < 4096 {
                guard ContinuousClock.now < deadline else { throw FixtureError.timeout }
                var fd = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&fd, 1, 50)
                guard ready >= 0 else { throw FixtureError.closed }
                if ready == 0 { continue }
                guard let byte = try output.read(upToCount: 1), !byte.isEmpty else { throw FixtureError.closed }
                if byte[0] == 10 { return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any]) }
                bytes += byte
            }
            throw FixtureError.closed
        }
        func crash() throws {
            XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0)
            try wait { !self.process.isRunning }
            process.waitUntilExit()
        }
        func close() throws {
            try input.close()
            try wait { !self.process.isRunning }
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        private func wait(_ condition: () -> Bool) throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !condition() {
                guard ContinuousClock.now < deadline else { throw FixtureError.timeout }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }
    private enum FixtureError: Error { case timeout, closed }
    private func fixture() throws -> (URL, Client, Client) {
        guard let worker = ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"] else {
            throw XCTSkip("Build NarrationFixtureWorker and set NARRATION_FIXTURE_WORKER.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VS00-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let libro = try Client(worker: worker, root: root, app: "Libro")
        let relay = try Client(worker: worker, root: root, app: "VoiceRelay")
        // Retain private evidence optionally; otherwise temporary trace/PCM is removed.
        addTeardownBlock {
            // Failure cleanup releases only these fixtures' owned drain barriers.
            for app in ["Libro", "VoiceRelay"] { try? Data().write(to: root.appendingPathComponent("drain-\(app)")) }
            for client in [libro, relay] {
                if client.process.isRunning { _ = kill(client.process.processIdentifier, SIGKILL) }
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            var helpersExited = false
            repeat {
                let trace = (try? String(contentsOf: root.appendingPathComponent("trace.txt"), encoding: .utf8)) ?? ""
                helpersExited = trace.contains("Libro exit\n") && trace.contains("VoiceRelay exit\n")
                if !helpersExited { Thread.sleep(forTimeInterval: 0.005) }
            } while !helpersExited && ContinuousClock.now < deadline
            if let evidence = ProcessInfo.processInfo.environment["NARRATION_PROOF_EVIDENCE"] {
                let destination = URL(fileURLWithPath: evidence).appendingPathComponent(root.lastPathComponent)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: root, to: destination)
            }
            // Leave a failed orphan its barrier until it has actually exited.
            if helpersExited { try FileManager.default.removeItem(at: root) }
        }
        return (root, libro, relay)
    }
    private func event(_ result: [String: Any], _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result["event"] as? String, expected, file: file, line: line)
    }
    private func number(_ result: [String: Any], _ key: String) throws -> Int { try XCTUnwrap(result[key] as? Int) }
    private func trace(_ root: URL) throws -> [String] {
        try String(contentsOf: root.appendingPathComponent("trace.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
    }
    // Independent telemetry invariant: protected residency is a strict superset
    // of generation. A cancelled attempt remains active until quiescent, not cancel.
    private func audit(_ root: URL) throws {
        var resident: String?, active: String?
        var reset = true
        for line in try trace(root) {
            let parts = line.split(separator: " ").map(String.init)
            let app = parts[0], event = parts[1]
            switch event {
            case "load": XCTAssertNil(resident, line); resident = app
            case "start":
                XCTAssertEqual(resident, app, line); XCTAssertNil(active, line)
                XCTAssertTrue(reset, line); reset = false; active = app
            case "quiescent": XCTAssertEqual(active, app, line); active = nil
            case "reset": XCTAssertNil(active, line); reset = true
            case "unload": XCTAssertNil(active, line); XCTAssertEqual(resident, app, line); resident = nil
            default: break
            }
        }
        XCTAssertNil(active); XCTAssertNil(resident)
    }
    private func shutdown(_ root: URL, _ libro: Client, _ relay: Client) throws {
        try libro.close(); try relay.close(); try audit(root)
    }

    func testNestedStreamingPriorityRollbackFIFOAndCrossAppResidency() throws {
        let (root, libro, relay) = try fixture()
        try libro.send("register", id: "book", rank: 1)
        try relay.send("register", id: "podcast")
        event(try relay.send("observe"), "waiting")
        let first = try libro.send("observe")
        event(first, "started")
        let checkpoint = try libro.send("finish")
        XCTAssertEqual(checkpoint["chunks"] as? [Int], [1])
        let second = try libro.send("observe")
        try relay.send("register", id: "A", rank: 0)
        try relay.send("register", id: "B", rank: 0)
        event(try libro.send("observe"), "suspended")
        event(try libro.send("late", id: "book", epoch: number(second, "epoch")), "stale")
        event(try relay.send("observe"), "waiting")
        event(try libro.send("drain"), "ready")
        event(try libro.send("observe"), "waiting") // unload acknowledgement
        let a = try relay.send("observe")
        event(a, "started")
        XCTAssertEqual(try number(a, "loads"), 1)
        try relay.send("finish"); try relay.send("done", id: "A")
        let b = try relay.send("observe")
        XCTAssertEqual(try number(a, "pid"), try number(b, "pid"))
        XCTAssertEqual(try number(b, "loads"), 1)
        try relay.send("finish"); try relay.send("done", id: "B")
        event(try relay.send("observe"), "waiting") // Libro remains ahead of podcast
        let resumed = try libro.send("observe")
        event(resumed, "started")
        XCTAssertEqual(resumed["chunks"] as? [Int], [1])
        XCTAssertEqual(try number(resumed, "loads"), 2) // cross-app transfer is cold
        event(try libro.send("stale-cancel", id: "book", epoch: number(second, "epoch")), "stale")
        event(try libro.send("late", id: "book", epoch: number(second, "epoch")), "stale")
        try libro.send("finish"); try libro.send("observe"); try libro.send("finish")
        let final = try libro.send("status", id: "book")
        XCTAssertEqual(final["chunks"] as? [Int], [1, 2, 3])
        XCTAssertEqual(final["hash"] as? String, checkpoint["hash"] as? String)
        try libro.send("done", id: "book"); try libro.send("observe")
        event(try relay.send("observe"), "started")
        try relay.send("finish"); try relay.send("done", id: "podcast")
        try shutdown(root, libro, relay)
        let events = try trace(root)
        let starts = events.filter { $0.contains(" start ") }.map { $0.components(separatedBy: " ")[2] }
        XCTAssertEqual(starts, ["book", "book", "A", "B", "book", "book", "podcast"])
        XCTAssertEqual(events.filter { $0.contains("commit book chunk=2") }.count, 1)
        print("VS00 nested trace:\n" + events.joined(separator: "\n"))
    }

    func testSameAppStreamingBurstPreservesPIDWeightsAndVerifiedPCM() throws {
        let (root, libro, relay) = try fixture()
        try relay.send("register", id: "podcast")
        let original = try relay.send("observe")
        let checkpoint = try relay.send("finish")
        let interrupted = try relay.send("observe")
        try relay.send("register", id: "A", rank: 0)
        try relay.send("register", id: "B", rank: 0)
        event(try relay.send("observe"), "suspended")
        try relay.send("drain")
        for id in ["A", "B"] {
            let start = try relay.send("observe")
            XCTAssertEqual(try number(start, "pid"), try number(original, "pid"))
            XCTAssertEqual(try number(start, "loads"), 1)
            if id == "B" {
                // Different jobs may have the same local epoch. Identity is part
                // of the fence; an old A cancel cannot revoke live B.
                event(try relay.send("stale-cancel", id: "A", epoch: number(start, "epoch")), "stale")
            }
            try relay.send("finish"); try relay.send("done", id: id)
        }
        let resumed = try relay.send("observe")
        XCTAssertEqual(try number(resumed, "loads"), 1)
        XCTAssertEqual(try number(resumed, "pid"), try number(original, "pid"))
        event(try relay.send("late", id: "podcast", epoch: number(interrupted, "epoch")), "stale")
        try relay.send("finish"); try relay.send("observe"); try relay.send("finish")
        let final = try relay.send("status", id: "podcast")
        XCTAssertEqual(final["hash"] as? String, checkpoint["hash"] as? String)
        XCTAssertEqual(final["chunks"] as? [Int], [1, 2, 3])
        try relay.send("done", id: "podcast")
        try shutdown(root, libro, relay)
        XCTAssertEqual(try trace(root).filter { $0.contains("load count=") }.count, 1)
    }

    func testCompleteFileWaitsForChunkCommitAndDoesNotPreemptActiveAPI() throws {
        let (root, libro, relay) = try fixture()
        try libro.send("register", id: "book", rank: 1)
        try libro.send("observe")
        try relay.send("register", id: "A", rank: 0, delivery: "file")
        event(try libro.send("observe"), "yield-at-boundary")
        event(try relay.send("observe"), "waiting")
        try libro.send("finish"); try libro.send("observe")
        event(try relay.send("observe"), "started")
        try relay.send("register", id: "B", rank: 0)
        event(try relay.send("observe"), "active")
        try relay.send("finish"); try relay.send("done", id: "A")
        event(try relay.send("observe"), "started")
        try relay.send("finish"); try relay.send("done", id: "B"); try relay.send("observe")
        try libro.send("observe")
        XCTAssertEqual(try libro.send("status", id: "book")["chunks"] as? [Int], [1])
        try libro.send("finish"); try libro.send("done", id: "book")
        try shutdown(root, libro, relay)
        XCTAssertFalse(try trace(root).contains { $0.contains("revoke") })
    }

    func testManualPauseAndStopWhileSuspendedDoNotResurrectOrBlockPodcast() throws {
        for action in ["pause", "stop"] {
            let (root, libro, relay) = try fixture()
            try libro.send("register", id: "book", rank: 1); try libro.send("observe")
            try relay.send("register", id: "podcast")
            try relay.send("register", id: "A", rank: 0)
            try libro.send("observe"); try libro.send(action, id: "book")
            try libro.send("drain"); try libro.send("observe")
            try relay.send("observe"); try relay.send("finish"); try relay.send("done", id: "A")
            event(try relay.send("observe"), "started")
            event(try libro.send("observe"), "waiting")
            try relay.send("finish"); try relay.send("done", id: "podcast")
            if action == "pause" {
                try libro.send("resume", id: "book")
                try relay.send("observe")
                event(try libro.send("observe"), "started")
                try libro.send("finish"); try libro.send("done", id: "book")
            } else { event(try libro.send("observe"), "idle") }
            try shutdown(root, libro, relay)
        }
    }

    func testRequesterDisappearanceAndDelayedCancellationKeepExclusionUntilDrain() throws {
        let (root, libro, relay) = try fixture()
        try libro.send("register", id: "book", rank: 1); try libro.send("observe")
        try relay.send("register", id: "A", rank: 0)
        event(try libro.send("observe", delayed: true), "suspended")
        event(try relay.send("observe"), "waiting")
        try relay.send("disconnect", id: "A")
        // Disappeared requester does not shortcut the old producer's drain/reset.
        event(try libro.send("observe"), "draining")
        try libro.send("drain")
        let resumed = try libro.send("observe")
        event(resumed, "started"); XCTAssertEqual(try number(resumed, "loads"), 1)
        try libro.send("finish"); try libro.send("done", id: "book")
        try shutdown(root, libro, relay)
        XCTAssertFalse(try trace(root).contains { $0.contains("start A") })
    }

    func testHostCrashLeavesOrphanResidencyProtectedUntilParentEOFDrain() throws {
        let (root, libro, relay) = try fixture()
        try libro.send("register", id: "book", rank: 1); try libro.send("observe")
        try relay.send("register", id: "A", rank: 0)
        try libro.crash()
        // Ticket liveness disappears with the host; helper lock must outlive it.
        event(try relay.send("observe"), "waiting")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(try trace(root).contains("Libro parent-eof")) {
            guard ContinuousClock.now < deadline else { throw FixtureError.timeout }
            Thread.sleep(forTimeInterval: 0.005)
        }
        event(try relay.send("observe"), "waiting")
        try Data().write(to: root.appendingPathComponent("drain-Libro"))
        while !(try trace(root).contains("Libro exit")) {
            guard ContinuousClock.now < deadline else { throw FixtureError.timeout }
            Thread.sleep(forTimeInterval: 0.005)
        }
        event(try relay.send("observe"), "started")
        try relay.send("finish"); try relay.send("done", id: "A")
        try relay.close(); try audit(root)
    }

    func testCrashedWaitingRequesterCannotLeaveStalePriority() throws {
        let (root, libro, relay) = try fixture()
        try libro.send("register", id: "book", rank: 1); try libro.send("observe")
        try relay.send("register", id: "A", rank: 0)
        try relay.crash()
        event(try libro.send("observe"), "active")
        try libro.send("finish"); try libro.send("done", id: "book")
        try libro.close(); try audit(root)
    }

    func testIdleLoadedHelperMustUnloadBeforeOtherAppLoads() throws {
        let (root, libro, relay) = try fixture()
        try libro.send("register", id: "book", rank: 1); try libro.send("observe")
        try libro.send("finish"); try libro.send("pause", id: "book")
        try relay.send("register", id: "A", rank: 0)
        // No active generation exists, but residency still prevents a second load.
        event(try relay.send("observe"), "waiting")
        event(try libro.send("observe"), "waiting")
        event(try relay.send("observe"), "started")
        try relay.send("finish"); try relay.send("done", id: "A")
        try shutdown(root, libro, relay)
    }

    func testCommittedCheckpointReopensAndRejectsDuplicateCompletion() throws {
        let (root, libro, relay) = try fixture()
        try libro.send("register", id: "book", rank: 1)
        let start = try libro.send("observe")
        let checkpoint = try libro.send("finish")
        event(try libro.send("late", id: "book", epoch: number(start, "epoch")), "stale")
        try libro.send("done", id: "book"); try libro.close()
        let worker = try XCTUnwrap(ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"])
        let reopened = try Client(worker: worker, root: root, app: "Libro")
        defer { if reopened.process.isRunning { _ = kill(reopened.process.processIdentifier, SIGKILL) } }
        try reopened.send("register", id: "book", rank: 1)
        let restored = try reopened.send("observe")
        XCTAssertEqual(restored["chunks"] as? [Int], [1])
        XCTAssertEqual(try reopened.send("status", id: "book")["hash"] as? String, checkpoint["hash"] as? String)
        try reopened.send("finish"); try reopened.send("done", id: "book")
        try reopened.close(); try relay.close(); try audit(root)
    }

    func testActiveDisconnectDrainsBeforeNextAPIAndNeverReplaysDisconnectedWork() throws {
        let (root, libro, relay) = try fixture()
        try relay.send("register", id: "podcast")
        try relay.send("register", id: "A", rank: 0)
        let a = try relay.send("observe")
        try relay.send("register", id: "B", rank: 0)
        try relay.send("disconnect", id: "A", delayed: true)
        event(try relay.send("observe"), "draining")
        event(try relay.send("late", id: "A", epoch: number(a, "epoch")), "stale")
        try relay.send("drain")
        let b = try relay.send("observe")
        event(b, "started")
        XCTAssertEqual(try number(a, "pid"), try number(b, "pid"))
        XCTAssertEqual(try number(b, "loads"), 1)
        try relay.send("finish"); try relay.send("done", id: "B")
        event(try relay.send("observe"), "started")
        try relay.send("finish"); try relay.send("done", id: "podcast")
        try shutdown(root, libro, relay)
        XCTAssertEqual(try trace(root).filter { $0.contains("start A") }.count, 1)
        XCTAssertFalse(try trace(root).contains { $0.contains("commit A") })
    }
}
