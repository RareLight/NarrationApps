import Foundation
import Observation

/// Owns the provider-resolution interval before an intake scanner exists.
@MainActor @Observable
public final class FileDropImport {
    private var task: Task<Void, Never>?
    private var revision = UUID()
    public var hasOwnedWork: Bool { task != nil }
    public init() {}

    public func start(_ providers: [NSItemProvider], receive: @escaping @MainActor (FileDropResult) -> Void) {
        let previous = task
        previous?.cancel()
        let token = UUID(); revision = token
        task = Task {
            await previous?.value
            guard !Task.isCancelled, revision == token else { return }
            let result = await FileDrop.load(providers)
            guard revision == token else { return }
            task = nil
            guard !Task.isCancelled else { return }
            receive(result)
        }
    }

    public func cancel() {
        // Keep the handle until it has joined; invalidation precedes callbacks.
        revision = UUID()
        let previous = task
        previous?.cancel()
        let token = revision
        if previous != nil {
            task = Task {
                await previous?.value
                if revision == token { task = nil }
            }
        }
    }

    public func stop() async {
        cancel()
        let current = task
        await current?.value
    }
}
