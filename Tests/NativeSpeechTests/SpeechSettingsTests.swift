import XCTest
@testable import NarrationCore
@testable import DocumentProcessing
@testable import NativeSpeech
@testable import AudioOutput
@testable import ProcessingPipeline

final class SpeechSettingsTests: XCTestCase {
    func testCatalogDefaultsAndSopranoHint() {
        let defaults = SpeechSettings()
        XCTAssertEqual(defaults.model, .kokoro)
        XCTAssertEqual(defaults.voice, "af_heart")
        XCTAssertEqual(defaults.speed, 1.0)
        XCTAssertTrue(NativePrimaryCatalog.specification(for: .kokoro).voices.contains(defaults.voice))
        XCTAssertEqual(SpeechSettings(voice: "af_aoede").voice, "af_aoede")
        XCTAssertEqual(SpeechModel.soprano.repository, "mlx-community/Soprano-1.1-80M-bf16")
    }
}


extension SpeechSettingsTests {
    func testCommonSpeedRangePreservesValidValuesAndRejectsNonfiniteSpeeds() {
        for speed in [0.5, 0.75, 1.0, 1.1, 1.137, 1.25, 1.5, 2.0] { XCTAssertTrue(SpeechSpeedPolicy.contains(speed)) }
        for speed in [0.49, 2.01, Double.nan, .infinity, -.infinity] { XCTAssertFalse(SpeechSpeedPolicy.contains(speed)) }
        XCTAssertEqual(SpeechSpeedPolicy.step, 0.05)
        XCTAssertEqual(SpeechSettings().speed, 1.0)
    }

    func testSavedSpeedAndAdmittedSettingsDoNotAdoptNewDefaults() throws {
        let saved = Data(#"{"model":"kokoro","voice":"am_michael","speed":1.1}"#.utf8)
        let settings = try JSONDecoder().decode(SpeechSettings.self, from: saved)
        XCTAssertEqual(settings.voice, "am_michael")
        XCTAssertEqual(settings.speed, 1.1)
        XCTAssertEqual(try JSONDecoder().decode(SpeechSettings.self, from: JSONEncoder().encode(settings)), settings)
        XCTAssertEqual(VoiceSamples.sample(model: .kokoro, voice: "af_heart")?.settings, SpeechSettings())
    }

    func testVoiceMetadataCoversBothAppsWithoutLosingUnknownIdentifiers() {
        for voice in NativePrimaryCatalog.specification(for: .kokoro).voices {
            XCTAssertNotNil(VoiceCatalogPresentation.overallGrade(voice))
            XCTAssertFalse(VoiceCatalogPresentation.displayName(voice).contains("_"))
        }
        XCTAssertEqual(VoiceCatalogPresentation.displayName("af_heart"), "Heart · Female")
        XCTAssertEqual(VoiceCatalogPresentation.displayName("bm_george"), "George · Male")
        XCTAssertEqual(VoiceCatalogPresentation.displayName("future_voice"), "future_voice")
        XCTAssertTrue(VoiceCatalogPresentation.isRecommended("bf_emma"))
        XCTAssertFalse(VoiceCatalogPresentation.isRecommended("future_voice"))
        XCTAssertEqual(VoiceCatalogPresentation.ranked(["future_voice", "bm_george", "af_aoede", "af_bella"]),
                       ["af_bella", "af_aoede", "bm_george", "future_voice"])
    }
    func testVoiceQualityOrderRecommendationsAndAvailableSubsets() {
        let available = NativePrimaryCatalog.specification(for: .kokoro).voices
        let expected = [
            "af_heart", "af_bella", "bf_emma", "af_nicole",
            "af_aoede", "am_fenrir", "af_kore", "am_michael", "am_puck", "af_sarah",
            "af_alloy", "bm_fable", "bm_george", "bf_isabella", "af_nova",
            "af_sky", "bm_lewis", "bf_alice", "bm_daniel", "am_echo", "am_eric",
            "af_jessica", "am_liam", "bf_lily", "am_onyx", "af_river", "am_santa", "am_adam",
        ]
        XCTAssertEqual(VoiceCatalogPresentation.ranked(available.reversed()), expected)
        XCTAssertEqual(Set(expected), Set(available))
        XCTAssertTrue(available.allSatisfy { VoiceCatalogPresentation.overallGrade($0) != nil })
        XCTAssertEqual(expected.filter { VoiceCatalogPresentation.isRecommended($0) }, ["af_heart", "af_bella", "bf_emma", "af_nicole"])
        XCTAssertEqual(VoiceCatalogPresentation.name("af_heart"), "Heart")
        XCTAssertEqual(VoiceCatalogPresentation.overallGrade("af_aoede"), "C+")
        XCTAssertEqual(VoiceCatalogPresentation.name("future_voice"), "future_voice")
        XCTAssertFalse(VoiceCatalogPresentation.isRecommended("future_voice"))
        XCTAssertEqual(VoiceCatalogPresentation.ranked(["future_voice", "bm_george", "af_aoede", "af_bella"]),
                       ["af_bella", "af_aoede", "bm_george", "future_voice"])
        XCTAssertEqual(VoiceCatalogPresentation.ranked([]), [])
        XCTAssertTrue(VoiceCatalogPresentation.help("af_heart").contains("Recommended"))
    }


}
