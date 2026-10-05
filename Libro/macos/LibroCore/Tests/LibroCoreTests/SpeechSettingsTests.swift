import XCTest
@testable import LibroCore

final class SpeechSettingsTests: XCTestCase {
    func testCatalogDefaultsAndSopranoHint() {
        let defaults = SpeechSettings()
        XCTAssertEqual(defaults.model, .kokoro)
        XCTAssertEqual(defaults.voice, "af_aoede")
        XCTAssertEqual(defaults.speed, 1.1)
        XCTAssertEqual(SpeechModel.soprano.repository, "mlx-community/Soprano-1.1-80M-bf16")
    }
}
