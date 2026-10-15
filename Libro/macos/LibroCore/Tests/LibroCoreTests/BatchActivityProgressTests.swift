import XCTest
@testable import LibroCore

final class BatchActivityProgressTests: XCTestCase {
    func testDelayedUpdatesCannotRegressDocumentPhaseOrBatch() {
        let batch = UUID(), first = UUID(), second = UUID()
        var state = BatchActivityProgress(batch: batch, jobs: [first, second])
        let page = DocumentPreparationProgress(stage: .recognizingText, completed: 4, total: 10, currentPage: 5)
        func update(_ job: UUID, _ sequence: Int, batch id: UUID? = nil) -> TextPreparationProgress {
            .init(batch: id ?? batch, job: job, sequence: sequence, progress: page)
        }
        XCTAssertTrue(state.beginPreparation(job: first))
        XCTAssertTrue(state.receive(update(first, 2)))
        XCTAssertFalse(state.receive(update(first, 1)))
        XCTAssertFalse(state.beginPreparation(job: first))
        XCTAssertEqual(state.preparation?.progress.completed, 4)
        XCTAssertFalse(state.receive(update(first, 3, batch: UUID())))
        XCTAssertTrue(state.beginSpeech(job: first))
        XCTAssertNil(state.preparation)
        XCTAssertFalse(state.receive(update(first, 3)))
        XCTAssertFalse(state.beginPreparation(job: first))
        XCTAssertTrue(state.beginPreparation(job: second))
        XCTAssertTrue(state.receive(update(second, 1)))
        XCTAssertFalse(state.beginSpeech(job: first))
        XCTAssertFalse(state.receive(update(first, 99)))
        XCTAssertEqual(state.preparation?.job, second)
        XCTAssertFalse(state.receive(update(UUID(), 100)))
    }
    func testCoalescedProgressCanArriveBeforeItsPreparingNotification() {
        let batch = UUID(), job = UUID()
        var state = BatchActivityProgress(batch: batch, jobs: [job])
        XCTAssertTrue(state.receive(.init(batch: batch, job: job, sequence: 8,
            progress: .init(stage: .planningNarration))))
        XCTAssertFalse(state.beginPreparation(job: job))
        XCTAssertEqual(state.preparation?.progress.stage, .planningNarration)
    }
}
