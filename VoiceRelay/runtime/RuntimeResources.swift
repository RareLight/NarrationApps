import Foundation

public enum VoiceRelayRuntimeResources {
    public static func file(_ name: String) -> URL? { Bundle.module.url(forResource: name, withExtension: nil) }
}
