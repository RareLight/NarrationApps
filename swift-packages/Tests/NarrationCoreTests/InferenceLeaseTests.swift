import XCTest
import Darwin
@testable import NarrationCore

final class InferenceLeaseTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func canLock(_ url: URL) -> Bool {
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }
    func testDefaultPathUsesCurrentPackageName() {
        XCTAssertTrue(InferenceLease.defaultFile.path.hasSuffix("/SwiftNarration/Locks/inference.lock"))
    }
    func testRenamedAndLegacyLocksAreHeldAndReleasedTogether() async throws {
        let root = try root(), old = root.appendingPathComponent("old.lock"), current = root.appendingPathComponent("current.lock")
        var held: InferenceLease? = try await InferenceLease.acquire(files: [old, current])
        XCTAssertNotNil(held)
        XCTAssertFalse(canLock(old)); XCTAssertFalse(canLock(current))
        held = nil
        XCTAssertTrue(canLock(old)); XCTAssertTrue(canLock(current))
    }
    func testBlockedSecondLockDoesNotRetainTheFirstOnCancellation() async throws {
        let root = try root(), first = root.appendingPathComponent("first.lock"), second = root.appendingPathComponent("second.lock")
        let owner = try await InferenceLease.acquire(at: second)
        let waiting = Task { try await InferenceLease.acquire(files: [first, second]) }
        defer { waiting.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: first.path) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(canLock(first))
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Cancelled waiter acquired both locks") }
        catch is CancellationError {}
        XCTAssertTrue(canLock(first)); XCTAssertFalse(canLock(second))
        withExtendedLifetime(owner) {}
    }
}
