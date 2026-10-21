import XCTest
@testable import LibroCore

final class AudioOutputPreferenceTests: XCTestCase {
    func testPreferenceDefaultsRestoresAndRejectsUnknownValues() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = OutputFormatPreference(defaults: defaults)
        XCTAssertEqual(preference.load(), .wav)
        for format in AudioOutputFormat.allCases {
            preference.save(format)
            XCTAssertEqual(OutputFormatPreference(defaults: defaults).load(), format)
        }
        defaults.set("unknown", forKey: "LibroOutputFormat")
        XCTAssertEqual(preference.load(), .wav)
    }

}
