import XCTest
@testable import LibroCore

final class SpeechSettingsPreferenceTests: XCTestCase {
    func testSettingsRoundTripAcrossInstancesAndSopranoRetainsKokoroChoices() throws {
        let suite = "Libro settings fixture \(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = SpeechSettingsPreference(defaults: defaults)
        XCTAssertEqual(preference.load(), .init())
        for model in SpeechModel.allCases {
            let value = SpeechSettings(model: model, voice: "bf_emma", speed: 1.35)
            preference.save(value)
            XCTAssertEqual(SpeechSettingsPreference(defaults: defaults).load(), value)
        }
    }
    func testInvalidOrUnsupportedRecordsAreNotRewrittenOnLoadOrInvalidSave() throws {
        let suite = "Libro invalid settings fixture \(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = SpeechSettingsPreference(defaults: defaults)
        for text in ["corrupt", "{}", "{\"model\":\"future\",\"voice\":\"bf_emma\",\"speed\":1}",
                     "{\"model\":\"kokoro\",\"voice\":\"unknown\",\"speed\":1}",
                     "{\"model\":\"kokoro\",\"voice\":\"af_heart\",\"speed\":20}"] {
            let data = Data(text.utf8)
            defaults.set(data, forKey: SpeechSettingsPreference.key)
            XCTAssertEqual(preference.load(), .init())
            preference.save(.init(speed: .nan))
            XCTAssertEqual(defaults.data(forKey: SpeechSettingsPreference.key), data)
        }
    }
}
