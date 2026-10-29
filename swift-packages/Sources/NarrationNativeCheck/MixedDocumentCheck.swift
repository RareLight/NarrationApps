import Foundation
import CoreGraphics
import CoreText
import Darwin
import NarrationCore
import NativeSpeech
import DocumentProcessing
import ProcessingPipeline
import AudioOutput

/// Opt-in synthetic reproduction of the reported input shape. It never reads
/// private documents, downloads models, invokes the GUI or changes recordings.
enum MixedDocumentCheck {
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 4, args[3] == "mixed" else { throw CocoaError(.fileReadInvalidFileName) }
        let worker = URL(fileURLWithPath: args[0]), workspace = try NativeWorkspace(root: URL(fileURLWithPath: args[1]))
        let output = URL(fileURLWithPath: args[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let stage = try workspace.managed(workspace.nativeRoot.appendingPathComponent("staging/mixed-\(UUID())"))
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        let pdf = stage.appendingPathComponent("twelve-pages.pdf"), markdown = stage.appendingPathComponent("six-hundred-words.md")
        try makePDF(at: pdf)
        let sentence = "Readers follow the quiet river and discover stories about local history and everyday life."
        let words = Array(repeating: sentence, count: 50).joined(separator: " ").split(separator: " ").prefix(600)
        try Data(words.joined(separator: " ").utf8).write(to: markdown)
        let inputs = [InputDocument(source: pdf, kind: .pdf, relativePath: pdf.lastPathComponent),
                      InputDocument(source: markdown, kind: .markdown, relativePath: markdown.lastPathComponent)]
        let debug = try DebugLog(workspace: output)
        let debugOffset = (try? Data(contentsOf: debug.url).count) ?? 0
        // Explicit OS sandbox denial is independent of SDK offline flags.
        let denyNetwork = "(version 1)(allow default)(deny network*)"
        var config = WorkerConfiguration(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
            arguments: ["-p", denyNetwork, worker.path, "--serve"])
        guard let policy = SpeechPreparationPolicy(rawValue: ProcessInfo.processInfo.environment["NARRATION_CHECK_POLICY"] ?? SpeechPreparationPolicy.current.rawValue) else { throw SpeechFailure(.invalidInput) }
        config.preparationPolicy = policy
        let coordinator = QueueCoordinator(configuration: config)
        let meter = CoordinatorFootprint()
        let sampling = Task.detached {
            while !Task.isCancelled {
                meter.sample()
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
        }
        defer { sampling.cancel() }
        var records: [[String: Any]] = []
        for model in [SpeechModel.kokoro, .soprano] {
            let names = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, "\(model.rawValue)-\($0.source.deletingPathExtension().lastPathComponent).wav") })
            let planned = try BatchPlanner.plan(inputs, output: output, names: names)
            let request = BatchRequest(documents: planned, outputDirectory: output, workspace: workspace.root,
                settings: .init(model: model), describeImages: false, replaceExisting: true)
            let summary = try await coordinator.run(request, debugLog: debug)
            guard summary.successfulCount == 2, summary.failedCount == 0, !summary.cancelled else {
                throw NSError(domain: "MixedDocumentCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: summary.documents.compactMap(\.message).joined(separator: "; ")])
            }
            for plan in planned {
                let info = try NativeAudio.inspect(plan.destination)
                guard info.sampleRate == model.capabilities.sampleRate else { throw AudioOutputError.inconsistentFormat }
                var nonzero = false
                try NativeAudio.decode(plan.destination) { nonzero = nonzero || $0.contains { abs($0) > 0.0001 } }
                guard nonzero else { throw AudioOutputError.empty }
                records.append(["model": model.rawValue, "file": plan.destination.lastPathComponent,
                    "frames": info.frames, "sampleRate": info.sampleRate, "duration": info.duration])
            }
            print("\(model.rawValue): mixed 12-page PDF and 600-word Markdown passed offline with one resident worker.")
        }
        sampling.cancel(); await sampling.value
        let logBytes = try Data(contentsOf: debug.url)
        let log = String(decoding: logBytes.dropFirst(min(debugOffset, logBytes.count)), as: UTF8.self)
        let regex = try NSRegularExpression(pattern: "peakFootprintBytes=([0-9]+)")
        let helperPeaks = regex.matches(in: log, range: NSRange(log.startIndex..., in: log)).compactMap {
            Range($0.range(at: 1), in: log).flatMap { UInt64(log[$0]) }
        }
        guard meter.peak > 0, helperPeaks.count == 2 else { throw AudioOutputError.encoding }
        let record: [String: Any] = ["version": 1, "pdfPages": 12, "markdownWords": words.count,
            "offline": true, "normalization": false, "volumeLeveling": false, "workers": 1,
            "coordinatorPeakFootprintBytes": meter.peak, "helperPeakFootprintBytes": helperPeaks,
            "results": records]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("mixed-results.json"), options: [.atomic])
        print("Coordinator peak: \(meter.peak) bytes. Helper peaks: \(helperPeaks) bytes.")
    }

    private static func makePDF(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        for page in 1...12 {
            context.beginPDFPage(nil)
            for line in 0..<10 {
                let text = "Page \(page). Readers explore the river, the park, and nearby homes."
                let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 12, nil)])
                context.textPosition = CGPoint(x: 40, y: 740 - line * 24)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }
}

private final class CoordinatorFootprint: @unchecked Sendable {
    private let lock = NSLock()
    private var maximum: UInt64 = 0
    var peak: UInt64 { lock.withLock { maximum } }
    func sample() {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        if result == 0 { lock.withLock { maximum = max(maximum, usage.ri_phys_footprint) } }
    }
}
