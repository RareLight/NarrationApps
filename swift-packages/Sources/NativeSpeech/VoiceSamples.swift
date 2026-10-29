import Foundation
import NarrationCore

public struct VoiceSample: Sendable, Identifiable {
    public let model: SpeechModel
    public let voice: String
    public let name: String
    public var id: String { "\(model.rawValue)-\(voice)" }
    /// The phrase recorded for the currently bundled assets, including regenerated samples.
    public var phrase: String? { VoiceSamples.phrases[id] }
    public var settings: SpeechSettings { .init(model: model, voice: voice, speed: 1) }
    public var url: URL? { Bundle.module.url(forResource: id, withExtension: "m4a", subdirectory: "VoiceSamples") }
}

/// Only the app-supported English inventory and Soprano's single voice, not every upstream voice.
public enum VoiceSamples {
    fileprivate static let phrases: [String: String] = {
        struct Manifest: Decodable {
            struct Record: Decodable { let id: String; let phrase: String }
            let samples: [Record]
        }
        guard let url = Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "VoiceSamples"),
              let data = try? Data(contentsOf: url), let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return [:] }
        return Dictionary(manifest.samples.map { ($0.id, $0.phrase) }, uniquingKeysWith: { first, _ in first })
    }()

    public static var catalog: [VoiceSample] {
        NativePrimaryCatalog.specification(for: .kokoro).voices.sorted().map {
            VoiceSample(model: .kokoro, voice: $0, name: String($0.dropFirst(3)).capitalized)
        } + [VoiceSample(model: .soprano, voice: "soprano", name: "Soprano")] +
        [SpeechModel.qwen3, .chatterbox, .orpheus].flatMap { model in
            model.presetVoices.map { VoiceSample(model: model, voice: $0, name: $0.replacingOccurrences(of: "_", with: " ").capitalized) }
        }
    }
    public static func sample(model: SpeechModel, voice: String) -> VoiceSample? {
        catalog.first { $0.model == model && (model == .soprano || $0.voice == voice) }
    }
}
