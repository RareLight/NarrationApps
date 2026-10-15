import XCTest
@testable import NarrationCore
@testable import DocumentProcessing
@testable import NativeSpeech
@testable import AudioOutput
@testable import ProcessingPipeline

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

extension NativeAssetsTests {
    func testBritishAssetsAreSeparatePinnedAndMissingDoesNotAcceptUSFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try NativeWorkspace(root: root)
        XCTAssertNotEqual(workspace.g2pDirectory, BritishG2P.directory(in: workspace))
        XCTAssertEqual(BritishG2P.requiredFiles.count, 4)
        XCTAssertTrue(BritishG2P.requiredFiles.allSatisfy { $0.path.hasPrefix("gb_") && $0.hash.count == 64 && $0.bytes > 0 })
        XCTAssertThrowsError(try workspace.pronunciationDirectory(for: .init(voice: "bf_emma"))) {
            XCTAssertTrue($0.localizedDescription.contains("gb_"))
        }
        XCTAssertTrue(ModelPreparationProgress(scope: .g2p, phase: .downloading, completedBytes: 1, totalBytes: BritishG2P.totalBytes).isValid(for: .kokoro))
        XCTAssertFalse(ModelPreparationProgress(scope: .g2p, phase: .downloading, completedBytes: 1, totalBytes: BritishG2P.totalBytes).isValid(for: .soprano))
    }
    func testPreparedFrontendRecordsCorrectedSubtokenAlignment() {
        let current = SpeechAcousticIdentity.provenance(settings: .init(), policy: .current)
        XCTAssertTrue(current["frontend"]?.contains("subtoken-ranges-1") == true)
        let legacy = SpeechAcousticIdentity.provenance(settings: .init(), policy: .legacy)
        XCTAssertFalse(legacy["frontend"]?.contains("subtoken-ranges-1") == true)
    }

    func testPausePolicyDoesNotInvalidateRawAcousticIdentity() {
        let settings = SpeechSettings()
        XCTAssertEqual(SpeechAcousticIdentity.make(settings: settings, policy: .longformCandidate),
                       SpeechAcousticIdentity.make(settings: settings, policy: .longformPausesCandidate))
        XCTAssertNotEqual(SpeechAcousticIdentity.make(settings: settings, policy: .legacy),
                          SpeechAcousticIdentity.make(settings: settings, policy: .longformCandidate))
    }
}
