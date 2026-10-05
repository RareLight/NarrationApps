import XCTest
@testable import LibroCore

final class NativeAssetsTests: XCTestCase {
    func testWorkspaceCannotPutAssetsInsideSignedApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Libro.app/Contents/Resources")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try NativeWorkspace(root: app))
        let workspace = try NativeWorkspace(root: root)
        XCTAssertThrowsError(try workspace.contained(app.appendingPathComponent("models/weight")))
    }

    func testMissingAndPartialG2PFailBeforeRuntimeLoading() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try NativeWorkspace(root: root)
        XCTAssertThrowsError(try NativeG2P.validate(directory: workspace.g2pDirectory, workspace: workspace))
        try FileManager.default.createDirectory(at: workspace.g2pDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: workspace.g2pDirectory.appendingPathComponent("us_gold.json"))
        XCTAssertThrowsError(try NativeG2P.validate(directory: workspace.g2pDirectory, workspace: workspace))
    }

    func testSymlinkCannotReachAnotherWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try NativeWorkspace(root: root)
        let link = root.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.deletingLastPathComponent())
        XCTAssertThrowsError(try workspace.contained(link.appendingPathComponent("asset")))
    }
}
