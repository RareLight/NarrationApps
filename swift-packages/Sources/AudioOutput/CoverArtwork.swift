import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import CryptoKit

public enum ArtworkError: Error, LocalizedError {
    case invalidImage, tooLarge, podcastRequirements, unavailable, metadata
    public var errorDescription: String? {
        switch self {
        case .invalidImage: "Choose a valid JPEG or PNG cover image."
        case .tooLarge: "The cover image exceeds the supported image size. Choose a smaller image."
        case .podcastRequirements: "Podcast covers must be square, at least 1400 pixels per side, and have no transparency."
        case .unavailable: "The selected cover is unavailable. Replace or remove it before exporting."
        case .metadata: "The cover could not be embedded. The previous output has been preserved."
        }
    }
}

/// Validated, metadata-free JPEG derivative. Book art is bounded to LAME's 128 KiB
/// album-art limit; the separate podcast profile retains show-cover resolution.
public struct CoverArtwork: Sendable, Equatable {
    public enum Profile: Sendable { case book, podcast }
    public let data: Data
    public let width: Int
    public let height: Int
    public var digest: String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static let maximumInputBytes = 20 * 1024 * 1024
    public static let maximumPixels = 40_000_000
    public static let maximumStoredBytes = 2 * 1024 * 1024

    public init(data: Data, profile: Profile = .book) throws {
        try Task.checkCancellation()
        let (source, width, height, alpha) = try Self.source(data)
        if profile == .podcast, width != height || width < 1400 || alpha { throw ArtworkError.podcastRequirements }
        var edge = profile == .podcast ? 3000 : 1200
        let budget = profile == .podcast ? Self.maximumStoredBytes : 120 * 1024
        while edge >= 300 {
            try Task.checkCancellation()
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: edge
            ] as CFDictionary), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ArtworkError.invalidImage }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let opaque = context.makeImage() else { throw ArtworkError.invalidImage }
            for quality in [0.85, 0.65, 0.45] {
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw ArtworkError.invalidImage }
                CGImageDestinationAddImage(destination, opaque, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw ArtworkError.invalidImage }
                if output.length <= budget {
                    self.data = output as Data; self.width = opaque.width; self.height = opaque.height
                    return
                }
            }
            if profile == .podcast { break }
            edge /= 2
        }
        throw ArtworkError.tooLarge
    }

    /// Read only our already-prepared derivative, without another JPEG conversion.
    public init(preparedData: Data) throws {
        guard preparedData.count <= Self.maximumStoredBytes else { throw ArtworkError.tooLarge }
        let (source, width, height, _) = try Self.source(preparedData)
        guard CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              max(width, height) <= 3000,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 144] as CFDictionary) != nil else { throw ArtworkError.invalidImage }
        self.data = preparedData; self.width = width; self.height = height
    }

    private static func source(_ data: Data) throws -> (CGImageSource, Int, Int, Bool) {
        guard !data.isEmpty, data.count <= maximumInputBytes else { throw ArtworkError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source) as String?,
              [UTType.jpeg.identifier, UTType.png.identifier].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16000, height <= 16000 else { throw ArtworkError.invalidImage }
        guard width * height <= maximumPixels else { throw ArtworkError.tooLarge }
        return (source, width, height, properties[kCGImagePropertyHasAlpha] as? Bool ?? false)
    }

    public func thumbnailData() throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 144] as CFDictionary) else { throw ArtworkError.invalidImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw ArtworkError.invalidImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ArtworkError.invalidImage }
        return output as Data
    }

    public static func read(_ url: URL, profile: Profile = .book) throws -> CoverArtwork {
        try .init(data: boundedRead(url, limit: maximumInputBytes), profile: profile)
    }
    static func boundedRead(_ url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ArtworkError.tooLarge }
        return data
    }
}

/// App-owned, content-addressed assets. No original file bookmarks or image paths
/// enter feed metadata. Libraries/backups do not implicitly own Publishing settings.
public struct CoverArtworkStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public static func application(_ name: String) -> Self {
        .init(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name).appendingPathComponent("CoverArtwork"))
    }
    public func url(for digest: String) throws -> URL {
        guard digest.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ArtworkError.unavailable }
        return root.appendingPathComponent(digest + ".jpg")
    }
    public func save(_ artwork: CoverArtwork) throws -> String {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try artwork.data.write(to: url(for: artwork.digest), options: .atomic)
        return artwork.digest
    }
    /// Only canonical, byte-confirmed derivatives in this app-owned directory.
    /// Call while the app holds its artwork-edit ownership; originals are never scanned.
    public func removeUnreferenced(keeping digests: Set<String>) throws {
        guard FileManager.default.fileExists(atPath: root.path),
              (try root.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { return }
        for candidate in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            try Task.checkCancellation()
            let digest = candidate.deletingPathExtension().lastPathComponent
            guard candidate.pathExtension == "jpg", !digests.contains(digest),
                  (try? url(for: digest)) != nil,
                  let properties = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  properties.isRegularFile == true, properties.isSymbolicLink != true,
                  let data = try? CoverArtwork.boundedRead(candidate, limit: CoverArtwork.maximumStoredBytes),
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else { continue }
            try FileManager.default.removeItem(at: candidate)
        }
    }
    public func load(_ digest: String) throws -> CoverArtwork {
        do {
            let value = try CoverArtwork(preparedData: CoverArtwork.boundedRead(url(for: digest), limit: CoverArtwork.maximumStoredBytes))
            guard value.digest == digest else { throw ArtworkError.unavailable }
            return value
        } catch { throw ArtworkError.unavailable }
    }
}
