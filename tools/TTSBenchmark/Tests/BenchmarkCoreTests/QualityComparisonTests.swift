import XCTest
@testable import BenchmarkCore

final class QualityComparisonTests: XCTestCase {
    func testBlindComparisonNeverEmbedsIdentitiesAndPreservesLocalRuntime() throws {
        let html = try QualityComparison.page(pairs: [.init(id: 1, text: "Quoted <source> & text", a: "audio/abc.wav", b: "audio/def.wav")], identity: String(repeating: "a", count: 64))
        XCTAssertTrue(html.contains("Quoted &lt;source> &amp; text"))
        XCTAssertTrue(html.contains("Finish all comparisons before revealing identities"))
        XCTAssertTrue(html.contains("grid-template-columns:1fr 1fr"))
        for forbidden in ["Qwen", "Kokoro", "Ryan", "Heart", "fetch(", "http://", "https://", "WebSocket"] { XCTAssertFalse(html.contains(forbidden), forbidden) }
        XCTAssertThrowsError(try QualityComparison.page(pairs: [.init(id: 1, text: "Text", a: "model-name.wav", b: "audio/def.wav")], identity: String(repeating: "a", count: 64)))
    }
}
