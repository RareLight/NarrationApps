import XCTest
import Foundation
@testable import NarrationCore

final class SpeechAttemptFenceTests: XCTestCase {
    private func fence(_ verified: Set<Int> = []) throws -> SpeechAttemptFence {
        try .init(batch: UUID(), job: UUID(), verifiedChunks: verified)
    }
    func testRevocationRejectsLateValidationAndWaitsForQuiescenceBeforeResume() throws {
        let fence = try fence(), first = try fence.begin()
        XCTAssertTrue(try fence.commit(first, index: 0) {})
        XCTAssertTrue(fence.revoke(first))
        var called = false
        XCTAssertFalse(try fence.commit(first, index: 1) { called = true })
        XCTAssertFalse(called)
        XCTAssertThrowsError(try fence.begin())
        XCTAssertTrue(fence.acknowledgeQuiescence(first))
        let resumed = try fence.begin()
        XCTAssertGreaterThan(resumed.epoch, first.epoch)
        XCTAssertNotEqual(resumed.identity.attempt, first.identity.attempt)
        XCTAssertFalse(fence.revoke(first)); XCTAssertFalse(fence.acknowledgeQuiescence(first))
        XCTAssertTrue(try fence.commit(resumed, index: 1) {})
        XCTAssertEqual(fence.verifiedPrefix, 2)
    }
    func testDifferentJobsAtEpochOneCannotPublishOrCancelEachOther() throws {
        let batch = UUID()
        let a = try SpeechAttemptFence(batch: batch, job: UUID()), b = try SpeechAttemptFence(batch: batch, job: UUID())
        let ta = try a.begin(), tb = try b.begin()
        XCTAssertEqual(ta.epoch, tb.epoch)
        XCTAssertFalse(b.revoke(ta)); XCTAssertFalse(b.acknowledgeQuiescence(ta))
        XCTAssertFalse(try b.commit(ta, index: 0) { XCTFail("Foreign job published") })
        XCTAssertTrue(try b.commit(tb, index: 0) {})
    }
    func testVerifiedSparseChunksSurviveRecoveryWithoutMovingTheCursorPastAHole() throws {
        let fence = try fence([0, 2]), token = try fence.begin()
        XCTAssertEqual(fence.verifiedPrefix, 1)
        XCTAssertFalse(try fence.commit(token, index: 2) { XCTFail("Duplicate publication") })
        XCTAssertTrue(try fence.commit(token, index: 1) {})
        XCTAssertEqual(fence.verifiedPrefix, 3)
        XCTAssertEqual(fence.verifiedChunks, [0, 1, 2])
    }
    func testThrowingCommitDoesNotAdvanceRecoveryAndStopPreventsResurrection() throws {
        let fence = try fence(), token = try fence.begin()
        XCTAssertThrowsError(try fence.commit(token, index: 0) { throw SpeechAttemptFailure.invalidCheckpoint })
        XCTAssertEqual(fence.verifiedPrefix, 0)
        fence.stop()
        XCTAssertFalse(try fence.commit(token, index: 0) {})
        XCTAssertTrue(fence.acknowledgeQuiescence(token))
        XCTAssertThrowsError(try fence.begin())
    }
    func testCommitAlreadyInsideFinalTransactionSurvivesSubsequentRevocation() throws {
        let fence = try fence(), token = try fence.begin()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let committed = DispatchSemaphore(value: 0), revoked = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { committed.signal() }
            do {
                XCTAssertTrue(try fence.commit(token, index: 0) {
                    entered.signal(); _ = release.wait(timeout: .now() + 2)
                })
            } catch { XCTFail("Commit failed: \(error)") }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async { XCTAssertTrue(fence.revoke(token)); revoked.signal() }
        XCTAssertEqual(revoked.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        XCTAssertEqual(committed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(revoked.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(fence.verifiedPrefix, 1)
        XCTAssertFalse(try fence.commit(token, index: 1) {})
    }
    func testBoundsAndPersistedEpochExhaustionFailClosed() throws {
        XCTAssertThrowsError(try fence([-1]))
        let fullEpoch = try SpeechAttemptFence(batch: UUID(), job: UUID(), lastEpoch: .max)
        XCTAssertThrowsError(try fullEpoch.begin())
        let fence = try fence(), token = try fence.begin()
        XCTAssertThrowsError(try fence.commit(token, index: SpeechAttemptFence.maximumChunks) {})
        XCTAssertEqual(fence.verifiedPrefix, 0)
    }
}
