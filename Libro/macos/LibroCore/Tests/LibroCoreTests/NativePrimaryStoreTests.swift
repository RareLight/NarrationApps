import XCTest
import CryptoKit
@testable import LibroCore

final class NativePrimaryStoreTests: XCTestCase {
    private let config = Data(#"{"hidden_dim":8}"#.utf8)
    private let tensor = Data("abc".utf8)
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private var specification: NativePrimarySpecification {
        .init(model: .kokoro, repository: SpeechModel.kokoro.repository, revision: String(repeating: "a", count: 40), files: [
            .init(path: "config.json", bytes: config.count, sha256: sha(config), gitOID: "fixture", compatibleKokoroConfigSHA256: sha(config)),
            .init(path: "kokoro-v1_0.safetensors", bytes: 3, sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", gitOID: "fixture"),
            .init(path: "voices/af_aoede.safetensors", bytes: 3, sha256: sha(tensor), gitOID: "fixture"),
            .init(path: "voices/bf_alice.safetensors", bytes: 3, sha256: sha(tensor), gitOID: "fixture")
        ])
    }
    private func workspace() throws -> NativeWorkspace {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Native primary \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try NativeWorkspace(root: root)
    }
    private func fixture(_ directory: URL, allVoices: Bool = true) throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("voices"), withIntermediateDirectories: true)
        try config.write(to: directory.appendingPathComponent("config.json"))
        try tensor.write(to: directory.appendingPathComponent("kokoro-v1_0.safetensors"))
        try tensor.write(to: directory.appendingPathComponent("voices/af_aoede.safetensors"))
        if allVoices { try tensor.write(to: directory.appendingPathComponent("voices/bf_alice.safetensors")) }
    }

    func testCatalogContainsExactPinnedRequiredScope() {
        let kokoro = NativePrimaryCatalog.specification(for: .kokoro)
        let soprano = NativePrimaryCatalog.specification(for: .soprano)
        XCTAssertEqual(kokoro.files.count, 30)
        XCTAssertEqual(kokoro.voices.count, 28)
        XCTAssertTrue(kokoro.voices.contains("af_aoede"))
        XCTAssertFalse(kokoro.files.contains { $0.path.hasSuffix(".pt") || $0.path.hasPrefix("samples/") })
        XCTAssertEqual(Set(soprano.files.map(\.path)), ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"])
        for item in [kokoro, soprano] {
            XCTAssertEqual(item.repository, item.model.repository)
            XCTAssertEqual(item.revision.count, 40)
            XCTAssertEqual(Set(item.files.map(\.path)).count, item.files.count)
            XCTAssertTrue(item.files.allSatisfy { $0.bytes > 0 && $0.sha256.count == 64 && $0.gitOID.count == 40 })
        }
    }

    func testSameLengthCorruptionAndMissingFilesCannotBeComplete() throws {
        let workspace = try workspace(); defer { try? FileManager.default.removeItem(at: workspace.root) }
        let directory = workspace.root.appendingPathComponent("snapshot")
        try fixture(directory)
        XCTAssertEqual(try NativePrimaryStore.validate(directory: directory, specification: specification, workspace: workspace).count, 4)
        try tensor.write(to: directory.appendingPathComponent("model.safetensors"))
        XCTAssertThrowsError(try NativePrimaryStore.validate(directory: directory, specification: specification, workspace: workspace, sharedVoice: "af_aoede"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("model.safetensors"))
        try Data("abx".utf8).write(to: directory.appendingPathComponent("kokoro-v1_0.safetensors"))
        XCTAssertThrowsError(try NativePrimaryStore.validate(directory: directory, specification: specification, workspace: workspace))
        try tensor.write(to: directory.appendingPathComponent("kokoro-v1_0.safetensors"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("voices/af_aoede.safetensors"))
        XCTAssertThrowsError(try NativePrimaryStore.validate(directory: directory, specification: specification, workspace: workspace, sharedVoice: "af_aoede"))
    }

    func testOnlyKnownKokoroConfigMetadataDifferenceIsCompatibleReadOnly() throws {
        let workspace = try workspace(); defer { try? FileManager.default.removeItem(at: workspace.root) }
        let directory = workspace.root.appendingPathComponent("snapshot")
        try fixture(directory)
        let adapted = Data("{\n  \"model_type\": \"kokoro\", \"hidden_dim\": 8\n}".utf8)
        try adapted.write(to: directory.appendingPathComponent("config.json"))
        XCTAssertEqual(try NativePrimaryStore.validate(directory: directory, specification: specification, workspace: workspace, sharedVoice: "af_aoede").count, 4)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("config.json")), adapted)
        XCTAssertThrowsError(try NativePrimaryStore.validate(directory: directory, specification: specification, workspace: workspace))
        for invalid in [#"{"model_type":"unknown","hidden_dim":8}"#, #"{"model_type":"kokoro","hidden_dim":9}"#, #"{"hidden_dim":8,"unexpected":true}"#] {
            try Data(invalid.utf8).write(to: directory.appendingPathComponent("config.json"))
            XCTAssertThrowsError(try NativePrimaryStore.validate(directory: directory, specification: specification, workspace: workspace, sharedVoice: "af_aoede"))
        }
    }

    func testSharedSnapshotInventoriesPresentVoicesAndWritesOnlyNativeMetadata() throws {
        let workspace = try workspace(); defer { try? FileManager.default.removeItem(at: workspace.root) }
        let directory = workspace.root.appendingPathComponent(SpeechModel.kokoro.primaryRelativePath)
        try fixture(directory, allVoices: false)
        XCTAssertEqual(try NativePrimaryStore.validate(directory: directory, specification: specification, workspace: workspace, sharedVoice: "af_aoede").count, 3)
        XCTAssertThrowsError(try NativePrimaryStore.validate(directory: directory, specification: specification, workspace: workspace, sharedVoice: "bf_alice"))
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try NativePrimaryStore.recordReuse(directory: directory, specification: specification, workspace: workspace, voice: "af_aoede")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), before)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("config.json")), config)
        XCTAssertEqual(try NativePrimaryStore.directory(specification: specification, workspace: workspace, voice: "af_aoede").path, directory.path)
        let metadata = try NativePrimaryStore.reuseRecordURL(specification, workspace: workspace)
        let bytes = try Data(contentsOf: metadata)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(workspace.root.path))
        var record = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        record["revision"] = String(repeating: "b", count: 40)
        try JSONSerialization.data(withJSONObject: record).write(to: metadata)
        XCTAssertThrowsError(try NativePrimaryStore.directory(specification: specification, workspace: workspace, voice: "af_aoede"))
    }

    func testNativeSnapshotRequiresCompleteBoundInventoryAndSurvivesRelocation() throws {
        let workspace = try workspace()
        var cleanup = workspace.root
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let stage = try workspace.managed(workspace.nativeRoot.appendingPathComponent("staging/primary-fixture"))
        try fixture(stage)
        XCTAssertThrowsError(try NativePrimaryStore.validateStaged(directory: stage, specification: specification, workspace: workspace))
        try NativePrimaryStore.recordStaged(directory: stage, specification: specification, workspace: workspace)
        try NativePrimaryStore.validateStaged(directory: stage, specification: specification, workspace: workspace)
        let target = try NativePrimaryStore.nativeDirectory(specification, workspace: workspace)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: stage, to: target)
        XCTAssertEqual(try NativePrimaryStore.directory(specification: specification, workspace: workspace, voice: "af_aoede").path, target.path)
        let moved = workspace.root.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: workspace.root, to: moved)
        cleanup = moved
        let relocated = try NativeWorkspace(root: moved)
        XCTAssertEqual(try NativePrimaryStore.directory(specification: specification, workspace: relocated, voice: "af_aoede"),
                       try NativePrimaryStore.nativeDirectory(specification, workspace: relocated))
        let inventory = try NativePrimaryStore.nativeDirectory(specification, workspace: relocated).appendingPathComponent(".libro-native.json")
        var record = try JSONSerialization.jsonObject(with: Data(contentsOf: inventory)) as! [String: Any]
        record["files"] = []
        try JSONSerialization.data(withJSONObject: record).write(to: inventory)
        XCTAssertThrowsError(try NativePrimaryStore.directory(specification: specification, workspace: relocated, voice: "af_aoede"))
    }

    func testInternalNamespaceAliasesCannotRedirectWritesIntoPythonSnapshots() throws {
        let workspace = try workspace(); defer { try? FileManager.default.removeItem(at: workspace.root) }
        let shared = workspace.root.appendingPathComponent(SpeechModel.kokoro.primaryRelativePath)
        try fixture(shared)
        try FileManager.default.createSymbolicLink(at: workspace.nativeRoot, withDestinationURL: shared)
        XCTAssertThrowsError(try NativePrimaryStore.recordReuse(directory: shared, specification: specification, workspace: workspace, voice: "af_aoede"))
        XCTAssertThrowsError(try workspace.managed(workspace.nativeRoot.appendingPathComponent("staging/new")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent("reuse").path))
        try FileManager.default.removeItem(at: workspace.nativeRoot)
        try FileManager.default.createDirectory(at: workspace.nativeRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: workspace.nativeRoot.appendingPathComponent("staging"), withDestinationURL: shared)
        XCTAssertThrowsError(try workspace.managed(workspace.nativeRoot.appendingPathComponent("staging/new")))
    }
}
