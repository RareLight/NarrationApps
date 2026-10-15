import Foundation

public struct KokoroConfiguration: Sendable {
    public let projectRoot: URL
    public let voice: String
    public let speed: Double
    public let prepareTimeout: TimeInterval
    public let synthesisTimeout: TimeInterval
    public init(projectRoot: URL, voice: String = "af_heart", speed: Double = 1,
                prepareTimeout: TimeInterval = 180, synthesisTimeout: TimeInterval = 600) throws {
        guard projectRoot.isFileURL, voice.range(of: "^[ab][fm]_[a-z0-9_]+$", options: .regularExpression) != nil,
              speed.isFinite, (0.25...4).contains(speed), prepareTimeout > 0, synthesisTimeout > 0,
              prepareTimeout.isFinite, synthesisTimeout.isFinite else { throw RelayError.setup("Invalid Kokoro runtime, voice, speed, or deadline.") }
        self.projectRoot = projectRoot.resolvingSymlinksInPath().standardizedFileURL
        self.voice = voice; self.speed = speed; self.prepareTimeout = prepareTimeout; self.synthesisTimeout = synthesisTimeout
    }
}
