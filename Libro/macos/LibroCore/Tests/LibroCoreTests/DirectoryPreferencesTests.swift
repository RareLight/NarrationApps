import XCTest
@testable import LibroCore

final class DirectoryPreferencesTests: XCTestCase {
    func testMovedBookmarkRefreshesResolvedIdentity() throws {
        let suite = "LibroTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let old = root.appendingPathComponent("Old")
        let moved = root.appendingPathComponent("Moved")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = DirectoryPreferences(defaults: defaults)
        try preferences.select(old, role: .output)
        try FileManager.default.moveItem(at: old, to: moved)
        let restored = try XCTUnwrap(preferences.load(.output))
        XCTAssertEqual(restored.url?.lastPathComponent, "Moved")
        XCTAssertTrue(restored.displayPath.hasSuffix("/Moved"))
        XCTAssertNil(restored.error)
        XCTAssertEqual(DirectoryPreferences(defaults: defaults).load(.output)?.displayPath, restored.displayPath)
    }

    func testRestorationReplacementAndMissingDestinationIdentity() throws {
        let suite = "LibroTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let one = root.appendingPathComponent("First")
        let two = root.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: two, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = DirectoryPreferences(defaults: defaults)
        XCTAssertNil(preferences.load(.output))
        try preferences.select(one, role: .output)
        XCTAssertEqual(DirectoryPreferences(defaults: defaults).load(.output)?.url?.lastPathComponent, "First")
        // A cancelled Browse makes no store call; a failed replacement preserves it.
        XCTAssertThrowsError(try preferences.select(root.appendingPathComponent("absent"), role: .output))
        XCTAssertEqual(preferences.load(.output)?.url?.lastPathComponent, "First")
        try preferences.select(two, role: .output)
        XCTAssertEqual(preferences.load(.output)?.url?.lastPathComponent, "Second")
        let rememberedPath = preferences.load(.output)?.displayPath
        try FileManager.default.removeItem(at: two)
        let missing = try XCTUnwrap(DirectoryPreferences(defaults: defaults).load(.output))
        XCTAssertEqual(missing.displayPath, rememberedPath)
        XCTAssertNil(missing.url)
        XCTAssertNotNil(missing.error)
        XCTAssertNil(preferences.load(.workspace))
    }
}
