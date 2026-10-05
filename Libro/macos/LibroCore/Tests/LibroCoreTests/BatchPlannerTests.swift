import XCTest
@testable import LibroCore

final class BatchPlannerTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, output)
    }

    private func input(_ root: URL, name: String, relative: String? = nil) throws -> InputDocument {
        let source = root.appendingPathComponent(name)
        try Data("Narration.".utf8).write(to: source)
        return InputDocument(source: source, kind: DocumentKind.identify(source)!, relativePath: relative ?? name)
    }

    func testRelativeNamingExplicitConflictAndResolution() throws {
        let (root, output) = try fixture()
        let one = try input(root, name: "Notes.wav.txt", relative: "Book/Part/Notes.wav.txt")
        let two = try input(root, name: "Notes.pdf", relative: "Book/Part/Notes.pdf")
        XCTAssertEqual(BatchPlanner.defaultOutput(one), "Book/Part/Notes.wav")
        XCTAssertThrowsError(try BatchPlanner.plan([one, two], output: output))
        let plan = try BatchPlanner.plan([one, two], output: output, names: [two.id: "Book/Part/Notes-2.wav"])
        XCTAssertEqual(plan.map(\.relativeOutput), ["Book/Part/Notes.wav", "Book/Part/Notes-2.wav"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("Book").path))
        XCTAssertThrowsError(try BatchPlanner.plan([one], output: output, names: [one.id: "../escape.wav"]))
        XCTAssertThrowsError(try BatchPlanner.plan([one, two], output: output, names: [one.id: "Folder.wav", two.id: "Folder.wav/chapter.wav"]))
    }

    func testCaseUnicodeSymlinkAndHardlinkAliases() throws {
        let (root, output) = try fixture()
        let one = try input(root, name: "one.txt")
        let two = try input(root, name: "two.md")
        for names in [[one.id: "Café.wav", two.id: "CAFE\u{301}.wav"], [one.id: "Name.wav", two.id: "NAME.wav"], [one.id: "Straße.wav", two.id: "STRASSE.wav"]] {
            XCTAssertThrowsError(try BatchPlanner.plan([one, two], output: output, names: names))
        }
        let target = output.appendingPathComponent("target.wav")
        try Data([1, 2]).write(to: target)
        try FileManager.default.createSymbolicLink(at: output.appendingPathComponent("alias.wav"), withDestinationURL: target)
        XCTAssertThrowsError(try BatchPlanner.plan([one, two], output: output, names: [one.id: "target.wav", two.id: "alias.wav"]))
        try FileManager.default.linkItem(at: one.source, to: output.appendingPathComponent("input.wav"))
        XCTAssertThrowsError(try BatchPlanner.plan([one], output: output, names: [one.id: "input.wav"]))
        try FileManager.default.createSymbolicLink(at: output.appendingPathComponent("outside"), withDestinationURL: root)
        XCTAssertThrowsError(try BatchPlanner.plan([one], output: output, names: [one.id: "outside/new.wav"]))
    }

    func testMissingDestinationMustNotBeSubstitutedAndPublicationRevalidation() throws {
        let (root, output) = try fixture()
        let one = try input(root, name: "one.txt")
        XCTAssertThrowsError(try BatchPlanner.plan([one], output: root.appendingPathComponent("missing")))
        let plan = try BatchPlanner.plan([one], output: output)
        XCTAssertFalse(plan[0].replacesExisting)
        try FileManager.default.createSymbolicLink(at: plan[0].destination, withDestinationURL: one.source)
        XCTAssertThrowsError(try BatchPlanner.plan([one], output: output))
        XCTAssertEqual(try String(contentsOf: one.source, encoding: .utf8), "Narration.")
    }

    func testImmutableBatchSettingsAndExistingOutputFlag() throws {
        let (root, output) = try fixture()
        let one = try input(root, name: "one.txt")
        let existing = output.appendingPathComponent("one.wav")
        try Data("Previous complete audio".utf8).write(to: existing)
        let planned = try BatchPlanner.plan([one], output: output)
        XCTAssertTrue(planned[0].replacesExisting)
        var settings = SpeechSettings()
        let request = BatchRequest(documents: planned, outputDirectory: output, workspace: root, settings: settings, serial: false)
        settings.model = .soprano; settings.speed = 2
        XCTAssertEqual(request.settings, SpeechSettings())
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "Previous complete audio")
    }
}
