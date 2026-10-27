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
    public let narrationOptions: NarrationOptions
    public let coverArtwork: [UUID: CoverArtwork]
    public let approvedReplacements: Set<UUID>

    public init(documents: [PlannedDocument], outputDirectory: URL, workspace: URL, settings: SpeechSettings,
                describeImages: Bool = false, replaceExisting: Bool = false, outputFormat: AudioOutputFormat = .wav, pronunciations: PronunciationDictionary = .empty, coverArtwork: [UUID: CoverArtwork] = [:], narrationOptions: NarrationOptions = .init()) {
        self.narrationOptions = narrationOptions
        self.coverArtwork = coverArtwork
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
        let protection = try Protection(inputs)
        var keys: [(String, String)] = []
        var existingIdentities = Set<String>()
        let plans = try inputs.map { input in
            try Task.checkCancellation()
            let relative = names[input.id] ?? defaultOutput(input, format: format)
            let plan = try validate(input, relative: relative, root: root, format: format, protection: protection)
            keys.append((OutputPaths.key(try OutputPaths.resolved(plan.destination).path), relative))
            if plan.replacesExisting, let identity = identity(plan.destination), !existingIdentities.insert(identity).inserted {
                throw PlanningError.collision(relative)
            }
            return plan
        }
        // Check ancestor membership instead of scanning every previously seen
        // path. Case/Unicode folding is shared with all destination checks.
        var destinations = Set<String>()
        for (key, relative) in keys {
            guard destinations.insert(key).inserted else { throw PlanningError.collision(relative) }
        }
        for (key, relative) in keys {
            try Task.checkCancellation()
            var parent = (key as NSString).deletingLastPathComponent
            while parent.count > 1 {
                guard !destinations.contains(parent) else { throw PlanningError.collision(relative) }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        return plans
    }

    private struct Protection: Sendable {
        var paths = Set<String>()
        var directories = Set<String>()
        var identities = Set<String>()
        init(_ inputs: [InputDocument]) throws {
            for input in inputs {
                try Task.checkCancellation()
                let source = try OutputPaths.resolved(input.source)
                let key = OutputPaths.key(source.path)
                paths.insert(key)
                if (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { directories.insert(key) }
                if let id = BatchPlanner.identity(source) { identities.insert(id) }
            }
        }
        func contains(_ key: String) -> Bool {
            if paths.contains(key) { return true }
            var parent = key as NSString
            while parent.length > 1 {
                parent = parent.deletingLastPathComponent as NSString
                if directories.contains(parent as String) { return true }
            }
            return false
        }
        mutating func include(_ other: Self) {
            paths.formUnion(other.paths); directories.formUnion(other.directories); identities.formUnion(other.identities)
        }
    }

    private static func validate(_ input: InputDocument, relative: String, root: URL,
                                 format: AudioOutputFormat, protection: Protection) throws -> PlannedDocument {
        guard !relative.hasPrefix("/"), !relative.isEmpty,
              !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !relative.contains("\0"), (relative as NSString).pathExtension.lowercased() == format.rawValue else { throw PlanningError.invalidName }
        let destination = root.appendingPathComponent(relative)
        let resolved = try OutputPaths.resolved(destination)
        guard resolved.path.hasPrefix(root.path + "/") else { throw PlanningError.invalidDestination }
        guard !protection.contains(OutputPaths.key(resolved.path)) else { throw PlanningError.protectedInput }
        let exists = FileManager.default.fileExists(atPath: resolved.path)
        if exists {
            guard (try resolved.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw PlanningError.invalidDestination }
            if let id = identity(resolved), protection.identities.contains(id) { throw PlanningError.protectedInput }
        }
        var parent = resolved.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: parent.path) { parent.deleteLastPathComponent() }
        guard (try parent.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
              access(parent.path, W_OK | X_OK) == 0 else { throw PlanningError.invalidDestination }
        return PlannedDocument(input: input, destination: destination, relativeOutput: relative, replacesExisting: exists)
    }

    /// Captures whole-batch naming/collision validation once. Publication still
    /// refreshes source protection and inode aliases, since files can change
    /// while a long batch runs; only the current destination is replanned.
    struct ValidationContext: Sendable {
        private let request: BatchRequest
        private let root: URL
        private let protection: Protection
        private let bindings: [UUID: URL]

        init(_ request: BatchRequest) throws {
            self.request = request
            root = try OutputPaths.resolved(request.outputDirectory)
            protection = try Protection(request.documents.map(\.input))
            guard Set(request.documents.map(\.id)).count == request.documents.count else { throw PlanningError.invalidName }
            let names = Dictionary(uniqueKeysWithValues: request.documents.map { ($0.id, $0.relativeOutput) })
            let plans = try BatchPlanner.plan(request.documents.map(\.input), output: request.outputDirectory, names: names, format: request.outputFormat)
            var captured: [UUID: URL] = [:]
            for (plan, original) in zip(plans, request.documents) {
                let resolved = try OutputPaths.resolved(plan.destination)
                guard resolved == (try OutputPaths.resolved(original.destination)) else { throw PlanningError.invalidDestination }
                guard !plan.replacesExisting || request.approvedReplacements.contains(plan.id) else { throw PlanningError.replacementRequired }
                captured[plan.id] = resolved
            }
            bindings = captured
        }

        func validate(_ document: PlannedDocument) throws {
            try Task.checkCancellation()
            guard try OutputPaths.resolved(request.outputDirectory) == root,
                  (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  access(root.path, W_OK | X_OK) == 0 else { throw PlanningError.invalidDestination }
            var liveProtection = try Protection(request.documents.map(\.input))
            liveProtection.include(protection)
            let current = try BatchPlanner.validate(document.input, relative: document.relativeOutput,
                root: root, format: request.outputFormat, protection: liveProtection)
            let resolved = try OutputPaths.resolved(current.destination)
            guard resolved == bindings[document.id], try OutputPaths.resolved(document.destination) == resolved else { throw PlanningError.invalidDestination }
            guard !current.replacesExisting || request.approvedReplacements.contains(document.id) else { throw PlanningError.replacementRequired }
            if let currentIdentity = BatchPlanner.identity(resolved) {
                for (id, destination) in bindings where id != document.id {
                    try Task.checkCancellation()
                    guard BatchPlanner.identity(destination) != currentIdentity else { throw PlanningError.collision(document.relativeOutput) }
                }
            }
        }
    }

    private static func identity(_ url: URL) -> String? {
        var info = stat()
        return stat(url.path, &info) == 0 ? "\(info.st_dev):\(info.st_ino)" : nil
    }
}
