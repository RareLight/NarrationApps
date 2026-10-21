import XCTest
@testable import LibroCore

final class QueueOrderingTests: XCTestCase {
    func testDiscontiguousMovesUseNativeInsertionIndicesAndPreserveSelectionOrder() {
        let rows = (0..<5).map { _ in UUID() }
        XCTAssertEqual(QueueOrdering.moving(rows, ids: [rows[1], rows[3]], to: 5), [rows[0], rows[2], rows[4], rows[1], rows[3]])
        XCTAssertEqual(QueueOrdering.moving(rows, ids: [rows[3], rows[4]], to: 0), [rows[3], rows[4], rows[0], rows[1], rows[2]])
        XCTAssertEqual(QueueOrdering.moving(rows, ids: [rows[1]], to: 2), rows)
        XCTAssertNil(QueueOrdering.moving(rows, ids: [UUID()], to: 0))
        XCTAssertNil(QueueOrdering.moving(rows, ids: [rows[0]], to: 6))
        XCTAssertEqual(QueueOrdering.retainingOrder([rows[3], rows[1], rows[0]], discovered: [rows[0], rows[1], rows[2], rows[4]]), [rows[1], rows[0], rows[2], rows[4]])
    }
    func testReorderedProgressAcceptsNewNextAndRejectsCompletedOrLateUpdates() {
        let batch = UUID(), jobs = (0..<3).map { _ in UUID() }
        var progress = BatchActivityProgress(batch: batch, jobs: jobs)
        XCTAssertTrue(progress.beginSpeech(job: jobs[0]))
        progress.reorderPending(jobs: [jobs[0], jobs[2], jobs[1]])
        XCTAssertTrue(progress.beginPreparation(job: jobs[2]))
        XCTAssertFalse(progress.beginSpeech(job: jobs[0]))
        XCTAssertTrue(progress.beginPreparation(job: jobs[1]))
        XCTAssertFalse(progress.beginSpeech(job: jobs[2]))
    }
    func testRunningBatchMovesOnlyWaitingRowsWithinTheirCapturedMembership() {
        let rows = (0..<6).map { _ in UUID() }, activeCount = 4
        let active = Array(rows.prefix(activeCount)), pending = Set(rows[2...3])
        XCTAssertEqual(QueueOrdering.moving(rows, ids: [rows[3]], to: 2, active: active, pending: pending), [rows[0], rows[1], rows[3], rows[2], rows[4], rows[5]])
        XCTAssertNil(QueueOrdering.moving(rows, ids: [rows[3]], to: 0, active: active, pending: pending))
        XCTAssertNil(QueueOrdering.moving(rows, ids: [rows[0]], to: 3, active: active, pending: pending))
        XCTAssertNil(QueueOrdering.moving(rows, ids: [rows[4]], to: 2, active: active, pending: pending))
        XCTAssertEqual(QueueOrdering.moving(rows, ids: [rows[5]], to: 4, active: active, pending: pending), [rows[0], rows[1], rows[2], rows[3], rows[5], rows[4]])
    }
    func testStatusLabelsKeepCountsAndUseConciseAnalysisLanguage() {
        XCTAssertEqual(QueueStatusPresentation.preparation(.init(stage: .extractingText, completed: 2, total: 10)), "Analyzing text 2/10")
        XCTAssertEqual(QueueStatusPresentation.preparation(.init(stage: .waitingForOCR)), "Waiting for analysis…")
        XCTAssertEqual(QueueStatusPresentation.preparation(.init(stage: .phonemizing)), "Preparing pronunciation…")
    }
}
