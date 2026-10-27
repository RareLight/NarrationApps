import Foundation
import AudioOutput

/// Standard RSS metadata only. Recovery retains references without fetching
/// arbitrary transcript URLs or treating them as server-deletion authority.
public struct PodcastTranscriptReference: Codable, Sendable, Equatable {
    public static let namespace = "https://podcastindex.org/namespace/1.0"
    public let url: URL
    public let type: String
    public let language: String?
    public let rel: String?

    func validate() throws {
        guard url.scheme == "https", url.absoluteString.count <= 4096,
              (try? ArticleURL.validate(url)) != nil,
              ["text/vtt", "application/x-subrip", "text/plain", "text/html", "application/json"].contains(type),
              language == nil || Self.validLanguage(language!), rel == nil || rel == "captions" else {
            throw RelayError.artifact("The episode transcript reference is invalid.")
        }
    }
    static func validLanguage(_ value: String) -> Bool {
        value.count <= 64 && value.range(of: "^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$", options: .regularExpression) != nil
    }
}

/// Small durable text lives with the episode metadata, so temporary-audio and
/// article-cache cleanup cannot strand a transcript upload. No audio is embedded.
public struct EpisodeTranscript: Codable, Sendable, Equatable {
    static let maximumBytes = 4 * 1024 * 1024
    public let audioHash: String
    public let language: String
    public let vtt: String
    public let sha256: String
    public var delivery: DeliveryState? = nil

    func data(for hash: String?) throws -> Data {
        let bytes = Data(vtt.utf8)
        guard hash == audioHash, ServerRecoveryIdentity.validHash(audioHash),
              PodcastTranscriptReference.validLanguage(language), bytes.count <= Self.maximumBytes,
              vtt.hasPrefix("WEBVTT\n\n"), !vtt.contains("\0"), Files.hash(bytes) == sha256 else {
            throw RelayError.artifact("The timed transcript does not match this recording; saved audio is preserved.")
        }
        return bytes
    }
    func filename(id: String) -> String { id + "-" + sha256 + ".vtt" }
    func reference(id: String, settings: DeliverySettings) throws -> PodcastTranscriptReference {
        guard UUID(uuidString: id) != nil, ServerRecoveryIdentity.validHash(sha256), let base = settings.publicAudioBaseURL else {
            throw RelayError.setup("Configure publishing before uploading transcripts.")
        }
        let reference = PodcastTranscriptReference(url: base.appendingPathComponent(filename(id: id)), type: "text/vtt", language: language, rel: "captions")
        try reference.validate(); return reference
    }
    func remotePath(id: String, settings: DeliverySettings) -> String {
        DeliverySettings.join(settings.mediaFolder, filename(id: id))
    }
    func confirmed(id: String, settings: DeliverySettings) -> Bool {
        delivery?.status == .uploaded && delivery?.destinationURL == settings.feedFolderURL
            && delivery?.remotePath == remotePath(id: id, settings: settings)
            && delivery?.uploadedByteLength == Int64(vtt.utf8.count)
    }

    static func make(texts: [String], artifactCounts: [Int], timeline: [AudioSegmentTiming], language: String, audioHash: String) throws -> Self {
        guard !texts.isEmpty, texts.count <= 100_000, texts.count == artifactCounts.count,
              artifactCounts.allSatisfy({ $0 > 0 && $0 <= timeline.count }),
              artifactCounts.reduce(0, +) == timeline.count,
              texts.reduce(0, { $0 + $1.utf8.count }) <= maximumBytes,
              PodcastTranscriptReference.validLanguage(language), ServerRecoveryIdentity.validHash(audioHash) else { throw invalid }
        var output = "WEBVTT\n\n", position = 0, lastFrame: UInt64 = 0, lastEnd = 0
        let rate = timeline.first?.sampleRate ?? 0
        guard (8_000...192_000).contains(rate) else { throw invalid }
        for (index, raw) in texts.enumerated() {
            try Task.checkCancellation()
            let count = artifactCounts[index]
            let pieces = timeline[position..<(position + count)]
            for piece in pieces {
                guard piece.sampleRate == rate, piece.startFrame >= lastFrame,
                      piece.endFrame > piece.startFrame, piece.endFrame <= UInt64(rate) * 31 * 86_400 else { throw invalid }
                lastFrame = piece.endFrame
            }
            let start = max(lastEnd, Int((Double(pieces.first!.startFrame) * 1000 / Double(rate)).rounded()))
            let end = max(start + 1, Int((Double(pieces.last!.endFrame) * 1000 / Double(rate)).rounded()))
            // Plain cue text: normalize line breaks so article text cannot create
            // new cue blocks, escape markup and timestamp-arrow characters.
            let text = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
                .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            let escaped = String(String.UnicodeScalarView(text)).replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            guard !escaped.isEmpty else { throw invalid }
            output += "\(index + 1)\n\(timestamp(start)) --> \(timestamp(end))\n\(escaped)\n\n"
            guard output.utf8.count <= maximumBytes else { throw invalid }
            lastEnd = end; position += count
        }
        return Self(audioHash: audioHash, language: language, vtt: output, sha256: Files.hash(Data(output.utf8)))
    }
    private static var invalid: RelayError { .artifact("Timed transcript segments are incomplete or invalid; saved audio is preserved.") }
    private static func timestamp(_ milliseconds: Int) -> String {
        String(format: "%02d:%02d:%02d.%03d", milliseconds / 3_600_000, milliseconds / 60_000 % 60,
               milliseconds / 1000 % 60, milliseconds % 1000)
    }
}

extension Episode {
    func transcriptUploadDue(settings: DeliverySettings, force: Bool, now: Date) -> Bool {
        guard let transcript, transcript.audioHash == audioHash, delivery?.status == .uploaded,
              delivery?.destinationURL == settings.feedFolderURL else { return false }
        if force { return true }
        if transcript.confirmed(id: id, settings: settings) { return false }
        let copy = transcript.delivery
        if copy?.destinationURL != settings.feedFolderURL || copy?.remotePath != transcript.remotePath(id: id, settings: settings) { return true }
        return copy?.status != .failed && (copy?.nextAttemptAt == nil || copy!.nextAttemptAt! <= now)
    }

    /// Only app-owned content-addressed files in this destination can be retired.
    func ownedTranscriptPaths(settings: DeliverySettings) -> [String] {
        guard let base = settings.publicAudioBaseURL else { return [] }
        return (transcriptReferences ?? []).compactMap { reference in
            let filename = reference.url.lastPathComponent
            guard filename.hasPrefix(id + "-"), filename.hasSuffix(".vtt"),
                  ServerRecoveryIdentity.validHash(String(filename.dropFirst(id.count + 1).dropLast(4))),
                  reference.url == base.appendingPathComponent(filename) else { return nil }
            return DeliverySettings.join(settings.mediaFolder, filename)
        }
    }
}

extension WebDAVClient {
    func confirmTranscript(_ transcript: EpisodeTranscript, id: String, audioHash: String?) async throws {
        let data = try transcript.data(for: audioHash)
        let path = transcript.remotePath(id: id, settings: settings), url = try remoteURL(path)
        func read() async throws -> DeliveryResponse {
            try await transport.read(url, headers: recoveryHeaders(url), maximumBytes: Int64(EpisodeTranscript.maximumBytes))
        }
        let previous = try await read()
        if previous.status == 200 {
            guard previous.body == data else { throw DeliveryError.fatal("An existing transcript has different contents; it was not replaced.") }
            return
        }
        guard previous.status == 404 else { throw DeliveryError.classify(previous.status) }
        try await uploadData(data, remotePath: path, contentType: "text/vtt; charset=utf-8", onlyIfMissing: true)
        let actual = try await read()
        guard actual.status == 200, actual.body == data else {
            throw DeliveryError.retryable("The uploaded transcript could not be confirmed; its feed link remains pending.")
        }
    }
}

extension FixtureCoordinator {
    /// Independent sidecar delivery: a failed transcript never blocks other audio
    /// or feed entries. A reference is added only after exact-byte readback.
    func deliverTranscripts(store: PipelineStore, settings: DeliverySettings, client: WebDAVClient,
                            force: Bool, now: Date, ledger: inout DeliveryLedger, result: inout DeliveryResult) async throws {
        for var episode in try store.published() where episode.transcriptUploadDue(settings: settings, force: force, now: now)
            && ledger.blockedServerIDs?.contains(episode.id) != true {
            try Task.checkCancellation()
            guard var transcript = episode.transcript else { continue }
            let wasConfirmed = transcript.confirmed(id: episode.id, settings: settings)
            let path = transcript.remotePath(id: episode.id, settings: settings)
            var copy = transcript.delivery ?? DeliveryState(status: .pending, remotePath: path)
            if copy.destinationURL != settings.feedFolderURL || copy.remotePath != path {
                copy = DeliveryState(status: .pending, remotePath: path)
            }
            copy.destinationURL = settings.feedFolderURL; copy.attempts += 1; copy.lastAttemptAt = now
            transcript.delivery = copy; episode.transcript = transcript
            try store.save(episode) // intent survives cancellation after a PUT
            do {
                try await client.confirmTranscript(transcript, id: episode.id, audioHash: episode.audioHash)
                let reference = try transcript.reference(id: episode.id, settings: settings)
                var references = (episode.transcriptReferences ?? []).filter {
                    $0.url.lastPathComponent != transcript.filename(id: episode.id)
                }
                if !references.contains(reference) { references.append(reference) }
                guard references.count <= 8 else { throw RelayError.artifact("Too many episode transcript references.") }
                let referencesChanged = references != (episode.transcriptReferences ?? [])
                episode.transcriptReferences = references
                copy.status = .uploaded; copy.uploadedByteLength = Int64(transcript.vtt.utf8.count)
                copy.lastError = nil; copy.nextAttemptAt = nil
                if referencesChanged || !wasConfirmed { ledger.remoteFeedPending = true }
                if !wasConfirmed { result.uploadedTranscripts += 1 }
            } catch is CancellationError { throw CancellationError() }
            catch {
                // Errors are sanitized; transcript contents and URLs never enter logs.
                copy.status = .pending
                copy.lastError = "The timed transcript could not be published. Audio publishing can continue; Sync Now retries it."
                copy.nextAttemptAt = now + Self.deliveryBackoff(copy.attempts)
                switch error as? DeliveryError {
                case .authFailed, .credentialUnavailable, .permissionDenied, .fatal: copy.status = .failed; copy.nextAttemptAt = nil
                default: if error is RelayError { copy.status = .failed; copy.nextAttemptAt = nil }
                }
                if copy.status == .failed { result.failed += 1 } else { result.retrying += 1 }
            }
            transcript.delivery = copy; episode.transcript = transcript
            try store.save(episode)
        }
    }
}
