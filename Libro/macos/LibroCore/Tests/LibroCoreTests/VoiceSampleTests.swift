import XCTest
@testable import LibroCore

final class VoiceSampleTests: XCTestCase {
    func testAvailableEnglishVoicesAndSopranoHaveBundledSamples() throws {
        let voices = NativePrimaryCatalog.specification(for: .kokoro).voices
        for voice in VoicePresentation.ranked(voices) {
            let sample = try XCTUnwrap(VoiceSamples.sample(model: .kokoro, voice: voice))
            XCTAssertEqual(sample.name, VoicePresentation.name(voice))
            XCTAssertNotNil(sample.url)
        }
        XCTAssertNotNil(VoiceSamples.sample(model: .soprano, voice: SpeechSettings.defaultKokoroVoice)?.url)
    }
}
