import AVFoundation
import Observation

@MainActor protocol PreviewPlayback: AnyObject {
    var isPlaying: Bool { get }
    func play() -> Bool
    func stop()
}
extension AVAudioPlayer: PreviewPlayback {}

/// Native playback of short audio previews. Never starts inference or changes sample gain.
@MainActor @Observable public final class AudioPreviewPlayer {
    public private(set) var playingID: String?
    public private(set) var error: String?
    @ObservationIgnored private var player: (any PreviewPlayback)?
    @ObservationIgnored private var completion: Task<Void, Never>?
    @ObservationIgnored private let makePlayer: @MainActor (URL) throws -> any PreviewPlayback
    public init() { makePlayer = { try AVAudioPlayer(contentsOf: $0) } }
    init(makePlayer: @escaping @MainActor (URL) throws -> any PreviewPlayback) { self.makePlayer = makePlayer }
    public func toggle(url: URL?, id: String) {
        if playingID == id { stop(); return }
        stop()
        guard let url else { error = "This voice sample is unavailable."; return }
        do {
            let audio = try makePlayer(url)
            guard audio.play() else { throw AudioOutputError.storage }
            player = audio; playingID = id
            completion = Task { [weak self] in
                while audio.isPlaying {
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                }
                guard let self, self.playingID == id else { return }
                self.stop()
            }
        } catch { self.error = "The voice sample could not be played. Try again." }
    }
    public func stop() {
        completion?.cancel(); completion = nil
        player?.stop(); player = nil; playingID = nil; error = nil
    }
}
