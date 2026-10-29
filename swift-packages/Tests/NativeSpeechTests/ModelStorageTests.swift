import Foundation
import XCTest
import HuggingFace
import NarrationCore
import ProcessingPipeline
@testable import NativeSpeech

final class ModelStorageTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Shared model cache \(UUID())")
        try NativeModelStorage.prepareRoot(root)
        return root.resolvingSymlinksInPath()
    }
    private func repository(_ model: SpeechModel, root: URL) -> URL {
        HubCache(cacheDirectory: root).repoDirectory(repo: Repo.ID(rawValue: model.repository)!, kind: .model)
    }
    private func seed(_ path: URL) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Data(repeating: 0x31, count: 8192).write(to: path.appendingPathComponent("synthetic-weight"))
    }
    func testGeneratedJSONDigestIgnoresOnlyObjectOrderAndPreservesTokenizerContent() throws {
        func digest(_ json: String) throws -> String { try NativeJSONDigest.sha256(JSONSerialization.jsonObject(with: Data(json.utf8))) }
        let expected = try digest(#"{"vocab":{"***":1,"**":2},"tokens":["one","two"],"enabled":true}"#)
        XCTAssertEqual(expected, try digest(#"{"enabled":true,"tokens":["one","two"],"vocab":{"**":2,"***":1}}"#))
        XCTAssertNotEqual(expected, try digest(#"{"vocab":{"***":2,"**":1},"tokens":["one","two"],"enabled":true}"#))
        XCTAssertNotEqual(expected, try digest(#"{"vocab":{"***":1,"**":2},"tokens":["two","one"],"enabled":true}"#))
        XCTAssertNotEqual(try digest(#"{"value":true}"#), try digest(#"{"value":1}"#))
        XCTAssertNotEqual(try digest(#"{"value":"1"}"#), try digest(#"{"value":1}"#))
    }

    func testDefaultUsesLibraryResolverWithoutCreatingCache() {
        XCTAssertEqual(NativeModelStorage.defaultRoot, HubCache.default.cacheDirectory.standardizedFileURL.resolvingSymlinksInPath())
    }
    func testNewCustomCacheUsesStandardLayoutAndMissingInventoryDoesNotCreateIt() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(try NativeModelStorage.entries(at: missing).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try NativeWorkspace(root: root)
        XCTAssertTrue(workspace.usesSharedHub)
        XCTAssertEqual(workspace.hubCache, root)
        let cache = HubCache(cacheDirectory: root)
        XCTAssertEqual(repository(.qwen3, root: root).lastPathComponent, "models--mlx-community--Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit")
        let source = root.appendingPathComponent("input")
        try Data("synthetic".utf8).write(to: source)
        // SDK APIs create blobs and a Python-compatible snapshot, with no network.
        let repo = Repo.ID(rawValue: SpeechModel.qwen3.repository)!
        let revision = String(repeating: "a", count: 40)
        // storeFile is tested separately below because it is asynchronous.
        XCTAssertTrue(try cache.snapshotPath(repo: repo, kind: .model, commitHash: revision).path.hasPrefix(root.path + "/models--"))
    }
    func testHubPublicationAndPrivateOverlayShareBytesWithoutMutatingSnapshot() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try NativeWorkspace(root: root)
        let cache = HubCache(cacheDirectory: root)
        let repo = Repo.ID(rawValue: SpeechModel.kokoro.repository)!
        let source = root.appendingPathComponent("source")
        try Data("abc".utf8).write(to: source)
        try await cache.storeFile(at: source, repo: repo, kind: .model, revision: String(repeating: "a", count: 40), filename: "weight.bin", etag: String(repeating: "b", count: 64))
        let snapshot = try XCTUnwrap(cache.cachedFilePath(repo: repo, kind: .model, revision: String(repeating: "a", count: 40), filename: "weight.bin"))
        let blob = try workspace.cached(snapshot.resolvingSymlinksInPath())
        let stage = workspace.nativeRoot.appendingPathComponent("staging/primary-fixture")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let linked = stage.appendingPathComponent("weight.bin")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: blob)
        let file = NativeAcquisitionFile(path: "weight.bin", bytes: 3, hash: try NativeG2P.sha256(blob), gitOID: nil)
        XCTAssertTrue(try file.quarantineInvalidCopy(at: linked, workspace: workspace))
        XCTAssertEqual(try Data(contentsOf: snapshot), Data("abc".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linked.path), blob.path)
    }
    func testLegacyWorkspaceLayoutAndImportsRemainReadOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try seed(root.appendingPathComponent("models/.native"))
        defer { try? FileManager.default.removeItem(at: root) }
        try NativeModelStorage.prepareRoot(root)
        let workspace = try NativeWorkspace(root: root)
        XCTAssertFalse(workspace.usesSharedHub)
        XCTAssertEqual(workspace.hubCache.path, workspace.nativeRoot.appendingPathComponent("hub").path)
        let imported = root.appendingPathComponent(SpeechModel.kokoro.primaryRelativePath)
        try seed(imported)
        let entry = try XCTUnwrap(NativeModelStorage.entries(at: root).first)
        XCTAssertTrue(entry.imported); XCTAssertGreaterThan(entry.bytes, 0)
        try NativeModelStorage.remove(.kokoro, at: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.path))
    }
    func testReadersBlockDeletionUntilBothSessionsReleaseAndUnrelatedDataSurvives() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let model = repository(.qwen3, root: root), other = repository(.orpheus, root: root)
        try seed(model); try seed(other)
        try seed(root.appendingPathComponent("unrelated-repo"))
        let workspace = try NativeWorkspace(root: root)
        var first: ModelStorageLease? = try ModelStorageLease(workspace: workspace)
        var second: ModelStorageLease? = try ModelStorageLease(workspace: workspace)
        XCTAssertThrowsError(try NativeModelStorage.remove(.qwen3, at: root))
        first = nil
        XCTAssertThrowsError(try NativeModelStorage.remove(.qwen3, at: root))
        withExtendedLifetime(second) {}; second = nil
        try NativeModelStorage.remove(.qwen3, at: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("unrelated-repo").path))
        withExtendedLifetime(first) {}
    }
    func testPartialInstallationsAreListedAndOnlyTheirOwnedStageIsRemoved() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try NativeWorkspace(root: root)
        let partial = workspace.nativeRoot.appendingPathComponent("staging/primary-qwen3-fixture")
        let unrelated = workspace.nativeRoot.appendingPathComponent("staging/primary-orpheus-fixture")
        try seed(partial); try seed(unrelated)
        let before = try XCTUnwrap(NativeModelStorage.entries(at: root).first { $0.model == .qwen3 })
        XCTAssertGreaterThan(before.bytes, 0)
        try NativeModelStorage.remove(.qwen3, at: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testExclusiveRemovalBlocksNewReadersAndEscapingRepoLinkCannotDelete() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try seed(outside); defer { try? FileManager.default.removeItem(at: outside) }
        let model = repository(.qwen3, root: root)
        try FileManager.default.createSymbolicLink(at: model, withDestinationURL: outside)
        XCTAssertThrowsError(try NativeModelStorage.remove(.qwen3, at: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("synthetic-weight").path))
        let exclusive = try ModelStorageLease(workspace: NativeWorkspace(root: root), deleting: true)
        XCTAssertThrowsError(try ModelStorageLease(workspace: NativeWorkspace(root: root)))
        withExtendedLifetime(exclusive) {}
    }
    /// Explicit cached-assets gate; ordinary fixtures never load or download models.
    func testOfflineSharedCacheInstallationAndGeneration() async throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["NARRATION_CACHE_SOURCE"],
              let workerPath = ProcessInfo.processInfo.environment["NARRATION_CACHE_WORKER"] else {
            throw XCTSkip("Opt-in shared-cache native check requires a model workspace and worker.")
        }
        let source = try NativeWorkspace(root: URL(fileURLWithPath: sourcePath))
        let model = ProcessInfo.processInfo.environment["NARRATION_CACHE_MODEL"].flatMap(SpeechModel.init(rawValue:)) ?? .kokoro
        let settings = SpeechSettings(model: model, voice: model.defaultVoice)
        _ = try source.primaryDirectory(for: model, voice: settings.voice)
        if model == .kokoro { try NativeG2P.validate(directory: source.g2pDirectory, workspace: source) }
        let destination = try root(); defer { try? FileManager.default.removeItem(at: destination) }
        let workspace = try NativeWorkspace(root: destination)
        let cache = HubCache(cacheDirectory: destination)
        let spec = NativePrimaryCatalog.specification(for: model)
        for inventory in [spec] + NativePrimaryCatalog.dependencies(for: model) {
            let folder = try NativePrimaryStore.directory(specification: inventory, workspace: source, voice: settings.voice)
            let repo = Repo.ID(rawValue: inventory.repository)!
            for file in inventory.files {
                try await cache.storeFile(at: folder.appendingPathComponent(file.path), repo: repo, kind: .model,
                    revision: inventory.revision, filename: file.path, etag: file.gitOID.isEmpty ? file.sha256 : file.gitOID)
            }
        }
        if model == .kokoro {
            let g2pRepo = Repo.ID(rawValue: NativeG2P.repository)!
            for (file, _) in NativeG2P.requiredFiles {
                try await cache.storeFile(at: source.g2pDirectory.appendingPathComponent(file), repo: g2pRepo, kind: .model,
                    revision: NativeG2P.revision, filename: file, etag: NativeG2P.sha256ByFile[file]!)
            }
        }
        let debug = try DebugLog(workspace: destination)
        let configuration = WorkerConfiguration(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
            arguments: ["-p", "(version 1)(allow default)(deny network*)", workerPath, "--serve"],
            debugLog: debug, inferencePriority: .background)
        try await ModelPreparation.run(configuration: configuration, workspace: destination, settings: settings)
        let prepared = try workspace.primaryDirectory(for: model, voice: settings.voice)
        let sourcePrimary = try source.primaryDirectory(for: model, voice: settings.voice)
        XCTAssertEqual(try Data(contentsOf: prepared.appendingPathComponent("config.json")), try Data(contentsOf: sourcePrimary.appendingPathComponent("config.json")))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: prepared.appendingPathComponent(spec.files.first { $0.path.hasSuffix(".safetensors") }!.path).path))
        let session = try NativeSpeechSession(configuration: configuration, workspace: destination, settings: settings)
        do {
            try await session.prepare()
            XCTAssertThrowsError(try NativeModelStorage.remove(model, at: destination))
            let projection = try NarrationPlanner.prepareForSpeech(.init(blocks: [.init(kind: .paragraph, text: "This synthetic passage verifies the shared model cache.")], extractorVersion: "cache-fixture"), settings: settings)
            let plan = try await session.prepareSpeech(projection)
            try await session.render(plan: plan, destination: destination.appendingPathComponent("synthetic.wav"), identity: .init(batch: UUID(), job: UUID()))
            await session.close()
            for inventory in [spec] + NativePrimaryCatalog.dependencies(for: model) {
                for file in inventory.files {
                    let cached = try XCTUnwrap(cache.cachedFilePath(repo: Repo.ID(rawValue: inventory.repository)!, kind: .model, revision: inventory.revision, filename: file.path))
                    XCTAssertEqual(try NativeG2P.sha256(cached), file.sha256)
                }
            }
            try NativeModelStorage.remove(model, at: destination)
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("synthetic.wav").path))
            if model == .kokoro { XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.g2pDirectory.path)) }
        } catch {
            await session.close()
            print((try? String(contentsOf: debug.url, encoding: .utf8)) ?? "No worker diagnostics")
            if let evidence = ProcessInfo.processInfo.environment["NARRATION_CACHE_EVIDENCE"] {
                let generated = prepared.appendingPathComponent("tokenizer.json")
                if FileManager.default.fileExists(atPath: generated.path) {
                    let destination = URL(fileURLWithPath: evidence).appendingPathComponent(model.rawValue + "-generated-tokenizer.json")
                    try? Data(contentsOf: generated).write(to: destination)
                }
            }
            throw error
        }
    }

}
