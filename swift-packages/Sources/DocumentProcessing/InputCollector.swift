import NarrationCore
import Foundation
import UniformTypeIdentifiers
import Darwin

public enum DocumentKind: String, Codable, Sendable, CaseIterable {
    case text, markdown, rtf, pdf, epub

    public static func identify(_ url: URL) -> Self? {
        switch url.pathExtension.lowercased() {
        case "txt": .text
        case "md", "markdown": .markdown
        case "rtf": .rtf
        case "pdf": .pdf
        case "epub": .epub
        default: nil
        }
    }

    public static var contentTypes: [UTType] {
        [.plainText, UTType(filenameExtension: "md")!, UTType(filenameExtension: "markdown")!, .rtf, .pdf, UTType("org.idpf.epub-container") ?? UTType(filenameExtension: "epub")!]
    }
}

public struct InputDocument: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let source: URL
    public let kind: DocumentKind
    public let relativePath: String
    public var textEncoding: TextFileEncoding

    public init(source: URL, kind: DocumentKind, relativePath: String, id: UUID = UUID(), textEncoding: TextFileEncoding = .automatic) {
        self.id = id
        self.source = source
        self.kind = kind
        self.relativePath = relativePath
        self.textEncoding = textEncoding
    }
}

public struct IntakeIssue: Sendable, Equatable {
    public let source: URL
    public let message: String
}

public struct IntakeResult: Sendable {
    public var documents: [InputDocument] = []
    public var issues: [IntakeIssue] = []
    public var ignoredCount = 0
    public var excludedOutput = false
}

/// Shared by panels, drops and Finder opening. Call away from MainActor.
public enum InputCollector {
    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey,
        .isSymbolicLinkKey, .isAliasFileKey, .isPackageKey]

    public static func collect(_ selection: [URL], excludingOutput: URL? = nil,
                               progress: @Sendable (Int) -> Void = { _ in }) throws -> IntakeResult {
        let manager = FileManager.default
        var result = IntakeResult()
        var folders: [URL] = []
        var loose: [URL] = []
        for original in selection {
            try Task.checkCancellation()
            do {
                guard original.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
                let values = try original.resourceValues(forKeys: keys)
                var url = original.standardizedFileURL
                if values.isAliasFile == true {
                    url = try URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting])
                }
                url = url.resolvingSymlinksInPath()
                let resolved = try url.resourceValues(forKeys: keys)
                if resolved.isDirectory == true {
                    guard values.isSymbolicLink != true, values.isAliasFile != true, resolved.isPackage != true else {
                        result.ignoredCount += 1
                        continue
                    }
                    folders.append(url)
                } else if resolved.isRegularFile == true { loose.append(url) }
                else { result.ignoredCount += 1 }
            } catch {
                result.issues.append(IntakeIssue(source: original, message: "Cannot access selected input: \(error.localizedDescription)"))
            }
        }
        folders = Dictionary(grouping: folders, by: \.path).values.compactMap(\.first).sorted { $0.path < $1.path }
        let excluded = excludingOutput?.standardizedFileURL.resolvingSymlinksInPath()
        // An outer root owns placement, except explicitly selected descendants
        // inside an otherwise excluded output subtree. Selection is authority
        // to import those documents; WAV output is an unsupported input type.
        folders = folders.filter { folder in !folders.contains { outer in
            guard outer != folder, isWithin(folder, outer) else { return false }
            if let excluded, isWithin(folder, excluded), !isWithin(outer, excluded) { return false }
            return true
        } }
        var labels = Set<String>()
        var identities = Set<String>()
        var visited = 0
        func add(_ url: URL, relative: String) {
            guard let kind = DocumentKind.identify(url) else { result.ignoredCount += 1; return }
            guard identities.insert(identity(url)).inserted else { return }
            result.documents.append(InputDocument(source: url, kind: kind, relativePath: relative))
        }
        for folder in folders {
            try Task.checkCancellation()
            let recursiveExclusion = excluded.flatMap { isWithin(folder, $0) ? nil : $0 }
            let base = folder.lastPathComponent.isEmpty ? "Folder" : folder.lastPathComponent
            var label = base
            var number = 2
            while !labels.insert(OutputPaths.key(label)).inserted { label = "\(base)-\(number)"; number += 1 }
            var found: [URL] = []
            guard let enumerator = manager.enumerator(at: folder, includingPropertiesForKeys: Array(keys),
                    options: [.skipsPackageDescendants], errorHandler: { url, error in
                        result.issues.append(IntakeIssue(source: url, message: "Cannot scan input: \(error.localizedDescription)"))
                        return true
                    }) else {
                result.issues.append(IntakeIssue(source: folder, message: "Cannot scan this folder."))
                continue
            }
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                visited += 1
                if visited % 100 == 0 { progress(visited) }
                do {
                    let values = try url.resourceValues(forKeys: keys)
                    // Enumerators can return /var URLs for a /private/var root.
                    let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
                    if let excluded = recursiveExclusion, isWithin(canonical, excluded) {
                        if values.isDirectory == true { enumerator.skipDescendants() }
                        result.excludedOutput = true
                        continue
                    }
                    if values.isSymbolicLink == true || values.isAliasFile == true || values.isPackage == true {
                        enumerator.skipDescendants()
                        result.ignoredCount += 1
                    } else if values.isRegularFile == true { found.append(canonical) }
                } catch {
                    result.issues.append(IntakeIssue(source: url, message: "Cannot inspect input: \(error.localizedDescription)"))
                }
            }
            for url in found.sorted(by: { $0.path < $1.path }) {
                try Task.checkCancellation()
                let relative = String(url.path.dropFirst(folder.path.count + 1))
                add(url, relative: label + "/" + relative)
            }
        }
        for url in loose.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            visited += 1
            add(url, relative: url.lastPathComponent)
        }
        progress(visited)
        return result
    }

    private static func isWithin(_ url: URL, _ root: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path + "/")
    }

    private static func identity(_ url: URL) -> String {
        var info = stat()
        if stat(url.path, &info) == 0 { return "\(info.st_dev):\(info.st_ino)" }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
