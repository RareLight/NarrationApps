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
    public static var managedRoot: URL { AppStorage.root.appendingPathComponent("SpeechRuntime", isDirectory: true) }
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
    public static func preferredRoot(saved: URL?, legacy: URL) -> URL { saved ?? managedRoot }
    public static func isInstalled(at root: URL) -> Bool {
        let weights = root.appendingPathComponent(SpeechModel.kokoro.primaryRelativePath + "/kokoro-v1_0.safetensors")
        let prepared = root.appendingPathComponent("models/.native/primary/kokoro/\(NativePrimaryCatalog.specification(for: .kokoro).revision)/kokoro-v1_0.safetensors")
        return FileManager.default.isExecutableFile(atPath: workerExecutable.path)
            && (FileManager.default.fileExists(atPath: weights.path) || FileManager.default.fileExists(atPath: prepared.path))
    }
    public static func check(at root: URL) throws {
        try NativeOperationBridge().run {
            try await SpeechSetupCheck.run(configuration: .init(executable: workerExecutable, requestTimeout: .seconds(600), inferencePriority: .background),
                                           workspace: root, settings: .init(speed: 1))
        }
    }
    public static func install(at root: URL = managedRoot) throws {
        guard root.isFileURL, root.path != "/", !Files.samePath(root, FileManager.default.homeDirectoryForCurrentUser) else {
            throw RelayError.setup("Choose an app-owned model folder.")
        }
        try Files.directory(root)
        let configuration = WorkerConfiguration(executable: workerExecutable, requestTimeout: .seconds(5_400))
        try NativeOperationBridge().run {
            try await ModelPreparation.run(configuration: configuration, workspace: root, settings: .init(speed: 1))
        }
        try check(at: root)
    }
}

public typealias PronunciationStore = Pronunciation.PronunciationStore
