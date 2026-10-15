import NarrationCore
import DocumentProcessing
import NativeSpeech
import AudioOutput
import Foundation
import Pronunciation
import Darwin

public struct PlannedDocument: Identifiable, Sendable {
    public let input: InputDocument
    public let destination: URL
    public let relativeOutput: String
    public let replacesExisting: Bool
    public var id: UUID { input.id }
}

public struct BatchRequest: Sendable {
    public let id: UUID
    public let documents: [PlannedDocument]
    public let outputDirectory: URL
    public let workspace: URL
    public let pronunciations: PronunciationDictionary
    public let settings: SpeechSettings
    public let describeImages: Bool
    public let outputFormat: AudioOutputFormat
    public let approvedReplacements: Set<UUID>

    public init(documents: [PlannedDocument], outputDirectory: URL, workspace: URL, settings: SpeechSettings,
                describeImages: Bool = false, replaceExisting: Bool = false, outputFormat: AudioOutputFormat = .wav, pronunciations: PronunciationDictionary = .empty) {
        self.pronunciations = pronunciations; id = UUID(); self.documents = documents; self.outputDirectory = outputDirectory
        self.workspace = workspace; self.settings = settings; self.describeImages = describeImages
        self.outputFormat = outputFormat
        approvedReplacements = replaceExisting ? Set(documents.filter(\.replacesExisting).map(\.id)) : []
    }
}

public enum BatchPlanner {
    public static func defaultOutput(_ input: InputDocument, format: AudioOutputFormat = .wav) -> String {
        let path = input.relativePath as NSString
        var stem = (path.lastPathComponent as NSString).deletingPathExtension
        for suffix in [".wav", ".mp3", ".flac", ".aac", ".m4a", ".m4b", ".ogg", ".opus"] where stem.lowercased().hasSuffix(suffix) {
            stem = String(stem.dropLast(suffix.count)); break
        }
        stem = String(stem.drop(while: { $0 == "." }))
        if stem.isEmpty { stem = "untitled" }
        let parent = path.deletingLastPathComponent
        return parent.isEmpty ? stem + "." + format.rawValue : parent + "/" + stem + "." + format.rawValue
    }

    public static func plan(_ inputs: [InputDocument], output: URL,
                            names: [UUID: String] = [:], format: AudioOutputFormat = .wav) throws -> [PlannedDocument] {
        try Task.checkCancellation()
        let root = try OutputPaths.resolved(output)
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
              access(root.path, W_OK | X_OK) == 0 else { throw PlanningError.invalidDestination }
        let protected = try Set(inputs.map {
            try Task.checkCancellation()
            return OutputPaths.key(try OutputPaths.resolved($0.source).path)
        })
        let protectedIdentities = Set(inputs.compactMap { identity($0.source) })
        var destinations = Set<String>()
        var existingIdentities = Set<String>()
        return try inputs.map { input in
            try Task.checkCancellation()
            let relative = names[input.id] ?? defaultOutput(input, format: format)
            guard !relative.hasPrefix("/"), !relative.isEmpty,
                  !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  !relative.contains("\0"), (relative as NSString).pathExtension.lowercased() == format.rawValue else { throw PlanningError.invalidName }
            let destination = root.appendingPathComponent(relative)
            let resolved = try OutputPaths.resolved(destination)
            // A symlink may never redirect an output outside the chosen folder.
            guard resolved.path.hasPrefix(root.path + "/") else { throw PlanningError.invalidDestination }
            let key = OutputPaths.key(resolved.path)
            guard !protected.contains(key) else { throw PlanningError.protectedInput }
            guard !destinations.contains(where: { $0 == key || $0.hasPrefix(key + "/") || key.hasPrefix($0 + "/") }) else {
                throw PlanningError.collision(relative)
            }
            destinations.insert(key)
            let exists = FileManager.default.fileExists(atPath: resolved.path)
            if exists {
                guard (try resolved.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw PlanningError.invalidDestination }
                if let identity = identity(resolved) {
                    guard !protectedIdentities.contains(identity) else { throw PlanningError.protectedInput }
                    guard existingIdentities.insert(identity).inserted else { throw PlanningError.collision(relative) }
                }
            }
            var parent = resolved.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: parent.path) { parent.deleteLastPathComponent() }
            guard (try parent.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
                  access(parent.path, W_OK | X_OK) == 0 else { throw PlanningError.invalidDestination }
            return PlannedDocument(input: input, destination: destination, relativeOutput: relative, replacesExisting: exists)
        }
    }

    private static func identity(_ url: URL) -> String? {
        var info = stat()
        return stat(url.path, &info) == 0 ? "\(info.st_dev):\(info.st_ino)" : nil
    }
}
