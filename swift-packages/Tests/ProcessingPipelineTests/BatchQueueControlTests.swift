import XCTest
@testable import ProcessingPipeline

final class BatchQueueControlTests: XCTestCase {
    func testPendingOrderAndStaleSkipCannotChangeCurrentOrCommittedItem() async throws {
        let jobs = (0..<3).map { _ in UUID() }
        let control = BatchQueueControl(batch: UUID(), jobs: jobs)
        let first = try await control.next()
        XCTAssertEqual(first, jobs[0])
        XCTAssertFalse(control.reorderPending([jobs[0], jobs[2]]))
        XCTAssertTrue(control.reorderPending([jobs[2], jobs[1]]))
        try control.authorizePublication(job: jobs[0])
        XCTAssertFalse(control.skip(job: jobs[0]))
        control.finish(job: jobs[0])
        let next = try await control.next()
        XCTAssertEqual(next, jobs[2])
        XCTAssertFalse(control.skip(job: jobs[0]))
        XCTAssertTrue(control.skip(job: jobs[2]))
        do { try await control.checkpoint(job: jobs[2]); XCTFail("Skip should abort the current item") }
        catch is BatchItemSkipped { }
    }
    func testPausedBoundaryCancellationNeverLeaksAWaiter() async throws {
        let control = BatchQueueControl(batch: UUID(), jobs: [UUID()])
        control.setPaused(true)
        let task = Task { try await control.next() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled waiter resumed") } catch is CancellationError { }
        control.setPaused(false)
        let next = try await control.next()
        XCTAssertNotNil(next)
    }
}
