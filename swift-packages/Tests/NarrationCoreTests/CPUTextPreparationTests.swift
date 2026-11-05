import Foundation
import XCTest
import Tokenizers
@testable import NarrationCore

final class CPUTextPreparationTests: XCTestCase, @unchecked Sendable {
    private func tokenizer() async throws -> any Tokenizer {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-tokenizer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let symbols = (33...126).compactMap(UnicodeScalar.init).map(String.init) + ["Ġ", "Ċ", "ĉ", "[UNK]"]
        let vocab = Dictionary(uniqueKeysWithValues: symbols.enumerated().map { ($0.element, $0.offset) })
        let config: [String: Any] = ["tokenizer_class": "PreTrainedTokenizerFast", "model_max_length": 1024, "unk_token": "[UNK]"]
        let data: [String: Any] = ["version": "1.0", "added_tokens": [],
            "pre_tokenizer": ["type": "ByteLevel", "add_prefix_space": false, "use_regex": true],
            "decoder": ["type": "ByteLevel", "add_prefix_space": false],
            "model": ["type": "BPE", "vocab": vocab, "merges": [], "unk_token": "[UNK]"]]
        try JSONSerialization.data(withJSONObject: config).write(to: folder.appendingPathComponent("tokenizer_config.json"))
        try JSONSerialization.data(withJSONObject: data).write(to: folder.appendingPathComponent("tokenizer.json"))
        return try await AutoTokenizer.from(modelFolder: folder)
    }
    func testSyntheticTokenizerBaselinePreparation() async throws {
        let tokenizer = try await tokenizer()
        let texts = ["The traveller watched the sunlight cross the old stone bridge.",
            "The traveller walked through the quiet village, passed a small garden, and watched the sunlight cross the old stone bridge while the birds sang in the trees."]
        let repeats = ProcessInfo.processInfo.environment["NARRATION_CPU_PREPARATION_BENCHMARK"] == "1" ? 100 : 1
        var measureSeconds = 0.0, calls = 0
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<repeats {
            for text in texts {
                let slices = try LegacySpeechSegmentation.slices(text, target: 96, maximum: 512) {
                    let before = ProcessInfo.processInfo.systemUptime
                    let count = tokenizer.encode(text: $0).count
                    measureSeconds += ProcessInfo.processInfo.systemUptime - before; calls += 1
                    return count
                }
                XCTAssertEqual(slices.map { String(text[$0.range]) }.joined(), text)
            }
        }
        if repeats > 1 {
            print("CPU_TOKENIZER_BASELINE windows=\(repeats * texts.count) calls=\(calls) totalSeconds=\(ProcessInfo.processInfo.systemUptime - started) tokenizerSeconds=\(measureSeconds)")
        }
    }
    private func signature(_ slices: [SemanticSpeechSegmentation.Slice], in text: String) -> [String] {
        slices.map { "\(NSRange($0.range, in: text)):" + $0.boundary.rawValue }
    }
    func testSerialAndParallelKeepExactOriginalSlicesWithRealBPEAndNonMonotonicCounters() async throws {
        let tokenizer = try await tokenizer()
        let texts = ["A complete short sentence.", "  A sentence. Another one!  ",
            "The traveller walked through the quiet village, passed a small garden, and watched the sunlight cross the old stone bridge while the birds sang in the trees.",
            "日本語の文章です。次の文も保持します。", "中文没有空格，仍然保留每个字符。", "Café naïve — 12:30 p.m.; 👩🏽‍💻!", "alpha beta gamma delta epsilon"]
        for text in texts {
            for workers in [1, 2, 4, 8, 12] {
                for nonMonotonic in [false, true] {
                    let count: @Sendable (String) throws -> Int = { value in
                        nonMonotonic ? (value.hasSuffix("gamma") ? 49 : value.utf16.count) : tokenizer.encode(text: value).count
                    }
                    let expected = try LegacySpeechSegmentation.slices(text, target: 32, maximum: 80, measure: count)
                    let serial = try SemanticSpeechSegmentation.slices(text, target: 32, maximum: 80, measure: count)
                    let parallel = try SemanticSpeechSegmentation.parallelSlices(text, target: 32, maximum: 80, workers: workers, measure: count)
                    let reference = expected.map { "\(NSRange($0.range, in: text)):" + $0.boundary.rawValue }
                    XCTAssertEqual(signature(serial, in: text), reference)
                    XCTAssertEqual(signature(parallel, in: text), reference)
                    XCTAssertEqual(parallel.map { String(text[$0.range]) }.joined(), text)
                }
            }
        }
    }
    func testSpeculativeErrorPastOriginalStopCannotFailValidInput() throws {
        enum Unexpected: Error { case speculative }
        let text = "one two three four five six seven eight nine ten"
        final class Flag: @unchecked Sendable {
            let lock = NSLock(); private var value = false
            func mark() { lock.withLock { value = true } }
            var seen: Bool { lock.withLock { value } }
        }
        let flag = Flag()
        let selected: @Sendable (String) throws -> Int = { value in
            if value == "one two three four" { flag.mark(); throw Unexpected.speculative }
            return value.utf16.count
        }
        let reference = try LegacySpeechSegmentation.slices(text, target: 8, maximum: 20, measure: selected)
        let actual = try SemanticSpeechSegmentation.parallelSlices(text, target: 8, maximum: 20, workers: 12, measure: selected)
        XCTAssertEqual(signature(actual, in: text), reference.map { "\(NSRange($0.range, in: text)):" + $0.boundary.rawValue })
        XCTAssertTrue(flag.seen)
    }
    func testWorkersAreBoundedAndCancellationCheckedAfterJoinedBatch() throws {
        final class Activity: @unchecked Sendable {
            let lock = NSLock(); var active = 0, peak = 0, finished = 0
            func count(_ value: String) -> Int {
                lock.withLock { active += 1; peak = max(peak, active) }
                defer { lock.withLock { active -= 1; finished += 1 } }
                Thread.sleep(forTimeInterval: 0.002)
                return value.utf16.count
            }
        }
        final class Checks: @unchecked Sendable {
            let lock = NSLock(); private var count = 0
            func check() throws { try lock.withLock { count += 1; if count >= 3 { throw CancellationError() } } }
        }
        for workers in [1, 2, 4, 8, 12] {
            let activity = Activity(), checks = Checks()
            XCTAssertThrowsError(try NarrationWorkCheckpoint.$current.withValue({ try checks.check() }) {
                try SemanticSpeechSegmentation.parallelSlices("one two three four five six seven eight nine ten", target: 32, maximum: 80, workers: workers, measure: { activity.count($0) })
            })
            XCTAssertEqual(activity.active, 0); XCTAssertEqual(activity.finished, workers)
            if workers > 1 { XCTAssertGreaterThan(activity.peak, 1) }
            XCTAssertLessThanOrEqual(activity.peak, workers)
        }
        XCTAssertThrowsError(try SemanticSpeechSegmentation.parallelSlices("one", target: 1, maximum: 2, workers: 0, measure: { $0.count }))
    }
    func testSyntheticTokenizerParallelPreparationReportsTiming() async throws {
        guard ProcessInfo.processInfo.environment["NARRATION_CPU_PREPARATION_BENCHMARK"] == "1" else { return }
        let tokenizer = try await tokenizer()
        let texts = ["The traveller watched the sunlight cross the old stone bridge.",
            "The traveller walked through the quiet village, passed a small garden, and watched the sunlight cross the old stone bridge while the birds sang in the trees."]
        for workers in [1, 2, 4, 8, 12] {
            let before = ProcessInfo.processInfo.systemUptime
            for _ in 0..<100 {
                for text in texts {
                    let result = try SemanticSpeechSegmentation.parallelSlices(text, target: 96, maximum: 512, workers: workers) { tokenizer.encode(text: $0).count }
                    XCTAssertEqual(result.map { String(text[$0.range]) }.joined(), text)
                }
            }
            print("CPU_TOKENIZER_PARALLEL windows=200 workers=\(workers) seconds=\(ProcessInfo.processInfo.systemUptime - before)")
        }
    }

}
