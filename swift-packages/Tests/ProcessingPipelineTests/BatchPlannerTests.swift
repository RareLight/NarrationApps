import XCTest
@testable import NarrationCore
@testable import DocumentProcessing
@testable import NativeSpeech
@testable import AudioOutput
@testable import ProcessingPipeline

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
        let request = BatchRequest(documents: planned, outputDirectory: output, workspace: root, settings: settings)
        settings.model = .soprano; settings.speed = 2
        XCTAssertEqual(request.settings, SpeechSettings())
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "Previous complete audio")
    }
    func testDirectorySourcesProtectExistingAndNewDescendantsAndAliases() throws {
        let (root, _) = try fixture()
        let book = root.appendingPathComponent("book.epub")
        let resources = book.appendingPathComponent("EPUB")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let input = InputDocument(source: book, kind: .epub, relativePath: "book.epub")
        let bytes = Data("original book resource".utf8)
        try bytes.write(to: resources.appendingPathComponent("existing.wav"))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: resources)
        for output in [resources, alias] {
            for name in ["existing.wav", "new.wav", "sub/new.wav"] {
                XCTAssertThrowsError(try BatchPlanner.plan([input], output: output, names: [input.id: name])) { error in
                    guard case PlanningError.protectedInput = error else { return XCTFail("Unexpected \(error)") }
                }
            }
        }
        XCTAssertEqual(try Data(contentsOf: resources.appendingPathComponent("existing.wav")), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resources.appendingPathComponent("sub").path))
    }

    func testPrefixConflictWithInterveningSiblingAndOriginalOrder() throws {
        let (root, output) = try fixture()
        let inputs = try ["z.txt", "a.txt", "b.txt"].map { try input(root, name: $0) }
        XCTAssertThrowsError(try BatchPlanner.plan(inputs, output: output, names: [
            inputs[0].id: "A.wav", inputs[1].id: "A.wav-other.wav", inputs[2].id: "A.wav/chapter.wav"]))
        let plan = try BatchPlanner.plan(inputs, output: output)
        XCTAssertEqual(plan.map(\.id), inputs.map(\.id))
    }

    func testValidationContextRefreshesSourceAndOutputIdentityAndBinding() throws {
        let (root, output) = try fixture()
        let one = try input(root, name: "one.txt"), two = try input(root, name: "two.txt")
        let plans = try BatchPlanner.plan([one, two], output: output)
        let context = try BatchPlanner.ValidationContext(.init(documents: plans, outputDirectory: output, workspace: root, settings: .init()))
        try context.validate(plans[0])
        // A selected source can be replaced while the batch runs. Its new inode
        // must still be protected, as must the original captured source tree.
        try FileManager.default.removeItem(at: two.source)
        try Data("new source".utf8).write(to: two.source)
        try FileManager.default.linkItem(at: two.source, to: plans[0].destination)
        XCTAssertThrowsError(try context.validate(plans[0])) { error in
            guard case PlanningError.protectedInput = error else { return XCTFail("Unexpected \(error)") }
        }
        try FileManager.default.removeItem(at: plans[0].destination)
        let moved = output.appendingPathComponent("moved.wav")
        try Data("unrelated completed output".utf8).write(to: moved)
        try FileManager.default.createSymbolicLink(at: plans[0].destination, withDestinationURL: moved)
        XCTAssertThrowsError(try context.validate(plans[0])) { error in
            guard case PlanningError.invalidDestination = error else { return XCTFail("Unexpected \(error)") }
        }
    }

    func testLargeBatchUsesOnePlanAndCurrentTargetValidationInOriginalOrder() throws {
        let (root, output) = try fixture()
        let inputs = try (0..<1200).map { try input(root, name: "source-\($0).txt") }
        let start = ContinuousClock.now
        let plans = try BatchPlanner.plan(inputs, output: output)
        let planning = start.duration(to: .now)
        let context = try BatchPlanner.ValidationContext(.init(documents: plans, outputDirectory: output, workspace: root, settings: .init()))
        let validationStart = ContinuousClock.now
        for index in [0, 599, 1199] { try context.validate(plans[index]) }
        XCTAssertEqual(plans.map(\.id), inputs.map(\.id))
        print("Synthetic 1200-input Debug planner: \(planning); three current-target validations: \(validationStart.duration(to: .now))")
    }

    func testValidationRejectsLateHardlinksBetweenApprovedOutputs() throws {
        let (root, output) = try fixture()
        let inputs = try ["one.txt", "two.txt"].map { try input(root, name: $0) }
        for input in inputs { try Data("complete output".utf8).write(to: output.appendingPathComponent(BatchPlanner.defaultOutput(input))) }
        let plans = try BatchPlanner.plan(inputs, output: output)
        let context = try BatchPlanner.ValidationContext(.init(documents: plans, outputDirectory: output,
            workspace: root, settings: .init(), replaceExisting: true))
        try FileManager.default.removeItem(at: plans[1].destination)
        try FileManager.default.linkItem(at: plans[0].destination, to: plans[1].destination)
        XCTAssertThrowsError(try context.validate(plans[0])) { error in
            guard case PlanningError.collision = error else { return XCTFail("Unexpected \(error)") }
        }
    }

}
