import Foundation
import AVFoundation
import AudioToolbox
import XCTest
import NativeSpeech
import NarrationCore
import AudioOutput

final class VoiceSampleTests: XCTestCase {
    func testEveryPresentedVoiceHasAnIntactFiniteAACSampleAndRecordedPhrase() throws {
        let samples = VoiceSamples.catalog
        XCTAssertEqual(samples.count, 47)
        XCTAssertEqual(Set(samples.map(\.id)).count, samples.count)
        XCTAssertEqual(Set(samples.filter { $0.model == .kokoro }.map(\.voice)), Set(NativePrimaryCatalog.specification(for: .kokoro).voices))
        let folder = try XCTUnwrap(samples.first?.url).deletingLastPathComponent()
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        XCTAssertEqual(manifest["version"] as? Int, 3)
        let records = try XCTUnwrap(manifest["samples"] as? [[String: Any]])
        XCTAssertEqual(records.count, samples.count)
        for sample in samples {
            let record = try XCTUnwrap(records.first { $0["id"] as? String == sample.id })
            XCTAssertEqual(record["phrase"] as? String, sample.phrase)
            XCTAssertEqual(record["bitRate"] as? Int, 64_000)
            let preparedObject = try XCTUnwrap(record["preparedSpeech"] as? [String: Any])
            let plan = try JSONDecoder().decode(PreparedSpeechPlan.self, from: JSONSerialization.data(withJSONObject: preparedObject))
            XCTAssertEqual(plan.settings, sample.settings)
            // Bundled samples retain their recorded preparation, independent of
            // the policy used for newly generated narration.
            XCTAssertEqual(plan.policy, sample.model.isLarge ? .nativeText : sample.model == .kokoro ? .longformPausesCandidate : .legacy)
            XCTAssertNotNil(plan.provenance)
            XCTAssertFalse(plan.utterances.isEmpty)
            for utterance in plan.utterances {
                try utterance.validate(identity: plan.acousticIdentity, prepared: sample.model == .kokoro)
            }
            XCTAssertEqual(record["modelRevision"] as? String, NativePrimaryCatalog.specification(for: sample.model).revision)

            XCTAssertFalse(try XCTUnwrap(sample.phrase).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let inputText = manifest["inputText"] as? String { XCTAssertEqual(sample.phrase, inputText) }
            let url = try XCTUnwrap(sample.url, sample.id)
            XCTAssertEqual(record["sha256"] as? String, try NativeG2P.sha256(url))
            let info = try NativeAudio.inspect(url)
            XCTAssertEqual(info.codec, "aac"); XCTAssertEqual(info.sampleRate, 24_000); XCTAssertEqual(info.channels, 1)
            let audio = try AVAudioFile(forReading: url)
            XCTAssertEqual(audio.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC) // Standard AAC, not AAC-HE or AAC-HE v2.
            var nonzero = false
            try NativeAudio.decode(url) { frames in
                XCTAssertTrue(frames.allSatisfy(\.isFinite))
                nonzero = nonzero || frames.contains { abs($0) > 0.00001 }
            }
            XCTAssertTrue(nonzero, sample.id)
        }
        XCTAssertNil(VoiceSamples.sample(model: .kokoro, voice: "jf_alpha"))
        XCTAssertEqual(VoiceSamples.sample(model: .soprano, voice: "ignored")?.name, "Soprano")
    }
}
