import XCTest
import NarrationCore
@testable import LibroCore

final class TextPreparationWorkerPreferenceTests: XCTestCase {
    func testAutomaticAndManualLimitsPersistWithoutTouchingVoiceSettings() throws {
        let suite = "CPU text preparation fixture \(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = TextPreparationWorkerPreference(defaults: defaults)
        XCTAssertEqual(preference.load(), 0)
        preference.save(12)
        XCTAssertEqual(TextPreparationWorkerPreference(defaults: defaults).load(), 12)
        XCTAssertEqual(CPUTextPreparation.resolvedWorkers(preference: 12), min(12, CPUTextPreparation.automaticWorkers))
        preference.save(0); XCTAssertEqual(preference.load(), 0)
        XCTAssertEqual(CPUTextPreparation.resolvedWorkers(preference: 0), CPUTextPreparation.automaticWorkers)
        XCTAssertNil(defaults.object(forKey: SpeechSettingsPreference.key))
    }
    func testInvalidValuesAreNotSilentlyRewritten() throws {
        let suite = "CPU invalid preference fixture \(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = TextPreparationWorkerPreference(defaults: defaults)
        for invalid in [-1, 33, Int.max] {
            defaults.set(invalid, forKey: TextPreparationWorkerPreference.key)
            XCTAssertEqual(preference.load(), 0)
            preference.save(-1)
            XCTAssertEqual(defaults.integer(forKey: TextPreparationWorkerPreference.key), invalid)
        }
    }
}
