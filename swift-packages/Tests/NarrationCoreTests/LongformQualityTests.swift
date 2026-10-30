import XCTest
import Pronunciation
@testable import NarrationCore

final class LongformQualityTests: XCTestCase {
    func testSemanticPlanningIsMandatoryForEveryModelIncludingSavedAndExplicitLegacySettings() throws {
        let requested: [SpeechPreparationPolicy] = [.legacy, .correctnessCandidate, .longformCandidate, .longformPausesCandidate, .semanticCandidate, .nativeText, .current]
        for model in SpeechModel.allCases {
            let expectedPolicy: SpeechPreparationPolicy = model == .kokoro ? .current : .nativeText
            let old = try JSONDecoder().decode(SpeechSettings.self,
                from: Data("{\"model\":\"\(model.rawValue)\",\"voice\":\"\(model.defaultVoice)\",\"speed\":1}".utf8))
            XCTAssertNil(old.planning)
            for planning in [nil, SpeechPlanning.semanticCandidate] {
                var settings = old; settings.planning = planning
                XCTAssertEqual(settings.effectivePlanning, .semanticCandidate)
                for policy in requested {
                    XCTAssertEqual(SpeechPreparationPolicy.selected(settings: settings, requested: policy), expectedPolicy, "\(model.rawValue)/\(policy)")
                    let projection = try NarrationPlanner.prepareForSpeech(.init(blocks: [.init(kind: .paragraph, text: "A behind-the-scenes look.")], extractorVersion: "test"), settings: settings, policy: policy)
                    XCTAssertEqual(NarrationPlanner.version(settings: settings), NarrationPlanner.version(settings: old))
                    XCTAssertTrue(projection.version.hasSuffix("/spoken-projection-1"))
                    XCTAssertEqual(projection.chunks.count, 1)
                    let chunk = try XCTUnwrap(projection.chunks.first)
                    XCTAssertEqual(chunk.text, "A behind-the-scenes look.")
                    XCTAssertEqual(chunk.blockIndices, [0])
                    XCTAssertEqual(chunk.boundaryAfter, .paragraph)
                    XCTAssertEqual(chunk.origin, .authored)
                    for mapping in chunk.sourceMappings ?? [] {
                        XCTAssertGreaterThanOrEqual(mapping.spokenLocation, 0)
                        XCTAssertLessThanOrEqual(mapping.spokenLocation + mapping.spokenLength, chunk.text.utf16.count)
                    }
                }
                // Switching models must not change the mandatory semantic behavior.
                for target in SpeechModel.allCases {
                    XCTAssertEqual(settings.switching(to: target).effectivePlanning, .semanticCandidate)
                }
            }
            XCTAssertTrue(NarrationPlanner.version(settings: old).contains("semantic-boundaries-1") == (model != .kokoro), model.rawValue)
        }
    }
    func testCompoundHyphensDoNotBecomePausePhonesOrPackingBoundaries() throws {
        for separator in ["-", "\u{2010}", "\u{2011}"] {
            let compound = "behind\(separator)the\(separator)scenes"
            let text = "Quiet readers enjoy a \(compound) explanation together."
            let ns = text as NSString
            let pattern = try NSRegularExpression(pattern: #"[\p{L}\p{M}]+|[^\s]"#)
            let tokens = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match -> AlignedPhonemeToken in
                let next = NSMaxRange(match.range)
                let raw = ns.substring(with: match.range)
                return .init(range: match.range, phonemes: raw == separator ? "—" : String(repeating: "a", count: raw == "Quiet" ? 100 : 40),
                    whitespace: next < ns.length && ns.substring(with: NSRange(location: next, length: 1)) == " " ? " " : "")
            }
            let window = SpeechTextWindow(text: text, source: .init(blockIndices: [3], location: 10, length: ns.length, origin: .authored), boundaryAfter: .paragraph)
            let packed = try PhonemeUtterancePacker.pack(window: window, tokens: tokens, vocabulary: ["a", " ", "—"], identity: "test", semantic: true)
            XCTAssertTrue(packed.contains { $0.text.contains(compound) })
            XCTAssertFalse(packed.contains { $0.phonemes!.contains("—") })
            XCTAssertEqual(packed.map(\.text).joined(separator: " "), text)
            XCTAssertTrue(packed.allSatisfy { $0.tokenCount <= 510 })
            try PreparedSpeechCoverage.validate(packed, window: window)
            for value in packed { try value.validate(identity: "test", prepared: true) }
        }
    }
    func testCompoundHandlingPreservesRealDashesAndRefusesAnOverLimitCompound() throws {
        let text = "a - b 2-3 c—d e–f"
        let ns = text as NSString
        let tokens = try NSRegularExpression(pattern: #"[^\s]"#).matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match -> AlignedPhonemeToken in
            let raw = ns.substring(with: match.range), end = NSMaxRange(match.range)
            return .init(range: match.range, phonemes: "-—–".contains(raw) ? "—" : "a", whitespace: end < ns.length && ns.substring(with: NSRange(location: end, length: 1)) == " " ? " " : "")
        }
        let window = SpeechTextWindow(text: text, source: .init(blockIndices: [0], location: 0, length: ns.length), boundaryAfter: .paragraph)
        let packed = try PhonemeUtterancePacker.pack(window: window, tokens: tokens, vocabulary: ["a", " ", "—"], identity: "test", semantic: true)
        XCTAssertEqual(packed.map { $0.phonemes!.filter { $0 == "—" }.count }.reduce(0, +), 4)
        let long = SpeechTextWindow(text: "one-two-three", source: .init(blockIndices: [0], location: 0, length: 13), boundaryAfter: .paragraph)
        let longTokens: [AlignedPhonemeToken] = [
            .init(range: NSRange(location: 0, length: 3), phonemes: String(repeating: "a", count: 200), whitespace: ""),
            .init(range: NSRange(location: 3, length: 1), phonemes: "—", whitespace: ""),
            .init(range: NSRange(location: 4, length: 3), phonemes: String(repeating: "a", count: 200), whitespace: ""),
            .init(range: NSRange(location: 7, length: 1), phonemes: "—", whitespace: ""),
            .init(range: NSRange(location: 8, length: 5), phonemes: String(repeating: "a", count: 200), whitespace: "")]
        XCTAssertThrowsError(try PhonemeUtterancePacker.pack(window: long, tokens: longTokens, vocabulary: ["a", " ", "—"], identity: "test", semantic: true))
    }
    func testDensePhoneOverridesStayInsideControlLimitWithoutLosingWords() throws {
        let dictionary = try PronunciationDictionary(entries: [.init(word: "A", spelling: "", model: "kokoro", phonemes: String(repeating: "a", count: 500))]).resolving(language: "en", documentTitle: nil, model: "kokoro")
        let text = Array(repeating: "A", count: 400).joined(separator: " "), applied = try dictionary.applyingWithMappings(to: text)
        let window = SpeechTextWindow(text: applied.text, source: .init(blockIndices: [0], location: 0, length: text.utf16.count, pronunciationApplications: applied.applications), boundaryAfter: .paragraph)
        let windows = try SpeechTextWindows.boundedForControl([window])
        XCTAssertGreaterThan(windows.count, 1)
        XCTAssertEqual(windows.map(\.text).joined(separator: " "), text)
        XCTAssertEqual(windows.compactMap { $0.source.pronunciationApplications?.count }.reduce(0, +), 400)
        for part in windows {
            let data = try SpeechIPC.encode(WorkerCommand(kind: .prepareText, identity: .init(batch: UUID(), job: UUID()), chunk: 0, textWindow: part))
            XCTAssertLessThan(data.count, SpeechIPC.maximumRecordBytes)
            XCTAssertTrue(part.source.pronunciationApplications!.allSatisfy { $0.spokenLocation >= part.source.location && $0.spokenLocation + $0.spokenLength <= part.source.location + part.source.length })
        }
    }
    func testKokoroCandidateCanFinishASentenceBeyondTheAcceptedSoftTarget() throws {
        let text = "A measured explanation ends right here. Another quiet sentence follows nearby."
        let ns = text as NSString
        var offset = 0
        let tokens: [AlignedPhonemeToken] = text.split(separator: " ").map { word in
            let range = ns.range(of: String(word), range: NSRange(location: offset, length: ns.length - offset)); offset = NSMaxRange(range)
            return .init(range: range, phonemes: String(repeating: "a", count: 35), whitespace: offset == ns.length ? "" : " ")
        }
        let window = SpeechTextWindow(text: text, source: .init(blockIndices: [0], location: 0, length: text.utf16.count), boundaryAfter: .paragraph)
        let baseline = try PhonemeUtterancePacker.pack(window: window, tokens: tokens, vocabulary: ["a", " "], identity: "test")
        let candidate = try PhonemeUtterancePacker.pack(window: window, tokens: tokens, vocabulary: ["a", " "], identity: "test", semantic: true)
        XCTAssertFalse(baseline[0].text.hasSuffix("here."))
        XCTAssertTrue(candidate[0].text.hasSuffix("here.")); XCTAssertEqual(candidate[0].boundaryAfter, .sentence)
        XCTAssertEqual(candidate.map(\.text).joined(separator: " "), text)
        XCTAssertTrue(candidate.allSatisfy { $0.tokenCount <= 510 })
    }
    func testSemanticSlicesPreserveUnicodeAndRespectActualBudget() throws {
        let texts = ["“Café 😀 is open,” she said. A short reply followed. Then the readers walked home together.",
                     "これは長い文章です。次の文章も読みます。今日は良い天気です。", "A value of 12.5 kg is reliable; this sentence has a longer explanation, because the samples differ."]
        for text in texts {
            let slices = try SemanticSpeechSegmentation.slices(text, target: 25, maximum: 70) { $0.unicodeScalars.count }
            XCTAssertEqual(slices.map { String(text[$0.range]) }.joined(), text)
            XCTAssertTrue(slices.allSatisfy { text[$0.range].trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count <= 70 })
        }
        XCTAssertThrowsError(try SemanticSpeechSegmentation.slices(String(repeating: "a", count: 600), target: 96, maximum: 512) { $0.count })
    }
    func testTokenBudgetIsNotCharacterBudgetAndClosingQuotesStayAttached() throws {
        let text = "“First sentence ends here.” Another sentence follows immediately. This is the final sentence."
        let slices = try SemanticSpeechSegmentation.slices(text, target: 5, maximum: 12) { $0.split(separator: " ").count }
        XCTAssertEqual(slices.map { String(text[$0.range]) }.joined(), text)
        XCTAssertTrue(slices.allSatisfy { text[$0.range].split(separator: " ").count <= 12 })
        XCTAssertFalse(slices.dropFirst().contains { text[$0.range].trimmingCharacters(in: .whitespaces).hasPrefix("”") })
    }
    func testMandatorySemanticCapturesVersionAndRetainsFullParagraphForNativePacking() throws {
        var settings = SpeechSettings(model: .qwen3, voice: "Ryan")
        let text = Array(repeating: "A quiet reader waits beside the river.", count: 30).joined(separator: " ")
        let document = SemanticDocument(blocks: [.init(kind: .paragraph, text: text)], extractorVersion: "test")
        let baseline = try NarrationPlanner.prepareForSpeech(document, settings: settings)
        settings.planning = .semanticCandidate
        let candidate = try NarrationPlanner.prepareForSpeech(document, settings: settings)
        XCTAssertEqual(baseline.chunks.count, 1); XCTAssertEqual(candidate.chunks.count, 1)
        XCTAssertEqual(baseline.version, candidate.version)
        XCTAssertTrue(candidate.version.contains("semantic-boundaries-1"))
        XCTAssertEqual(candidate.chunks[0].text, text)
        XCTAssertEqual(candidate.chunks[0].boundaryAfter, .paragraph)
        XCTAssertEqual(candidate.chunks[0].blockIndices, [0])
        XCTAssertEqual(candidate.chunks[0].sourceMappings, nil)
        XCTAssertEqual(SpeechPreparationPolicy.current, .semantic)
    }
    func testPhonemeOverridesRequireExactAlignedSpansAndPreserveSource() throws {
        let dictionary = try PronunciationDictionary(entries: [.init(word: "Mina", spelling: "", model: "kokoro", phonemes: "mina")])
            .resolving(language: "en-US", documentTitle: nil, model: "kokoro")
        let applied = try dictionary.applyingWithMappings(to: "Mina waits")
        let window = SpeechTextWindow(text: applied.text, source: .init(blockIndices: [2], location: 0, length: applied.text.utf16.count, pronunciationApplications: applied.applications), boundaryAfter: .paragraph)
        let tokens: [AlignedPhonemeToken] = [.init(range: NSRange(location: 0, length: 4), phonemes: "wrong", whitespace: " "), .init(range: NSRange(location: 5, length: 5), phonemes: "waits", whitespace: "")]
        let corrected = try PronunciationPhoneOverrides.apply(window: window, tokens: tokens)
        XCTAssertEqual(corrected.first?.phonemes, "mina"); XCTAssertEqual(corrected.first?.range, tokens.first?.range)
        XCTAssertThrowsError(try PronunciationPhoneOverrides.apply(window: window, tokens: Array(tokens.dropFirst())))
        XCTAssertThrowsError(try PhonemeUtterancePacker.pack(window: window, tokens: corrected, vocabulary: ["a"], identity: "test"))
    }
    func testEnglishSpokenFormsAreExplicitAndNeverLeakAcrossLanguages() throws {
        let document = SemanticDocument(blocks: [.init(kind: .paragraph, text: "At 9:05 pm the sample weighed 2.4 kg.", origin: .authored)], extractorVersion: "test")
        var settings = SpeechSettings(model: .qwen3, voice: "Ryan")
        let baseline = try NarrationPlanner.prepare(document, settings: settings)
        XCTAssertTrue(baseline.chunks.map(\.text).joined().contains("2.4 kg"))
        settings.expandSpokenForms = true
        let expanded = try NarrationPlanner.prepare(document, settings: settings)
        XCTAssertTrue(expanded.chunks.map(\.text).joined().contains("kilograms"))
        settings.language = "French"
        XCTAssertTrue(try NarrationPlanner.prepare(document, settings: settings).chunks.map(\.text).joined().contains("2.4 kg"))
    }
    func testDiagnosticsFlagWithoutChangingSamplesAndBoundWordComparison() throws {
        let samples = [Float](repeating: 0, count: 32_001), original = samples
        var diagnostic = try NarrationDiagnostics.inspect(samples: samples, sampleRate: 8_000, text: "An ordinary short sentence is spoken.")
        XCTAssertTrue(diagnostic.flags.contains(.longSilence)); XCTAssertEqual(samples, original)
        try diagnostic.compare(expected: "One two three four", recognized: "One two four")
        XCTAssertEqual(diagnostic.wordErrorRate, 0.25); XCTAssertTrue(diagnostic.flags.contains(.transcriptMismatch))
        try diagnostic.compare(expected: "Café, hello!", recognized: "cafe hello")
        XCTAssertEqual(diagnostic.wordErrorRate, 0); XCTAssertFalse(diagnostic.flags.contains(.transcriptMismatch))
        XCTAssertThrowsError(try diagnostic.compare(expected: String(repeating: "word ", count: 2001), recognized: "word"))
    }
}
