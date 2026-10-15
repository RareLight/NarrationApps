/// One startup assessment and one presentation per app session. No file access or downloads.
public struct SpeechSetupOnboarding: Sendable {
    public private(set) var needsSetup = false
    private var assessed = false
    private var presented = false
    public init() {}
    public mutating func assess(installed: Bool) {
        guard !assessed else { return }
        assessed = true
        needsSetup = !installed
    }
    public mutating func claimPresentation() -> Bool {
        guard needsSetup, !presented else { return false }
        presented = true
        return true
    }
}
