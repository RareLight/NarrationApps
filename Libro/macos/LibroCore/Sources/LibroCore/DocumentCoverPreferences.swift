import Foundation
import AudioOutput
import DocumentProcessing

public struct DocumentCoverPreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> [String: String] {
        defaults.dictionary(forKey: "LibroDocumentCovers") as? [String: String] ?? [:]
    }
    public func save(_ values: [String: String]) { defaults.set(values, forKey: "LibroDocumentCovers") }
    public func loadAutomaticExclusions() -> Set<String> {
        Set(defaults.stringArray(forKey: "LibroAutomaticCoverExclusions") ?? [])
    }
    public func saveAutomaticExclusions(_ values: Set<String>) {
        defaults.set(values.sorted(), forKey: "LibroAutomaticCoverExclusions")
    }
    public static func key(_ source: URL) -> String { source.standardizedFileURL.path }
    public static func automaticCovers(
        _ documents: [InputDocument], references: [String: String], excluding: Set<String>,
        store: CoverArtworkStore,
        readCover: @Sendable (InputDocument) throws -> Data? = { try DocumentReader.bookCover($0) },
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) throws -> [String: String] {
        let candidates = documents.filter {
            [.pdf, .epub].contains($0.kind) && references[key($0.source)] == nil && !excluding.contains(key($0.source))
        }
        var result: [String: String] = [:]
        progress(0, candidates.count)
        for (index, document) in candidates.enumerated() {
            try Task.checkCancellation()
            do {
                if let bytes = try readCover(document) {
                    let artwork = try CoverArtwork(data: bytes)
                    try Task.checkCancellation()
                    result[key(document.source)] = try store.save(artwork)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { }
            progress(index + 1, candidates.count)
        }
        try Task.checkCancellation()
        return result
    }
    public static func snapshot(_ documents: [InputDocument], references: [String: String],
                                store: CoverArtworkStore) throws -> [UUID: CoverArtwork] {
        var result: [UUID: CoverArtwork] = [:], cache: [String: CoverArtwork] = [:]
        for document in documents {
            try Task.checkCancellation()
            if let digest = references[key(document.source)] {
                let artwork = try cache[digest] ?? store.load(digest)
                cache[digest] = artwork; result[document.id] = artwork
            }
        }
        return result
    }
}
