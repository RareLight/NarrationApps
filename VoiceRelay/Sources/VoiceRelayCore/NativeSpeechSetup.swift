import Foundation
import Pronunciation
import NativeSpeech
import AudioOutput
import NarrationCore
import ProcessingPipeline

public typealias VoiceSamples = NativeSpeech.VoiceSamples
public typealias AudioPreviewPlayer = AudioOutput.AudioPreviewPlayer
public typealias SpeechSetupOnboarding = NarrationCore.SpeechSetupOnboarding

public enum NativeSpeechSetup {
    public static var legacyManagedRoot: URL { AppStorage.root.appendingPathComponent("SpeechRuntime", isDirectory: true) }
    public static var managedRoot: URL { NativeModelStorage.defaultRoot }
    public static var workerExecutable: URL {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/VoiceRelaySpeechWorker")
        }
        // Unshipped SwiftPM development runs can use the independently built
        // shared worker. Exported app bundles always use their own signed copy.
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("swift-packages/.build/debug/NarrationSpeechWorker")
    }
    public static func preferredRoot(saved: URL?) -> URL {
        guard let saved, !Files.samePath(saved, legacyManagedRoot) else { return managedRoot }
        return saved
    }
    public static func preferredRoot(defaults: UserDefaults) -> URL {
        let key = "modelStorage.sharedCacheDefault.v1"
        let saved = defaults.string(forKey: "runtimeProject").map { URL(fileURLWithPath: $0) }
        guard !defaults.bool(forKey: key) else { return saved ?? managedRoot }
        defaults.set(true, forKey: key)
        if let saved, Files.samePath(saved, legacyManagedRoot) { defaults.removeObject(forKey: "runtimeProject") }
        return preferredRoot(saved: saved)
    }
    public static func isInstalled(at root: URL, settings: SpeechSettings = .init()) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: workerExecutable.path),
              let workspace = try? NativeWorkspace(root: root) else { return false }
        let spec = NativePrimaryCatalog.specification(for: settings.model)
        let shared = root.appendingPathComponent(settings.model.primaryRelativePath)
        let prepared = try? NativePrimaryStore.nativeDirectory(spec, workspace: workspace)
        return [shared, prepared].compactMap { $0 }.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("config.json").path) }
    }
    public static func check(at root: URL, settings: SpeechSettings = .init()) throws {
        try NativeOperationBridge().run {
            try await SpeechSetupCheck.run(configuration: .init(executable: workerExecutable, requestTimeout: .seconds(600), inferencePriority: .background),
                                           workspace: root, settings: settings)
        }
    }
    public static func install(at root: URL = managedRoot, settings: SpeechSettings = .init(),
                               progress: @escaping @Sendable (ModelPreparationProgress) -> Void = { _ in }) throws {
        guard root.isFileURL, root.path != "/", !Files.samePath(root, FileManager.default.homeDirectoryForCurrentUser) else {
            throw RelayError.setup("Choose an app-owned model folder.")
        }
        try NativeModelStorage.prepareRoot(root)
        let configuration = WorkerConfiguration(executable: workerExecutable, requestTimeout: .seconds(5_400))
        try NativeOperationBridge().run {
            try await ModelPreparation.run(configuration: configuration, workspace: root, settings: settings, progress: progress)
        }
        progress(.init(scope: .primary, phase: .checking, totalBytes: 0))
        try check(at: root, settings: settings)
    }
}

public typealias PronunciationStore = Pronunciation.PronunciationStore

public typealias NarrationSampleText = NativeSpeech.NarrationSampleText
