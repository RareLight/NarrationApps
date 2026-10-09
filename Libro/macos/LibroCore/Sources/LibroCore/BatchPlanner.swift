import Foundation
import Darwin

public enum PlanningError: Error, LocalizedError {
    case invalidName, collision(String), protectedInput, invalidDestination, replacementRequired
    public var errorDescription: String? {
        switch self {
        case .invalidName: "Output names must be relative paths with a nonempty filename."
        case .collision(let path): "Output conflict: \(path). Choose a different output name before starting."
        case .protectedInput: "An output would overwrite a selected input. Choose another destination."
        case .invalidDestination: "The output folder is unavailable or not writable. Browse to recover it."
        case .replacementRequired: "An output already exists. Review destinations and approve replacement before generating again."
        }
    }
}

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
    public let settings: SpeechSettings
    public let serial: Bool
    public let outputFormat: AudioOutputFormat
    public let approvedReplacements: Set<UUID>

    public init(documents: [PlannedDocument], outputDirectory: URL, workspace: URL, settings: SpeechSettings,
                serial: Bool, replaceExisting: Bool = false, outputFormat: AudioOutputFormat = .wav) {
        id = UUID(); self.documents = documents; self.outputDirectory = outputDirectory
        self.workspace = workspace; self.settings = settings; self.serial = serial
        self.outputFormat = outputFormat
        approvedReplacements = replaceExisting ? Set(documents.filter(\.replacesExisting).map(\.id)) : []
    }
}

public enum OutputPaths {
    public static func key(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    public static func resolved(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw PlanningError.invalidDestination }
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            guard ancestor.path != "/", (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) == nil else {
                throw PlanningError.invalidDestination
            }
            missing.append(ancestor.lastPathComponent); ancestor.deleteLastPathComponent()
        }
        var result = ancestor.resolvingSymlinksInPath()
        for part in missing.reversed() { result.appendPathComponent(part) }
        return result
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
