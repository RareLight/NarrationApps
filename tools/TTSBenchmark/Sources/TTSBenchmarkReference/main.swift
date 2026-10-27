import Foundation
import BenchmarkCore
import NarrationCore
import NativeSpeech
import ProcessingPipeline
import AudioOutput
import Darwin

@main struct ReferenceWorker {
    static func main() async {
        let control = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        func emit(_ event: BenchmarkCore.WorkerEvent) throws { try control.write(contentsOf: JSONEncoder().encode(event) + Data([10])) }
        do {
            if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--prepare" {
                let root = URL(fileURLWithPath: CommandLine.arguments[2]), worker = URL(fileURLWithPath: CommandLine.arguments[3])
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                for settings in [SpeechSettings(voice: "af_heart"), SpeechSettings(voice: "bf_emma"), SpeechSettings(model: .soprano, voice: "soprano")] {
                    try await ModelPreparation.run(configuration: WorkerConfiguration(executable: worker, requestTimeout: .seconds(1800)), workspace: root, settings: settings)
                }
                try emit(.init("finished")); return
            }
            guard CommandLine.arguments.count == 2 else { throw BenchError("Reference worker needs a job") }
            let job = try Files.read(WorkerJob.self, URL(fileURLWithPath: CommandLine.arguments[1]))
            guard let worker = job.productWorker, let model = SpeechModel(rawValue: job.profile.family),
                  job.profile.productReference else { throw BenchError("Product worker, prepared workspace and reference profile required") }
            let identity = AttemptIdentity(batch: UUID(), job: UUID())
            let settings = SpeechSettings(model: model, voice: job.profile.voice ?? "af_heart", speed: 1)
            let session = try NativeSpeechSession(configuration: WorkerConfiguration(executable: URL(fileURLWithPath: worker)),
                workspace: URL(fileURLWithPath: job.workspace), settings: settings, identity: identity)
            let loadStart = ContinuousClock.now
            do {
                try await session.prepare()
                try emit(.init("loaded", seconds: Runtime.seconds(since: loadStart)))
                var first = true
                for passage in job.matrix.passages { for repetition in 0...job.matrix.repetitions {
                    let start = ContinuousClock.now
                    let document = SemanticDocument(title: passage.id, blocks: [.init(kind: .paragraph, text: passage.text)], extractorVersion: "benchmark-original-1")
                    let projected = try NarrationPlanner.prepareForSpeech(document, settings: settings)
                    let prepared = try await session.prepareSpeech(projected)
                    try Files.write(prepared, URL(fileURLWithPath: job.output).appendingPathComponent("\(passage.id)-\(repetition)-prepared.json"))
                    let renderStart = ContinuousClock.now
                    let state = repetition == 0 ? (first ? "cold" : "warmup") : "warm"
                    let name = "\(passage.id)-\(state)-\(repetition).wav"
                    let url = URL(fileURLWithPath: job.output).appendingPathComponent(name)
                    try await session.render(plan: prepared, destination: url, identity: identity)
                    let elapsed = Runtime.seconds(since: renderStart), info = try Wave.inspect(url)
                    first = false
                    let m = Measurement(profile: job.profile.id, passage: passage.id, repetition: repetition,
                        state: state, seconds: elapsed, requestSeconds: Runtime.seconds(since: start),
                        firstPCMSeconds: nil, admissionSeconds: 0, duration: info.duration, frames: info.frames,
                        sampleRate: info.rate, chunks: [passage.text], wav: name,
                        sha256: try Files.hash(url), peakAmplitude: info.peak, clippedSamples: info.clipped,
                        generationParameters: "Accepted product reference; IPC/assembly/WAV included; request includes frontend; admission is not isolated in reference API; speed=1; prepared utterances=\(prepared.utterances.count), full plan recorded separately")
                    try emit(.init("measurement", measurement: m))
                } }
                await session.close(); try emit(.init("finished"))
            } catch { await session.close(); throw error }
        } catch { try? emit(.init("failure", message: "\(error)")); exit(1) }
    }
}
