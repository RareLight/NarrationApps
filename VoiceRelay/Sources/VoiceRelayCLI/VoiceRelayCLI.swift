import Foundation
import Darwin
import VoiceRelayCore

@main
struct VoiceRelayCLI {
    static func main() async {
        umask(0o077)
        do {
            var args = Array(CommandLine.arguments.dropFirst())
            let command = args.first ?? "help"
            if !args.isEmpty { args.removeFirst() }
            func option(_ flag: String) throws -> String? {
                guard let i = args.firstIndex(of: flag) else { return nil }
                guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { throw RelayError.setup("Missing option value.") }
                let value = args[i + 1]; args.removeSubrange(i...(i + 1)); return value
            }
            if command == "help" || command == "--help" {
                print("""
                VoiceRelay native prototype — explicit local speech checks.
                voicerelay doctor [--config /absolute/config.toml]
                voicerelay speech-fixture --directory /dedicated/speech-fixture --project-root /VoiceRelay
                    [--voice af_heart] [--speed 1.0] [--config /absolute/config.toml]
                    [--interrupt-after boundary | --terminate-after boundary]
                voicerelay reading-list --plist /absolute/Bookmarks.plist
                voicerelay review-url --url https://example/article --directory /private/source-review
                    [--use-archives] [--saved-at ISO8601] [--config /absolute/config.toml]
                voicerelay library-backup --state-root /private/native-library --destination /private/new-backup
                voicerelay library-restore --backup /private/library-backup --state-root /private/new-empty-library
                doctor defaults to ./config.toml; other commands import only explicit --config.
                reading-list reads only the explicitly selected plist and prints counts.
                review-url fetches one selected URL and exports a private review; it produces no audio.
                No command adopts Python state, uploads, or enables automation.
                """); return
            }
            let config = try option("--config")
            let configURL = URL(fileURLWithPath: config ?? "config.toml").standardizedFileURL
            let profile: PrototypeProfile? = (config != nil || command == "doctor")
                ? try PrototypeProfile.load(configURL) : nil
            switch command {
            case "library-backup":
                guard config == nil, let root = try option("--state-root"), let destination = try option("--destination"), args.isEmpty else {
                    throw RelayError.setup("library-backup requires explicit --state-root and --destination, without --config.")
                }
                let summary = try await FixtureCoordinator().backupLibrary(
                    storage: .appStorage(stateRoot: URL(fileURLWithPath: root)), destination: URL(fileURLWithPath: destination))
                print("PRIVATE BACKUP: \(summary.retainedArticles) articles; \(summary.episodes) episode records. No credentials or audio included.")
            case "library-restore":
                guard config == nil, let backup = try option("--backup"), let root = try option("--state-root"), args.isEmpty else {
                    throw RelayError.setup("library-restore requires explicit --backup and --state-root, without --config.")
                }
                let destination = URL(fileURLWithPath: root)
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw RelayError.setup("CLI restore requires a new empty library location. Use Settings for replacing an existing library.")
                }
                _ = try await FixtureCoordinator().restoreLibrary(backup: URL(fileURLWithPath: backup), storage: .appStorage(stateRoot: destination))
                print("PRIVATE RESTORE: staged into the explicit new library. No app preferences, audio or server files changed.")
            case "reading-list":
                guard let path = try option("--plist"), args.isEmpty else { throw RelayError.setup("reading-list requires --plist and accepts no other options.") }
                let snapshot = try ReadingList.read(URL(fileURLWithPath: path))
                print("READ ONLY: \(snapshot.entries.count) Reading List entries; \(snapshot.skippedEntries) unsupported entries skipped. No source URLs or titles printed.")
            case "review-url":
                let useArchives = args.contains("--use-archives")
                if let index = args.firstIndex(of: "--use-archives") { args.remove(at: index) }
                let savedAtString = try option("--saved-at")
                let savedAt = savedAtString.flatMap { ISO8601DateFormatter().date(from: $0) }
                guard let address = try option("--url"), let directory = try option("--directory"), args.isEmpty,
                      let url = URL(string: address), savedAtString == nil || savedAt != nil else {
                    throw RelayError.setup("review-url requires --url, a dedicated --directory and a valid optional ISO8601 --saved-at.")
                }
                let limits = try FetchLimits(maximumBytes: profile?.maxArticleBytes ?? 10_000_000,
                                            timeout: Double(profile?.httpTimeoutSeconds ?? 30))
                let review = try await ArticleSourceLoader(limits: limits, useArchives: useArchives).load(
                    url, savedAt: savedAt, chunkLimit: profile?.chunkMaxCharacters ?? 1800)
                let folder = try SourceReviewArchive.save(review, root: URL(fileURLWithPath: directory), imported: profile)
                print("PRIVATE REVIEW: \(review.narration?.chunks.count ?? 0) narration chunks; no speech or publication.")
                if let issue = review.issueMessage { print("REVIEW NEEDED: \(issue)") }
                print("Snapshot: \(folder.path)")
            case "doctor":
                guard args.isEmpty, let profile else { throw RelayError.setup("Invalid doctor options.") }
                for diagnostic in Diagnostics.inspect(profile) {
                    print("\(diagnostic.ready ? "READY" : "GATE") \(diagnostic.id): \(diagnostic.message)")
                }
                for message in profile.compatibilityNotices { print("NOTE \(message)") }
            case "speech-fixture":
                guard let directory = try option("--directory") else { throw RelayError.setup("fixture requires --directory for explicit isolation.") }
                let projectRoot = try option("--project-root")
                let voice = try option("--voice")
                let speedString = try option("--speed")
                let speed = speedString.flatMap(Double.init)
                let stop = try option("--interrupt-after")
                let boundary = stop.flatMap(FixtureBoundary.init(rawValue:))
                let terminate = try option("--terminate-after")
                let terminationBoundary = terminate.flatMap(FixtureBoundary.init(rawValue:))
                guard args.isEmpty, stop == nil || boundary != nil, terminate == nil || terminationBoundary != nil,
                      stop == nil || terminate == nil, speedString == nil || speed != nil else { throw RelayError.setup("Invalid fixture options or recovery boundary.") }
                guard let projectRoot else { throw RelayError.setup("speech-fixture requires --project-root.") }
                let selectedVoice = voice ?? profile?.voice ?? "af_heart"
                let configuredSpeed: Double
                if let speed { configuredSpeed = speed }
                else if let setting = profile?.backendSettings["speed"] {
                    guard let value = setting.numericValue else { throw RelayError.setup("Speech speed must be a number.") }
                    configuredSpeed = value
                }
                else { configuredSpeed = 1 }
                let backend = try KokoroMLXBackend(configuration: KokoroConfiguration(projectRoot: URL(fileURLWithPath: projectRoot),
                    voice: selectedVoice, speed: configuredSpeed))
                let result = try await FixtureCoordinator().runSpeech(root: URL(fileURLWithPath: directory), imported: profile,
                    backend: backend, voice: selectedVoice, speed: configuredSpeed, interruptAfter: boundary,
                    onBoundary: { point in
                        if point == terminationBoundary { kill(getpid(), SIGKILL) }
                    })
                print("PUBLISHED fixture \(result.episode.id); \(result.narration.chunks.count) chunks; \(result.synthesizedChunks) synthesized this run")
                print("M4A: \(result.audioURL.path)\nRSS: \(result.feedURL.path)\nRemote delivery disabled. Audio: Kokoro speech.")
            default: throw RelayError.setup("Unknown command. Run voicerelay --help.")
            }
        } catch {
            let safe = (error as? RelayError)?.localizedDescription ?? (error as? SourceFetchError)?.localizedDescription
                ?? (error as? ArticleRecoveryError)?.localizedDescription
                ?? "Native operation failed; check setup and private artifacts."
            FileHandle.standardError.write(Data((safe + "\n").utf8)); exit(1)
        }
    }
}
