import Foundation
import AudioOutput

public struct DocumentCoverPreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> [String: String] {
        defaults.dictionary(forKey: "LibroDocumentCovers") as? [String: String] ?? [:]
    }
    public func save(_ values: [String: String]) { defaults.set(values, forKey: "LibroDocumentCovers") }
    public static func key(_ source: URL) -> String { source.standardizedFileURL.path }
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
