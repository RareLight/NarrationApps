import Foundation
import UniformTypeIdentifiers

public struct FileDropResult: Sendable {
    public let urls: [URL]
    public let unavailableItems: Int
}

public enum FileDrop {
    /// Finder supplies file URLs, including file-reference URLs. Ask for its
    /// native NSURL representation rather than a generic Transferable URL or
    /// a temporary copy of PDF/Markdown contents. Import the whole group once.
    @MainActor
    public static func load(_ providers: [NSItemProvider]) async -> FileDropResult {
        var urls: [URL] = []
        var unavailable = 0
        for provider in providers {
            if Task.isCancelled { break }
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), provider.canLoadObject(ofClass: NSURL.self) else {
                unavailable += 1; continue
            }
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: NSURL.self) { object, error in
                    guard error == nil, let reference = object as? NSURL,
                          let path = reference.filePathURL, path.isFileURL else {
                        continuation.resume(returning: nil); return
                    }
                    continuation.resume(returning: path)
                }
            }
            if let url { urls.append(url) } else { unavailable += 1 }
        }
        return FileDropResult(urls: urls, unavailableItems: unavailable)
    }
}
