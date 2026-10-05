import XCTest
@testable import LibroCore

final class CompletionNoticeTests: XCTestCase {
    private func outcome(_ state: DocumentOutcome.State) -> DocumentOutcome {
        .init(id: UUID(), state: state, destination: URL(fileURLWithPath: "/private/secret-document.wav"),
              message: "Private filename and narration never belong in notifications.")
    }
    func testPrivateContentCountsAndDuplicateOrLateCompletion() throws {
        var ledger = CompletionNoticeLedger()
        let summary = BatchSummary(id: UUID(), documents: [outcome(.published), outcome(.failed)], cancelled: false)
        let notice = try XCTUnwrap(ledger.finish(summary, authorized: true))
        XCTAssertEqual(notice.title, "Libro processing complete")
        XCTAssertEqual(notice.body, "Documents saved: 1. Failed: 1.")
        XCTAssertEqual(notice.successfulCount, 1)
        XCTAssertEqual(notice.failedCount, 1)
        XCTAssertFalse(notice.body.contains("secret"))
        XCTAssertNil(ledger.finish(summary, authorized: true))
    }
    func testDeniedAuthorizationAndCancellationNeverAnnounceSuccessLater() {
        var ledger = CompletionNoticeLedger()
        let denied = BatchSummary(id: UUID(), documents: [outcome(.published)], cancelled: false)
        XCTAssertNil(ledger.finish(denied, authorized: false))
        XCTAssertNil(ledger.finish(denied, authorized: true))
        let cancelled = BatchSummary(id: UUID(), documents: [outcome(.published), outcome(.cancelled)], cancelled: true)
        XCTAssertNil(ledger.finish(cancelled, authorized: true))
        let late = BatchSummary(id: cancelled.id, documents: [outcome(.published)], cancelled: false)
        XCTAssertNil(ledger.finish(late, authorized: true))
        let failed = BatchSummary(id: UUID(), documents: [outcome(.failed)], cancelled: false)
        XCTAssertEqual(ledger.finish(failed, authorized: true)?.body, "Documents saved: 0. Failed: 1.")
    }
}
