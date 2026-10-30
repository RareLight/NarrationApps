import Foundation
import AVFoundation
import Speech
import NarrationCore

public enum LocalNarrationRecognition {
    public enum Unavailable: Error, LocalizedError {
        case notInstalled, tooLong
        public var errorDescription: String? {
            switch self {
            case .notInstalled: "Local speech recognition for this language is unavailable or not installed. No download or online service was started."
            case .tooLong: "Check one narration chunk at a time (up to two minutes)."
            }
        }
    }
    /// Explicit review only. Never request/download assets and never use a server.
    public static func transcribe(_ audio: URL, language: String) async throws -> String {
        try Task.checkCancellation()
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)),
              await SpeechTranscriber.installedLocales.contains(locale) else { throw Unavailable.notInstalled }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        guard await AssetInventory.status(forModules: [module]) == .installed else { throw Unavailable.notInstalled }
        let file = try AVAudioFile(forReading: audio)
        guard file.length > 0, Double(file.length) / file.processingFormat.sampleRate <= 120 else { throw Unavailable.tooLong }
        let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [module], finishAfterFile: true)
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(120)); await analyzer.cancelAndFinishNow(); return true } catch { return false }
        }
        do {
            let text = try await withTaskCancellationHandler {
                var text = ""
                for try await result in module.results {
                    try Task.checkCancellation()
                    text += String(result.text.characters) + " "
                    guard text.utf8.count <= 64_000 else { throw SpeechFailure(.invalidInput) }
                }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            } onCancel: { Task { await analyzer.cancelAndFinishNow() } }
            deadline.cancel(); let timedOut = await deadline.value; await analyzer.cancelAndFinishNow()
            try Task.checkCancellation()
            guard !timedOut else { throw SpeechFailure(.timeout) }
            guard !text.isEmpty else { throw SpeechFailure(.generation) }
            return text
        } catch {
            deadline.cancel(); _ = await deadline.value; await analyzer.cancelAndFinishNow(); throw error
        }
    }
}
