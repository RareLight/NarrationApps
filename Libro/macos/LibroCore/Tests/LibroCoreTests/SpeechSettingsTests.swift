import XCTest
@testable import LibroCore

final class SpeechSettingsTests: XCTestCase {
    func testCatalogDefaultsAndSopranoHint() {
        let defaults = SpeechSettings()
        XCTAssertEqual(defaults.model, .kokoro)
        XCTAssertEqual(defaults.voice, "af_heart")
        XCTAssertEqual(defaults.speed, 1.1)
        XCTAssertTrue(NativePrimaryCatalog.specification(for: .kokoro).voices.contains(defaults.voice))
        XCTAssertEqual(SpeechSettings(voice: "af_aoede").voice, "af_aoede")
        XCTAssertEqual(SpeechModel.soprano.repository, "mlx-community/Soprano-1.1-80M-bf16")
    }
}
