import Foundation
import CryptoKit
import AVFoundation
import Darwin

/// User-imported immutable reference recordings. Shared between the apps, never
/// uploaded and never removed by model/cache cleanup. Reimport restores an ID.
public struct ReferenceVoice: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
}
public struct ReferenceVoiceStore: Sendable {
    public let root: URL
    public init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SwiftNarration/ReferenceVoices")) { self.root = root }
    public static func isIdentifier(_ voice: String) -> Bool {
        voice.hasPrefix("reference:") && voice.count == 74 && voice.dropFirst(10).allSatisfy { $0.isASCII && ($0.isNumber || "abcdef".contains($0)) }
    }
    public func profiles() throws -> [ReferenceVoice] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard root.standardizedFileURL == root.resolvingSymlinksInPath() else { throw NativeAssetError.outsideWorkspace }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.prefix(256).compactMap { url -> ReferenceVoice? in
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 4096,
                      let profile = try? JSONDecoder().decode(ReferenceVoice.self, from: Data(contentsOf: url)),
                      profile.id == "reference:" + url.deletingPathExtension().lastPathComponent,
                      profile.name.count <= 80 else { return nil }
                return profile
            }
            .filter { Self.isIdentifier($0.id) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func importRecording(_ source: URL) throws -> ReferenceVoice {
        try Task.checkCancellation()
        let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
        guard source.pathExtension.lowercased() == "wav", (try source.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 <= 20_000_000 else { throw NativeAssetError.invalid("Reference must be a WAV smaller than 20 MB") }
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        guard (5...30).contains(seconds), (1...2).contains(file.processingFormat.channelCount) else { throw NativeAssetError.invalid("Use a five-to-thirty-second mono or stereo WAV") }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { throw NativeAssetError.invalid("reference audio") }
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { throw NativeAssetError.invalid("reference audio") }
            for channel in 0..<Int(file.processingFormat.channelCount) {
                guard UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength)).allSatisfy(\.isFinite) else { throw NativeAssetError.invalid("nonfinite reference audio") }
            }
        }
        let bytes = try Data(contentsOf: source)
        guard bytes.count <= 20_000_000 else { throw NativeAssetError.invalid("reference recording size") }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let profile = ReferenceVoice(id: "reference:" + hash, name: String(source.deletingPathExtension().lastPathComponent.prefix(80)))
        try prepareRoot()
        try Task.checkCancellation()
        try create(bytes, at: root.appendingPathComponent(hash + ".wav"))
        let metadata = root.appendingPathComponent(hash + ".json")
        if !FileManager.default.fileExists(atPath: metadata.path) { try create(JSONEncoder().encode(profile), at: metadata) }
        return profile
    }
    public func bytes(for identifier: String) throws -> Data {
        guard Self.isIdentifier(identifier) else { throw NativeAssetError.invalid("reference voice identifier") }
        guard root.standardizedFileURL == root.resolvingSymlinksInPath() else { throw NativeAssetError.outsideWorkspace }
        let path = root.appendingPathComponent(String(identifier.dropFirst(10)) + ".wav")
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 20_000_000 else { throw NativeAssetError.invalid("reference recording") }
        let data = try Data(contentsOf: path)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard identifier == "reference:" + hash else { throw NativeAssetError.changed("reference recording") }
        return data
    }
    private func prepareRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard root.standardizedFileURL == root.resolvingSymlinksInPath() else { throw NativeAssetError.outsideWorkspace }
    }
    private func create(_ data: Data, at path: URL) throws {
        let fd = open(path.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        if fd < 0 {
            guard errno == EEXIST, (try FileManager.default.attributesOfItem(atPath: path.path)[.type]) as? FileAttributeType == .typeRegular, try Data(contentsOf: path) == data else { throw NativeAssetError.changed("reference profile") }
            return
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
    }
}
