import XCTest
import Foundation
@testable import ProcessingPipeline

final class SpeechWorkStatusTests: XCTestCase {
    private final class Events: @unchecked Sendable {
        let lock = NSLock(); private var stored: [SpeechWorkStatus] = []
        var values: [SpeechWorkStatus] { lock.withLock { stored } }
        func append(_ value: SpeechWorkStatus) { lock.withLock { stored.append(value) } }
    }
    func testReporterCoalescesDuplicatesAndProjectionRejectsReorderedEvents() throws {
        let events = Events(), reporter = SpeechWorkStatusReporter { events.append($0) }
        reporter.update(.api); reporter.update(.api); reporter.update(nil)
        let values = events.values
        XCTAssertEqual(values.count, 2); XCTAssertEqual(values.map(\.sequence), [1, 2])
        var projection = SpeechWorkStatusProjection()
        XCTAssertTrue(projection.receive(try XCTUnwrap(values.last)))
        XCTAssertFalse(projection.receive(try XCTUnwrap(values.first)))
        XCTAssertNil(projection.reason)
    }
    func testOneResumedSourceCannotClearAnotherSuspendedSource() {
        let speech = UUID(), validation = UUID()
        var projection = SpeechWorkStatusProjection()
        projection.receive(.init(source: speech, sequence: 1, reason: .api))
        projection.receive(.init(source: validation, sequence: 1, reason: .libro))
        XCTAssertEqual(projection.reason?.statusLabel, "Waiting for VoiceServer")
        projection.receive(.init(source: validation, sequence: 2, reason: nil))
        XCTAssertEqual(projection.reason, .api)
        projection.receive(.init(source: speech, sequence: 2, reason: nil))
        XCTAssertNil(projection.reason)
        XCTAssertFalse(projection.receive(.init(source: speech, sequence: 1, reason: .api)))
    }
}
