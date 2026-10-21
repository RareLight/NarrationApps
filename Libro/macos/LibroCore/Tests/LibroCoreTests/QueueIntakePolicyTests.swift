import XCTest
@testable import LibroCore

final class QueueIntakePolicyTests: XCTestCase {
    func testProcessingChoicesKeepExistingFilesUntilExplicitOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inputs = ["Existing.txt", "New.txt"].map {
            InputDocument(source: root.appendingPathComponent($0), kind: .text, relativePath: $0)
        }
        let destination = root.appendingPathComponent("Existing.wav")
        let original = Data("keep this completed audio".utf8)
        try original.write(to: destination)
        let plans = try BatchPlanner.plan(inputs, output: root)
        let skip = try XCTUnwrap(QueueProcessingSelection(plans: plans, choice: .skip))
        XCTAssertEqual(skip.documents.map(\.id), [inputs[1].id])
        XCTAssertEqual(skip.skipped, [inputs[0].id])
        XCTAssertFalse(skip.replaceExisting)
        let replace = try XCTUnwrap(QueueProcessingSelection(plans: plans, choice: .overwrite))
        let request = BatchRequest(documents: replace.documents, outputDirectory: root, workspace: root,
            settings: .init(), replaceExisting: replace.replaceExisting)
        XCTAssertEqual(request.approvedReplacements, [inputs[0].id])
        XCTAssertEqual(replace.documents.map(\.id), inputs.map(\.id))
        XCTAssertNil(QueueProcessingSelection(plans: plans, choice: .cancel))
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertTrue(try XCTUnwrap(QueueProcessingSelection(plans: [plans[0]], choice: .skip)).documents.isEmpty)
        // Files created after queue planning appear in the fresh batch-start plan.
        try Data("late audio".utf8).write(to: root.appendingPathComponent("New.wav"))
        let refreshed = try BatchPlanner.plan(inputs, output: root)
        XCTAssertTrue(try XCTUnwrap(QueueProcessingSelection(plans: refreshed, choice: .skip)).documents.isEmpty)
        XCTAssertFalse(request.approvedReplacements.contains(inputs[1].id))
    }

    func testExplicitReadditionDoesNotRequeueUnrelatedOrActiveSources() {
        let root = URL(fileURLWithPath: "/private/tmp/queue-policy")
        let documents = ["old.txt", "book.epub", "folder/chapter.md", "folder-other.txt"].map {
            InputDocument(source: root.appendingPathComponent($0), kind: DocumentKind.identify(root.appendingPathComponent($0))!, relativePath: $0)
        }
        XCTAssertEqual(QueueIntakePolicy.requeuedIDs(documents: documents, selected: [documents[1].source], active: []), [documents[1].id])
        XCTAssertEqual(QueueIntakePolicy.requeuedIDs(documents: documents, selected: [root.appendingPathComponent("folder")], active: []), [documents[2].id])
        XCTAssertEqual(QueueIntakePolicy.requeuedIDs(documents: documents, selected: [root], active: [documents[0].id]), Set(documents.dropFirst().map(\.id)))
    }
}
