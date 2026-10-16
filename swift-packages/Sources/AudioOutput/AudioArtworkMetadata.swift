import Foundation
import AVFoundation

public enum AudioArtworkMetadata {
    /// Container-only passthrough. Never route tagged audio through a PCM encoder.
    static func addAAC(_ cover: CoverArtwork, to url: URL) async throws {
        try Task.checkCancellation()
        let output = url.deletingLastPathComponent().appendingPathComponent(".cover-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: output) }
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw ArtworkError.metadata }
        let original = try await asset.load(.metadata)
        let item = AVMutableMetadataItem()
        item.identifier = .iTunesMetadataCoverArt
        item.dataType = kCMMetadataBaseDataType_JPEG as String
        item.value = cover.data as NSData
        export.metadata = original.filter { $0.commonKey != .commonKeyArtwork } + [item]
        try await export.export(to: output, as: .m4a)
        try Task.checkCancellation()
        guard try await embeddedCover(in: output) == cover.data else { throw ArtworkError.metadata }
        guard rename(output.path, url.path) == 0 else { throw ArtworkError.metadata }
    }
    public static func embeddedCover(in url: URL) async throws -> Data? {
        let metadata = try await AVURLAsset(url: url).load(.metadata)
        for item in metadata where item.commonKey == .commonKeyArtwork {
            return try await item.load(.dataValue)
        }
        return nil
    }
}
