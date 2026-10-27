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
            let pending = DropURLRequest()
            let url: URL? = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard pending.begin(continuation) else { return }
                    let progress = provider.loadObject(ofClass: NSURL.self) { object, error in
                        guard error == nil, let reference = object as? NSURL,
                              let path = reference.filePathURL, path.isFileURL else {
                            pending.finish(nil); return
                        }
                        pending.finish(path)
                    }
                    pending.setProgress(progress)
                }
            } onCancel: { pending.cancel() }
            if Task.isCancelled { break }
            if let url { urls.append(url) } else { unavailable += 1 }
        }
        return FileDropResult(urls: urls, unavailableItems: unavailable)
    }
}

/// The provider may ignore cancellation or call back late. Resolve our waiter
/// exactly once, cancel its Progress, and never wait for a provider to cooperate.
final class DropURLRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL?, Never>?
    private var progress: Progress?
    private var finished = false

    func begin(_ continuation: CheckedContinuation<URL?, Never>) -> Bool {
        let accepted = lock.withLock {
            guard !finished else { return false }
            self.continuation = continuation
            return true
        }
        if !accepted { continuation.resume(returning: nil) }
        return accepted
    }
    func setProgress(_ progress: Progress) {
        let cancel = lock.withLock {
            guard !finished else { return true }
            self.progress = progress
            return false
        }
        if cancel { progress.cancel() }
    }
    func finish(_ url: URL?) {
        let continuation = lock.withLock {
            guard !finished else { return nil as CheckedContinuation<URL?, Never>? }
            finished = true
            let current = self.continuation
            self.continuation = nil; progress = nil
            return current
        }
        continuation?.resume(returning: url)
    }
    func cancel() {
        let (continuation, progress) = lock.withLock {
            finished = true
            let current = (self.continuation, self.progress)
            self.continuation = nil; self.progress = nil
            return current
        }
        progress?.cancel()
        continuation?.resume(returning: nil)
    }
}
