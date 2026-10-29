import Foundation
import CoreGraphics
import CoreText
import NarrationCore
import DocumentProcessing
import NativeSpeech
import AudioOutput
import ProcessingPipeline

enum PDFWordJoinCheck {
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 4, args[3] == "pdf-word-joins" else { throw SpeechFailure(.invalidInput) }
        let workspace = try NativeWorkspace(root: URL(fileURLWithPath: args[1]))
        let output = URL(fileURLWithPath: args[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let pdf = output.appendingPathComponent("printed-wraps-\(UUID()).pdf")
        let lines = ["There is a particu-", "larly comfortable hotel in this town.",
                     "Readers describe an extraor-", "dinary arrival near the river."]
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: pdf as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw DocumentReadError.malformed }
        context.beginPDFPage(nil)
        for (index, line) in lines.enumerated() {
            let string = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 12, nil)])
            context.textPosition = CGPoint(x: 50, y: 700 - index * 18)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        context.endPDFPage(); context.closePDF()
        let document = try await DocumentReader.readSemantic(.init(source: pdf, kind: .pdf, relativePath: pdf.lastPathComponent))
        let original = document
        let expected = "There is a particularly comfortable hotel in this town. Readers describe an extraordinary arrival near the river."
        var records: [[String: Any]] = []
        for model in [SpeechModel.kokoro, .soprano] {
            let settings = SpeechSettings(model: model)
            let configuration = WorkerConfiguration(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                arguments: ["-p", "(version 1)(allow default)(deny network*)",
                    URL(fileURLWithPath: args[0]).standardizedFileURL.path, "--serve"])
            let session = try NativeSpeechSession(configuration: configuration, workspace: workspace.root, settings: settings)
            do {
                let projection = try NarrationPlanner.prepareForSpeech(document, settings: settings,
                    options: .init(experimentalPDFWordJoining: true))
                guard projection.chunks.map(\.text).joined(separator: " ") == expected,
                      projection.chunks.flatMap({ $0.sourceMappings ?? [] }).filter({ $0.rule == "pdf-word-wrap-readium-1" }).count == 2,
                      document == original else { throw SpeechFailure(.protocolViolation) }
                let reference = try NarrationPlanner.prepareForSpeech(
                    .init(blocks: [.init(kind: .paragraph, text: expected, origin: .authored)], extractorVersion: "independent-pdf-join-control-1"),
                    settings: settings)
                try await session.prepare()
                let plan = try await session.prepareSpeech(projection)
                let control = try await session.prepareSpeech(reference)
                guard plan.utterances.map(\.text) == control.utterances.map(\.text),
                      plan.utterances.map(\.phonemes) == control.utterances.map(\.phonemes) else {
                    throw SpeechFailure(.protocolViolation)
                }
                let destination = output.appendingPathComponent("\(model.rawValue)-\(UUID()).wav")
                try await session.render(plan: plan, destination: destination, identity: .init(batch: UUID(), job: UUID()))
                let info = try NativeAudio.inspect(destination)
                var audible = false
                try NativeAudio.decode(destination) { samples in
                    guard samples.allSatisfy(\.isFinite) else { throw AudioOutputError.invalidPCM }
                    audible = audible || samples.contains { abs($0) > 0.0001 }
                }
                guard audible, info.frames > 0, info.sampleRate == model.capabilities.sampleRate else {
                    throw AudioOutputError.inconsistentFormat
                }
                records.append(["model": model.rawValue, "spoken": expected, "sourcePreserved": true,
                    "mappedCuts": 2, "independentPreparationEqual": true, "offline": true,
                    "frames": info.frames, "sampleRate": info.sampleRate, "file": destination.lastPathComponent])
                await session.close()
            } catch { await session.close(); throw error }
        }
        try JSONSerialization.data(withJSONObject: ["version": 1, "experimental": true, "results": records],
            options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("pdf-word-joins.json"), options: .atomic)
        print("Experimental PDF joins: both native engines match independent preparation, preserve sources and decode offline.")
    }
}
