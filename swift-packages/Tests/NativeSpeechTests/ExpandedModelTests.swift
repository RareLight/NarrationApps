import XCTest
import NarrationCore
import DocumentProcessing
@testable import NativeSpeech
@testable import ProcessingPipeline

final class ExpandedModelTests: XCTestCase {
    func testCatalogAndVoiceLanguageValidation() throws {
        XCTAssertEqual(SpeechModel.qwen3.presetVoices.count, 9)
        XCTAssertEqual(SpeechModel.orpheus.presetVoices.count, 8)
        XCTAssertEqual(SpeechModel.orpheus.maximumGeneratedTokens, 4096)
        XCTAssertEqual(SpeechAcousticIdentity.provenance(settings: .init(model: .orpheus, voice: "leah"), policy: .nativeText)["maximumGeneratedTokens"], "4096")
        XCTAssertTrue(SpeechModel.qwen3.presetVoices.allSatisfy { SpeechModel.qwen3.nativeLanguage(for: $0) != nil })
        for model in SpeechModel.allCases {
            let specs = [NativePrimaryCatalog.specification(for: model)] + NativePrimaryCatalog.dependencies(for: model)
            XCTAssertGreaterThan(NativePrimaryCatalog.totalBytes(for: model), 0)
            for spec in specs {
                XCTAssertEqual(spec.revision.count, 40)
                XCTAssertEqual(Set(spec.files.map(\.path)).count, spec.files.count)
                XCTAssertTrue(spec.files.allSatisfy { $0.bytes > 0 && $0.sha256.count == 64 })
            }
            for voice in model.presetVoices {
                for language in model.languages { XCTAssertTrue(NativePrimaryCatalog.validates(.init(model: model, voice: voice, language: language))) }
            }
        }
        XCTAssertFalse(NativePrimaryCatalog.validates(.init(model: .qwen3, voice: "af_heart")))
        XCTAssertFalse(NativePrimaryCatalog.validates(.init(model: .chatterbox, voice: "default", language: "French")))
        XCTAssertFalse(NativePrimaryCatalog.validates(.init(model: .orpheus, voice: "leah", speed: 1.5)))
        XCTAssertTrue(NativePrimaryCatalog.validates(.init(model: .soprano, voice: "bf_emma", speed: 1.35)))
    }
    func testLegacyDecodeSwitchRestorationAndAcousticIsolation() throws {
        let old = try JSONDecoder().decode(SpeechSettings.self, from: Data(#"{"model":"kokoro","voice":"bf_emma","speed":1.35}"#.utf8))
        let qwen = old.switching(to: .qwen3)
        XCTAssertEqual(qwen.voice, "Ryan")
        XCTAssertEqual(qwen.speed, 1)
        XCTAssertEqual(qwen.switching(to: .kokoro).voice, old.voice)
        XCTAssertEqual(qwen.switching(to: .kokoro).speed, old.speed)
        var changed = qwen; changed.savedChoices = nil
        XCTAssertEqual(SpeechAcousticIdentity.make(settings: qwen, policy: .nativeText), SpeechAcousticIdentity.make(settings: changed, policy: .nativeText))
        changed.voice = "Aiden"
        XCTAssertNotEqual(SpeechAcousticIdentity.make(settings: qwen, policy: .nativeText), SpeechAcousticIdentity.make(settings: changed, policy: .nativeText))
        changed = qwen; changed.language = "French"
        XCTAssertNotEqual(SpeechAcousticIdentity.make(settings: qwen, policy: .nativeText), SpeechAcousticIdentity.make(settings: changed, policy: .nativeText))
    }
    func testNativeTextProjectionIsBoundedAndPreservesMappings() throws {
        let text = String(repeating: "This is an original sentence for bounded narration. ", count: 80)
        let doc = SemanticDocument(blocks: [.init(kind: .paragraph, text: text, origin: .authored)], extractorVersion: "fixture")
        for model in [SpeechModel.qwen3, .chatterbox, .orpheus] {
            let settings = SpeechSettings(model: model, voice: model.defaultVoice)
            let plan = try NarrationPlanner.prepareForSpeech(doc, settings: settings)
            XCTAssertEqual(plan.chunks.count, 1)
            XCTAssertEqual(plan.chunks.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace), text.split(whereSeparator: \.isWhitespace))
            XCTAssertTrue(plan.chunks.allSatisfy { $0.origin == .authored })
            XCTAssertEqual(plan.chunks[0].boundaryAfter, .paragraph)
        }
    }
    func testGuidanceIsBoundedAndLanguageScoped() {
        let initial = SpeechSettings()
        XCTAssertEqual(initial.model, .kokoro)
        XCTAssertEqual(initial.model, ModelGuidance.recommendedModel)
        XCTAssertEqual(initial.voice, "af_heart")
        XCTAssertEqual(initial.speed, 1)
        XCTAssertEqual(SpeechModel.allCases.filter { ModelGuidance.selectionLabel(for: $0).contains("Recommended") }, [.kokoro])
        for model in SpeechModel.allCases {
            let guide = ModelGuidance.guide(for: model)
            XCTAssertTrue((1...5).contains(guide.speed))
            if let quality = guide.quality { XCTAssertTrue((1...5).contains(quality)) }
            XCTAssertNil(ModelGuidance.guide(for: model, language: "Japanese").quality)
        }
        XCTAssertGreaterThan(ModelGuidance.guide(for: .kokoro).speed, ModelGuidance.guide(for: .qwen3).speed)
        XCTAssertGreaterThan(ModelGuidance.guide(for: .qwen3).speed, ModelGuidance.guide(for: .orpheus).speed)
        XCTAssertEqual(ModelGuidance.qualityLabel(nil), "Not rated")
    }
    func testModelMemorySupportGuardsAndWorkingThresholds() {
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        XCTAssertTrue(SpeechMemoryPolicy.canLoad(.kokoro, physicalMemory: 8 * gib))
        XCTAssertTrue(SpeechMemoryPolicy.canLoad(.soprano, physicalMemory: 8 * gib))
        for model in [SpeechModel.qwen3, .chatterbox] {
            XCTAssertFalse(SpeechMemoryPolicy.canLoad(model, physicalMemory: 8 * gib))
            XCTAssertTrue(SpeechMemoryPolicy.canLoad(model, physicalMemory: 16 * gib))
        }
        XCTAssertFalse(SpeechMemoryPolicy.canLoad(.orpheus, physicalMemory: 16 * gib))
        XCTAssertTrue(SpeechMemoryPolicy.canLoad(.orpheus, physicalMemory: 24 * gib))
        XCTAssertEqual(SpeechMemoryPolicy.workingLimit(for: .kokoro), SpeechMemoryPolicy.workingLimitBytes)
        XCTAssertGreaterThan(SpeechMemoryPolicy.workingLimit(for: .orpheus), SpeechMemoryPolicy.workingLimit(for: .qwen3))
    }
}

extension ExpandedModelTests {
    func testSpeedBandsStayStableAndRejectInvalidEvidence() {
        XCTAssertEqual(ModelGuidance.speedTier(referenceRTF: 0.0312), 5)
        XCTAssertEqual(ModelGuidance.speedTier(referenceRTF: 0.0744), 4)
        XCTAssertEqual(ModelGuidance.speedTier(referenceRTF: 0.2034), 3)
        XCTAssertEqual(ModelGuidance.speedTier(referenceRTF: 0.5462), 2)
        XCTAssertEqual(ModelGuidance.speedTier(referenceRTF: 2.0414), 1)
        XCTAssertNil(ModelGuidance.speedTier(referenceRTF: .nan))
        XCTAssertNil(ModelGuidance.speedTier(referenceRTF: 0))
    }
}
