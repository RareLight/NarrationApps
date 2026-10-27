import XCTest
import Foundation
import Darwin
@testable import BenchmarkCore

final class BenchmarkTests: XCTestCase {
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tts-bench-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func entrants(_ n: Int) -> [Entrant] {
        (0..<n).map { Entrant(id: "e\($0)", label: "Model \($0)", identity: "identity-\($0)", clips: [:], hashes: [:]) }
    }
    func testCatalogAndInputBounds() throws {
        let matrix = Catalog.matrix(); try matrix.validate()
        XCTAssertEqual(matrix.profiles.count, 13)
        var bad = matrix; bad.repetitions = 0; XCTAssertThrowsError(try bad.validate())
        bad = matrix; bad.profiles.append(matrix.profiles[0]); XCTAssertThrowsError(try bad.validate())
        bad = matrix; bad.timeoutSeconds = .infinity; XCTAssertThrowsError(try bad.validate())
        bad = matrix; bad.profiles[0].referenceAudio = "private.wav"; XCTAssertThrowsError(try bad.validate())
        let emma = try XCTUnwrap(matrix.profiles.firstIndex { $0.id == "kokoro-emma" })
        XCTAssertEqual(matrix.profiles[emma].language, "en-gb")
        bad = matrix; bad.profiles[emma].language = "en"; XCTAssertThrowsError(try bad.validate())
        bad = matrix; bad.profiles[0].language = "en-gb"; XCTAssertThrowsError(try bad.validate())
    }
    func testGenerationStatisticsDoNotConfuseAudioFramesAndTokens() throws {
        XCTAssertNil(GenerationEvidence.tokenCount(family: "chatterbox_turbo", info: 240960, events: 0))
        XCTAssertEqual(GenerationEvidence.tokenCount(family: "qwen3_tts", info: 248, events: 0), 248)
        XCTAssertNil(GenerationEvidence.tokenCount(family: "unverified", info: 100000, events: 0))
        XCTAssertThrowsError(try GenerationEvidence.verifyCeiling(family: "qwen3_tts", count: 4096, maximum: 4096))
        XCTAssertNoThrow(try GenerationEvidence.verifyCeiling(family: "chatterbox_turbo", count: nil, maximum: 4096))
        XCTAssertNoThrow(try GenerationEvidence.verifyCeiling(family: "fish_qwen3_omni", count: 6000, maximum: 4096))
    }
    func testSourceCoverageAndWordBoundaries() throws {
        for limit in 20...70 {
            let text = "An unexpected question. How should we answer it?\n\nWith care; and without losing any source text."
            let chunks = try TextChunks.make(text, limit: limit)
            XCTAssertEqual(chunks.joined(), text); XCTAssertTrue(chunks.allSatisfy { $0.count <= limit })
        }
        XCTAssertThrowsError(try TextChunks.make(String(repeating: "x", count: 50), limit: 20))
        let decimal = try TextChunks.make("Value 12345.6789 remains intact.", limit: 15)
        XCTAssertTrue(decimal.contains { $0.contains("12345.6789") })
    }
    func testPathsAndSymlinks() throws {
        let root = try temporary(), outside = try temporary()
        XCTAssertThrowsError(try Files.child(root, "../private"))
        XCTAssertThrowsError(try Files.child(root, "/absolute"))
        XCTAssertThrowsError(try Files.child(root, "a//b"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertThrowsError(try Files.child(root, "link/file"))
        XCTAssertNoThrow(try Files.child(root, "good/file"))
    }
    func testAudioPreservesFloatBitsAndRejectsInvalidOutput() throws {
        let root = try temporary(), file = root.appendingPathComponent("sample.wav")
        let values: [Float] = [0, -0.0, .leastNonzeroMagnitude, 0.1, -0.9, 1.2]
        let info = try Wave.write(values, rate: 24000, to: file)
        XCTAssertEqual(info.frames, values.count); XCTAssertEqual(info.clipped, 1)
        let data = try Data(contentsOf: file)
        for (i, f) in values.enumerated() {
            let offset = 44 + i * 4
            let bits = data[offset..<offset + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
            XCTAssertEqual(bits, f.bitPattern)
        }
        XCTAssertEqual(try Wave.inspect(file).frames, values.count)
        XCTAssertThrowsError(try Wave.write(values, rate: 24000, to: file))
        XCTAssertThrowsError(try Wave.inspectSamples([.nan], rate: 24000))
        XCTAssertThrowsError(try Wave.inspectSamples([0, 0], rate: 24000))
        XCTAssertThrowsError(try Wave.inspectSamples([], rate: 24000))
    }
    func testBracketCompletesForOddAndEvenFields() throws {
        for n in 2...17 {
            var bracket = try Bracket(entrants: entrants(n), seed: 42)
            var count = 0
            while let match = try bracket.view().pending {
                try bracket.answer(match: match.id, choice: count % 2 == 0 ? "a" : "b"); count += 1
                XCTAssertLessThan(count, 2 * n + 1)
            }
            let view = try bracket.view()
            XCTAssertNotNil(view.champion); XCTAssertNotNil(view.runnerUp)
            XCTAssertEqual(view.losses[view.runnerUp!], 2)
            XCTAssertEqual(Set(view.eliminated).count, n - 1)
            XCTAssertEqual(try bracket.shortlist().count, min(n, 4))
            for id in view.eliminated { XCTAssertEqual(view.losses[id], 2) }
        }
    }
    func testGrandFinalResetAndByes() throws {
        var bracket = try Bracket(entrants: entrants(3), seed: 3)
        while let match = try bracket.view().pending {
            if match.stage == "grand-final" { try bracket.answer(match: match.id, choice: "b") }
            else if match.stage == "final-reset" { break }
            else { try bracket.answer(match: match.id, choice: "a") }
        }
        let before = try bracket.view(); XCTAssertEqual(before.pending?.stage, "final-reset")
        XCTAssertFalse(before.byes.isEmpty)
        try bracket.answer(match: before.pending!.id, choice: "a")
        XCTAssertNotNil(try bracket.view().champion)
    }
    func testTieDeferRejectAndRevisionHistory() throws {
        var bracket = try Bracket(entrants: entrants(4), seed: 9)
        let first = try bracket.view().pending!
        try bracket.answer(match: first.id, choice: "tie")
        XCTAssertEqual(try bracket.view().pending?.passageOffset, 1)
        try bracket.answer(match: first.id, choice: "defer")
        XCTAssertEqual(try bracket.view().pending?.id, first.id)
        try bracket.answer(match: first.id, choice: "a")
        let second = try bracket.view().pending!
        try bracket.answer(match: second.id, choice: "b")
        try bracket.answer(match: first.id, choice: "b", revise: true)
        XCTAssertEqual(try bracket.view().pending?.id, second.id)
        XCTAssertFalse(bracket.decisions.contains { $0.match == second.id })
        XCTAssertTrue(bracket.history.contains { $0.choice == "revision" })
        XCTAssertTrue(bracket.history.contains { $0.match == second.id })
        try bracket.answer(match: second.id, choice: "neither")
        XCTAssertEqual(try bracket.view().rejected.count, 2)
        let encoded = try Files.encoder.encode(bracket)
        let decoded = try JSONDecoder().decode(Bracket.self, from: encoded)
        XCTAssertEqual(try decoded.view().pending, try bracket.view().pending)
    }
    func testDuplicateListeningIdentitiesRejected() throws {
        var entries = entrants(2); entries[1].identity = entries[0].identity
        XCTAssertThrowsError(try Bracket(entrants: entries, seed: 0))
    }
    func testRetainingOneContenderDoesNotSelectTheEntireField() throws {
        var b = try Bracket(entrants: entrants(8), seed: 19)
        while let match = try b.view().pending { try b.answer(match: match.id, choice: "a") }
        let automatic = try b.shortlist()
        b.retained = [b.entrants.first { !automatic.contains($0.id) }!.id]
        XCTAssertEqual(try b.shortlist().count, 5)
    }
    func testLongformIsCoherentSizedAndHeldOut() {
        XCTAssertGreaterThan(Longform.passage.text.split(whereSeparator: \.isWhitespace).count, 3500)
        XCTAssertEqual(Longform.passage.role, "longform")
        XCTAssertFalse(Catalog.passages.contains { $0.text == Longform.passage.text })
    }
    func testAssetVerificationRejectsChangedAndUnexpectedWeights() throws {
        let root = try temporary(), dir = try Assets.directory(root, repository: "fixture/model-0.6B")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let weight = dir.appendingPathComponent("model.safetensors")
        try Data([1, 2, 3]).write(to: weight)
        let file = AssetFile(path: "model.safetensors", bytes: 3, sha256: try Files.hash(weight))
        let snapshot = Snapshot(repository: "fixture/model-0.6B", revision: String(repeating: "a", count: 40), files: [file])
        try Files.write(snapshot, dir.appendingPathComponent("benchmark-assets.json"))
        XCTAssertNoThrow(try Assets.verify(dir))
        let extra = dir.appendingPathComponent("extra.safetensors")
        try Data([0]).write(to: extra)
        XCTAssertThrowsError(try Assets.verify(dir))
        try FileManager.default.removeItem(at: extra)
        try Data([3, 2, 1]).write(to: weight)
        XCTAssertThrowsError(try Assets.verify(dir))
    }
    func testReportsAndEscaping() throws {
        XCTAssertEqual(Reports.median([4, 2, 1, 3]), 2.5)
        XCTAssertNil(Reports.median([]))
        XCTAssertFalse(Reports.escape("<script>\"&").contains("<script>"))
        let root = try temporary(), matrix = Catalog.matrix()
        try Reports.summary(root: root, matrix: matrix, attempts: [])
        let text = try String(contentsOf: root.appendingPathComponent("summary.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("not-run")); XCTAssertTrue(text.contains("preferences are not inferred"))
        var finalist = Matrix(profiles: [matrix.profiles[0]], passages: [Passage(id: "long", role: "longform", text: String(repeating: "x", count: 5000))])
        var attempt = Attempt(id: "timing", identity: "timing", profile: matrix.profiles[0], outcome: "completed")
        attempt.measurements = [Measurement(profile: matrix.profiles[0].id, passage: "short", repetition: 1, state: "warm", seconds: 1.5, requestSeconds: 2,
            firstPCMSeconds: nil, admissionSeconds: 0, duration: 1, frames: 24000, sampleRate: 24000, chunks: ["ab"], wav: "sample.wav", sha256: String(repeating: "a", count: 64), peakAmplitude: 0.1, clippedSamples: 0, generationParameters: "fixture")]
        XCTAssertEqual(try Reports.finalistTimeout(matrix: finalist, attempts: []), 7200)
        XCTAssertEqual(try Reports.finalistTimeout(matrix: finalist, attempts: [attempt]), 30000)
        finalist.passages = [Passage(id: "long", role: "longform", text: String(repeating: "x", count: 100000))]
        XCTAssertThrowsError(try Reports.finalistTimeout(matrix: finalist, attempts: [attempt]))
    }
    func testListeningExcludesColdAndProductDuplicates() throws {
        let root = try temporary(), p = Catalog.matrix().profiles[0]
        let matrix = Matrix(profiles: [p], passages: [Catalog.passages[0]])
        let dir = root.appendingPathComponent("attempts/one")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("warm.wav"), info = try Wave.write([0.1, -0.1], rate: 24000, to: wav)
        var attempt = Attempt(id: "one", identity: "one", profile: p, outcome: "completed")
        let m = Measurement(profile: p.id, passage: matrix.passages[0].id, repetition: 1, state: "warm", seconds: 0.1,
            requestSeconds: 0.1, firstPCMSeconds: nil, admissionSeconds: 0, duration: info.duration,
            frames: info.frames, sampleRate: info.rate, chunks: [matrix.passages[0].text], wav: "warm.wav",
            sha256: try Files.hash(wav), peakAmplitude: info.peak, clippedSamples: 0, generationParameters: "fixture")
        attempt.measurements = [m]
        XCTAssertEqual(try Reports.entrants(root: root, matrix: matrix, attempts: [attempt]).count, 1)
        attempt.measurements[0].state = "cold"
        XCTAssertTrue(try Reports.entrants(root: root, matrix: matrix, attempts: [attempt]).isEmpty)
        var product = p; product.id += "-reference"; product.productReference = true
        XCTAssertTrue(try Reports.entrants(root: root, matrix: Matrix(profiles: [product], passages: matrix.passages), attempts: [attempt]).isEmpty)
    }
    func testBlindPackUsesHeldoutAndHidesIdentity() throws {
        let root = try temporary(), passages = [Catalog.passages[0], Catalog.passages[2]]
        let source = root.appendingPathComponent("source.wav")
        _ = try Wave.write([0.1, -0.1], rate: 24000, to: source)
        let hash = try Files.hash(source)
        let entries = (0..<3).map { i in Entrant(id: "secret-id-\(i)", label: "Secret Voice \(i)", identity: "private-\(i)", clips: Dictionary(uniqueKeysWithValues: passages.map { ($0.id, "source.wav") }), hashes: Dictionary(uniqueKeysWithValues: passages.map { ($0.id, hash) })) }
        var bracket = try Bracket(entrants: entries, seed: 5)
        let matrix = Matrix(profiles: [Catalog.matrix().profiles[0]], passages: passages)
        XCTAssertThrowsError(try Reports.blindPack(bracket, matrix: matrix, root: root))
        while let pending = try bracket.view().pending { try bracket.answer(match: pending.id, choice: "a") }
        try Reports.blindPack(bracket, matrix: matrix, root: root)
        let html = try String(contentsOf: root.appendingPathComponent("blind/index.html"), encoding: .utf8)
        XCTAssertFalse(html.contains("secret-id")); XCTAssertFalse(html.contains("Secret Voice"))
        XCTAssertFalse(html.contains(Catalog.passages[0].text))
        XCTAssertTrue(html.contains(Reports.escape(Catalog.passages[2].text)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("unblind.json").path))
        XCTAssertThrowsError(try Reports.blindPack(bracket, matrix: matrix, root: root))
    }
    func testSupervisorSuccessFailuresAndTimeout() throws {
        guard let path = ProcessInfo.processInfo.environment["TTS_BENCH_FIXTURE_WORKER"] else { throw XCTSkip("Run scripts/test.sh to build the fixture worker") }
        for mode in ["valid", "crash", "malformed", "unfinished", "timeout", "bad-evidence", "bad-coverage", "memory", "child"] {
            let root = try temporary()
            var matrix = Matrix(profiles: [Catalog.matrix().profiles[0]], passages: [Catalog.passages[0]])
            matrix.repetitions = 1; matrix.timeoutSeconds = ["timeout", "child"].contains(mode) ? 0.3 : 10
            if mode == "memory" { matrix.footprintLimitBytes = 64 * 1024 * 1024 }
            let job = WorkerJob(matrix: matrix, profile: matrix.profiles[0], workspace: root.path, output: root.path, assetDirectory: root.path)
            let attempt = Attempt(id: "test", identity: "test", profile: job.profile, outcome: "running")
            let result = try Supervisor.run(executable: URL(fileURLWithPath: path), job: job, attempt: attempt, directory: root, offline: false, extraArguments: [mode])
            XCTAssertEqual(result.outcome, mode == "valid" ? "completed" : "failed", mode)
            if mode == "timeout" { XCTAssertEqual(result.reason, "timeout"); XCTAssertLessThan(result.processSeconds, 3) }
            if mode == "memory" { XCTAssertEqual(result.reason, "memory-limit") }
            if mode == "child" {
                let pid = Int32(try String(contentsOf: root.appendingPathComponent("grandchild.pid"), encoding: .utf8))!
                let until = Date().addingTimeInterval(2)
                while kill(pid, 0) == 0 && Date() < until { usleep(20_000) }
                XCTAssertEqual(kill(pid, 0), -1)
            }
        }
    }
    func testCancellationProducesTerminalRecordAndJoinsWorker() throws {
        guard let path = ProcessInfo.processInfo.environment["TTS_BENCH_FIXTURE_WORKER"] else { throw XCTSkip("Run scripts/test.sh") }
        let root = try temporary(), matrix = Matrix(profiles: [Catalog.matrix().profiles[0]], passages: [Catalog.passages[0]])
        let job = WorkerJob(matrix: matrix, profile: matrix.profiles[0], workspace: root.path, output: root.path, assetDirectory: root.path)
        Runtime.requestCancellation(); defer { Runtime.clearCancellation() }
        let result = try Supervisor.run(executable: URL(fileURLWithPath: path), job: job, attempt: Attempt(id: "cancel", identity: "cancel", profile: job.profile, outcome: "running"), directory: root, offline: false, extraArguments: ["timeout"])
        XCTAssertEqual(result.outcome, "cancelled"); XCTAssertEqual(result.reason, "cancelled")
        XCTAssertLessThan(result.processSeconds, 3)
    }
    func testCombinedEvidencePreservesFailedConfigurationsAndRejectsSuccessfulDuplicates() throws {
        let root = try temporary(), first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        let profile = Catalog.matrix().profiles[0]
        var failedProfile = profile; failedProfile.language = "en-gb"
        let bad = Matrix(profiles: [failedProfile], passages: [Catalog.passages[0]])
        let good = Matrix(profiles: [profile], passages: bad.passages)
        try Files.write(bad, first.appendingPathComponent("matrix.json"))
        try Files.write(good, second.appendingPathComponent("matrix.json"))
        var failed = Attempt(id: "failure", identity: "original-binary", profile: failedProfile, outcome: "failed")
        failed.started = "2026-10-24T01:00:00Z"
        try Files.write(failed, first.appendingPathComponent("attempts/failure/attempt.json"))
        var completed = Attempt(id: "success", identity: "corrected-binary", profile: profile, outcome: "completed")
        completed.started = "2026-10-24T02:00:00Z"
        try Files.write(completed, second.appendingPathComponent("attempts/success/attempt.json"))
        let output = root.appendingPathComponent("comparison")
        try CombinedEvidence.create(sources: [first, second], output: output)
        XCTAssertEqual(try Reports.attempts(output).count, 2)
        XCTAssertEqual(try Files.read(Matrix.self, output.appendingPathComponent("matrix.json")).profiles, [profile])
        XCTAssertEqual(try Files.read(Attempt.self, output.appendingPathComponent("attempts/failure/attempt.json")).profile, failedProfile)
        XCTAssertTrue(try String(contentsOf: output.appendingPathComponent("summary.md"), encoding: .utf8).contains("source run receipts"))
        XCTAssertThrowsError(try CombinedEvidence.create(sources: [second, output], output: root.appendingPathComponent("duplicate")))
        var changed = good; changed.seed += 1
        try Files.write(changed, second.appendingPathComponent("matrix.json"))
        XCTAssertThrowsError(try CombinedEvidence.create(sources: [first, second], output: root.appendingPathComponent("incompatible")))
        XCTAssertEqual(try Reports.attempts(first).count, 1)
    }
    func testCLIResumeAndExecutableIdentityAreImmutable() throws {
        guard let workerPath = ProcessInfo.processInfo.environment["TTS_BENCH_FIXTURE_WORKER"] else { throw XCTSkip("Run scripts/test.sh") }
        let probe = Process(); probe.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        probe.arguments = ["-p", "(version 1)(allow default)(deny network*)", "/usr/bin/true"]
        probe.standardError = FileHandle.nullDevice; try probe.run(); probe.waitUntilExit()
        guard probe.terminationStatus == 0 else { throw XCTSkip("Nested OS sandbox unavailable; run the model-free fixture tier outside the outer agent sandbox") }
        let root = try temporary(), workspace = root.appendingPathComponent("workspace"), output = root.appendingPathComponent("run")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let worker = bin.appendingPathComponent("fixture")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: workerPath), to: worker)
        try Files.write(["fixture": true], bin.appendingPathComponent("benchmark-build.json"))
        let assets = try Assets.directory(workspace, repository: "fixture/model")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let weights = assets.appendingPathComponent("model.safetensors")
        try Data([1, 2, 3]).write(to: weights)
        let revision = String(repeating: "a", count: 40)
        try Files.write(Snapshot(repository: "fixture/model", revision: revision,
            files: [AssetFile(path: "model.safetensors", bytes: 3, sha256: try Files.hash(weights))]), assets.appendingPathComponent("benchmark-assets.json"))
        var matrix = Matrix(profiles: [Profile(id: "fixture-a", label: "Fixture A", family: "fixture", repository: "fixture/model", revision: revision, voice: "a"),
            Profile(id: "fixture-b", label: "Fixture B", family: "fixture", repository: "fixture/model", revision: revision, voice: "b")], passages: [Catalog.passages[0]])
        matrix.repetitions = 1
        let input = root.appendingPathComponent("matrix.json"); try Files.write(matrix, input)
        let cli = URL(fileURLWithPath: workerPath).deletingLastPathComponent().appendingPathComponent("tts-benchmark")
        func invoke(_ args: [String]) throws -> Int32 {
            let p = Process(); p.executableURL = cli; p.arguments = args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit(); return p.terminationStatus
        }
        let args = ["run", input.path, workspace.path, output.path, worker.path]
        XCTAssertEqual(try invoke(args), 0)
        XCTAssertEqual(try Reports.attempts(output).count, 2)
        XCTAssertEqual(try invoke(args), 0)
        XCTAssertEqual(try Reports.attempts(output).count, 2)
        XCTAssertEqual(try invoke(["bracket", output.path]), 0)
        XCTAssertNotNil(try Files.read(Bracket.self, output.appendingPathComponent("bracket.json")).view().pending)
        let inventoryURL = assets.appendingPathComponent("benchmark-assets.json")
        let inventory = try Data(contentsOf: inventoryURL)
        try Data([3, 2, 1]).write(to: weights)
        try Files.write(Snapshot(repository: "fixture/model", revision: revision,
            files: [AssetFile(path: "model.safetensors", bytes: 3, sha256: try Files.hash(weights))]), inventoryURL)
        XCTAssertNotEqual(try invoke(args), 0)
        XCTAssertEqual(try Reports.attempts(output).count, 2)
        try Data([1, 2, 3]).write(to: weights); try inventory.write(to: inventoryURL)
        let edit = try FileHandle(forWritingTo: worker); try edit.seekToEnd(); try edit.write(contentsOf: Data([0])); try edit.close()
        XCTAssertNotEqual(try invoke(args), 0)
        XCTAssertEqual(try Reports.attempts(output).count, 2)
    }
}
