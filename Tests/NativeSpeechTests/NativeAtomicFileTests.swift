import XCTest
@testable import NarrationCore
@testable import DocumentProcessing
@testable import NativeSpeech
@testable import AudioOutput
@testable import ProcessingPipeline

final class NativeAtomicFileTests: XCTestCase {
    private func workspace() throws -> NativeWorkspace {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Native inventory \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try NativeWorkspace(root: root)
    }
    func testAtomicInventoryReplacementLeavesOnlyCompleteRecord() throws {
        let workspace = try workspace(); defer { try? FileManager.default.removeItem(at: workspace.root) }
        let destination = workspace.nativeRoot.appendingPathComponent("records/inventory.json")
        for content in [Data("previous".utf8), Data("replacement".utf8)] {
            try NativeAtomicFile.write(content, to: destination, workspace: workspace)
            XCTAssertEqual(try Data(contentsOf: destination), content)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), ["inventory.json"])
        }
    }
    func testObstructedPublicationPreservesPriorDataAndRemovesSibling() throws {
        let workspace = try workspace(); defer { try? FileManager.default.removeItem(at: workspace.root) }
        let destination = workspace.nativeRoot.appendingPathComponent("records/inventory.json")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let prior = destination.appendingPathComponent("prior.bin")
        try Data([1]).write(to: prior)
        XCTAssertThrowsError(try NativeAtomicFile.write(Data([2]), to: destination, workspace: workspace))
        XCTAssertEqual(try Data(contentsOf: prior), Data([1]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), ["inventory.json"])
    }
    func testUnsafeDestinationCannotChangeSharedFile() throws {
        let workspace = try workspace(); defer { try? FileManager.default.removeItem(at: workspace.root) }
        let shared = workspace.root.appendingPathComponent("models/config.json")
        try FileManager.default.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: shared)
        XCTAssertThrowsError(try NativeAtomicFile.write(Data([2]), to: shared, workspace: workspace))
        let alias = workspace.nativeRoot.appendingPathComponent("records/inventory.json")
        try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: shared)
        XCTAssertThrowsError(try NativeAtomicFile.write(Data([2]), to: alias, workspace: workspace))
        XCTAssertEqual(try Data(contentsOf: shared), Data([1]))
    }
}
