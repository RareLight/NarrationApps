import XCTest
import Darwin
@testable import NarrationCore

@MainActor
final class InferencePriorityTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func process(root: URL, name: String, priority: String, hold: Int) throws -> Process {
        guard let worker = ProcessInfo.processInfo.environment["NARRATION_FIXTURE_WORKER"] else {
            throw XCTSkip("Supply the model-free fixture worker for cross-process admission tests.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: worker)
        process.arguments = ["--lease", root.appendingPathComponent("inference.lock").path, priority,
                             String(hold), root.appendingPathComponent(name + ".jsonl").path]
        try process.run()
        addTeardownBlock { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        return process
    }
    private func events(_ root: URL, _ name: String) throws -> [String] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(name + ".jsonl")) else { return [] }
        return try data.split(separator: 10).map {
            try XCTUnwrap((JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])?["event"] as? String)
        }
    }
    private func waitFor(_ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(try condition()) {
            guard ContinuousClock.now < deadline else { XCTFail("Admission condition timed out"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func hasTicket(_ file: URL) -> Bool {
        !( (try? FileManager.default.contentsOfDirectory(atPath: InferenceLease.ticketDirectory(for: file).path)) ?? [] ).isEmpty
    }
    func testInteractiveProcessOvertakesAlreadyWaitingBackgroundProcess() async throws {
        let root = try root(), file = root.appendingPathComponent("inference.lock")
        let owner = try process(root: root, name: "owner", priority: "background", hold: 10_000)
        try await waitFor { try events(root, "owner").contains("acquired") }
        let background = try process(root: root, name: "background", priority: "background", hold: 0)
        try await waitFor { try events(root, "background").contains("requested") }
        let foreground = try process(root: root, name: "foreground", priority: "interactive", hold: 150)
        try await waitFor { hasTicket(file) }
        owner.terminate(); owner.waitUntilExit()
        try await waitFor { try events(root, "foreground").contains("acquired") }
        XCTAssertFalse(try events(root, "background").contains("acquired"))
        try await waitFor { !foreground.isRunning && !background.isRunning }
        XCTAssertEqual(foreground.terminationStatus, 0)
        XCTAssertEqual(background.terminationStatus, 0)
        XCTAssertTrue(try events(root, "background").contains("acquired"))
        XCTAssertFalse(hasTicket(file))
    }
    func testCrashedInteractiveOwnerCannotLeaveBackgroundBlocked() async throws {
        let root = try root(), file = root.appendingPathComponent("inference.lock")
        let foreground = try process(root: root, name: "foreground", priority: "interactive", hold: 10_000)
        try await waitFor { try events(root, "foreground").contains("acquired") }
        XCTAssertTrue(hasTicket(file))
        XCTAssertEqual(kill(foreground.processIdentifier, SIGKILL), 0)
        foreground.waitUntilExit()
        let background = try process(root: root, name: "background", priority: "background", hold: 0)
        try await waitFor { !background.isRunning }
        XCTAssertEqual(background.terminationStatus, 0)
        XCTAssertTrue(try events(root, "background").contains("acquired"))
        XCTAssertFalse(hasTicket(file))
    }
    func testCancelledInteractiveWaitRemovesPriorityReservation() async throws {
        let root = try root(), file = root.appendingPathComponent("inference.lock")
        var owner: InferenceLease? = try await InferenceLease.acquire(at: file)
        let foreground = Task { try await InferenceLease.acquire(at: file, priority: .interactive) }
        try await waitFor { hasTicket(file) }
        foreground.cancel()
        do { _ = try await foreground.value; XCTFail("Cancelled request acquired inference") }
        catch is CancellationError {}
        XCTAssertFalse(hasTicket(file))
        let background = Task { try await InferenceLease.acquire(at: file) }
        withExtendedLifetime(owner) {}
        owner = nil
        let acquired = try await background.value
        withExtendedLifetime(acquired) {}
    }
    func testInteractiveReservationBlocksBackgroundAcrossGapsWithoutHoldingInference() async throws {
        let root = try root(), file = root.appendingPathComponent("inference.lock")
        let foreground = Task {
            try await InferenceLease.withPriority(.interactive, at: file) {
                // This represents document extraction/transition between ML calls.
                try await Task.sleep(for: .milliseconds(150))
            }
        }
        try await waitFor { hasTicket(file) }
        let background = try process(root: root, name: "background", priority: "background", hold: 0)
        try await waitFor { try events(root, "background").contains("requested") }
        XCTAssertFalse(try events(root, "background").contains("acquired"))
        try await foreground.value
        try await waitFor { !background.isRunning }
        XCTAssertEqual(background.terminationStatus, 0)
        XCTAssertTrue(try events(root, "background").contains("acquired"))
    }
}
