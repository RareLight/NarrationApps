import XCTest
@testable import LibroCore

private actor ScanGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

final class IntakeScanTaskTests: XCTestCase {
    func testReplacementAndShutdownJoinCancelledPredecessors() async throws {
        let gate = ScanGate()
        let first = Task<IntakeScanTask.Result, Error> {
            await gate.wait() // Simulates a native operation that ignores cancellation.
            return try InputCollector.collect([]).withNoCovers
        }
        for _ in 0..<200 {
            if await gate.waiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let waiting = await gate.waiting
        XCTAssertTrue(waiting)
        let second = IntakeScanTask.start(replacing: first, after: nil, coverWork: nil) {
            XCTFail("A superseded scanner must not start its native work")
            return try InputCollector.collect([]).withNoCovers
        }
        let third = IntakeScanTask.start(replacing: second, after: nil, coverWork: nil) {
            XCTFail("Shutdown must cancel the replacement before it starts")
            return try InputCollector.collect([]).withNoCovers
        }
        third.cancel()
        XCTAssertTrue(first.isCancelled)
        XCTAssertTrue(second.isCancelled)
        await gate.release()
        _ = try await first.value
        for task in [second, third] {
            do { _ = try await task.value; XCTFail("Expected cancellation after joining predecessors") }
            catch is CancellationError {}
        }
    }
}

private extension IntakeResult {
    var withNoCovers: IntakeScanTask.Result { (self, [:]) }
}
