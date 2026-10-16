import Foundation
import Darwin
import NarrationCore
import NativeSpeech
import ProcessingPipeline
import AudioOutput

/// Exercises the two packaged helpers without launching either GUI or touching
/// production queues. Uses the real shared admission lock and synthetic prose.
enum ContentionCheck {
    private final class Measurements: @unchecked Sendable {
        let lock = NSLock()
        var order: [String] = []
        var waitingPeak: UInt64 = 0
        func finish(_ name: String) { lock.withLock { order.append(name) } }
        func sample(pid: Int32) {
            var usage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &usage) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
            if status == 0 { lock.withLock { waitingPeak = max(waitingPeak, usage.ri_phys_footprint) } }
        }
    }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 5 else { throw SpeechFailure(.invalidInput) }
        let workspace = try NativeWorkspace(root: URL(fileURLWithPath: args[1]))
        let output = URL(fileURLWithPath: args[2]); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let debug = try DebugLog(workspace: output)
        let offset = (try? Data(contentsOf: debug.url).count) ?? 0
        func configuration(_ path: String, priority: InferencePriority) -> WorkerConfiguration {
            WorkerConfiguration(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                arguments: ["-p", "(version 1)(allow default)(deny network*)", URL(fileURLWithPath: path).standardizedFileURL.path, "--serve"], debugLog: debug, inferencePriority: priority)
        }
        let policy = SpeechPreparationPolicy.longformPausesCandidate
        let settings = SpeechSettings(speed: 1)
        let projection = try NarrationPlanner.prepareForSpeech(.init(blocks: [.init(kind: .paragraph,
            text: "Readers follow the river, consider the next sentence, and continue toward the final page.")], extractorVersion: "contention-1"), settings: settings, policy: policy)
        let background = try NativeSpeechSession(configuration: configuration(args[4], priority: .background), workspace: workspace.root, settings: settings, policy: policy)
        let foreground = try NativeSpeechSession(configuration: configuration(args[0], priority: .interactive), workspace: workspace.root, settings: settings, policy: policy)
        do {
            try await background.prepare()
            let backgroundPlan = try await background.prepareSpeech(projection)
            let bytes = try Data(contentsOf: debug.url)
            let log = String(decoding: bytes.dropFirst(min(offset, bytes.count)), as: UTF8.self)
            let regex = try NSRegularExpression(pattern: "started pid=([0-9]+)")
            guard let match = regex.firstMatch(in: log, range: NSRange(log.startIndex..., in: log)),
                  let range = Range(match.range(at: 1), in: log), let pid = Int32(log[range]) else { throw SpeechFailure(.protocolViolation) }
            let measurements = Measurements()
            var held: InferenceLease? = try await InferenceLease.acquire(priority: .interactive)
            let backgroundTask = Task {
                try await background.render(plan: backgroundPlan, destination: output.appendingPathComponent("background.wav"), identity: .init(batch: UUID(), job: UUID()))
                measurements.finish("background")
                await background.close()
            }
            let sampling = Task.detached {
                while !Task.isCancelled {
                    measurements.sample(pid: pid)
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                }
            }
            let foregroundTask = Task {
                try await InferenceLease.withPriority(.interactive) {
                    try await foreground.prepare()
                    let plan = try await foreground.prepareSpeech(projection)
                    try await foreground.render(plan: plan, destination: output.appendingPathComponent("foreground.wav"), identity: .init(batch: UUID(), job: UUID()))
                    measurements.finish("foreground")
                    await foreground.close()
                }
            }
            // Both tasks request admission while the controlled gate is held.
            try await Task.sleep(for: .milliseconds(150))
            withExtendedLifetime(held) {}; held = nil
            do { try await foregroundTask.value; try await backgroundTask.value }
            catch { foregroundTask.cancel(); backgroundTask.cancel(); sampling.cancel(); throw error }
            sampling.cancel(); await sampling.value
            guard measurements.order == ["foreground", "background"], measurements.waitingPeak > 0 else { throw SpeechFailure(.protocolViolation) }
            let cancellation = try NativeSpeechSession(configuration: configuration(args[4], priority: .background), workspace: workspace.root, settings: settings, policy: policy)
            try await cancellation.prepare()
            let cancelPlan = try await cancellation.prepareSpeech(projection)
            held = try await InferenceLease.acquire(priority: .interactive)
            let cancelledOutput = output.appendingPathComponent("cancelled.wav")
            let task = Task { try await cancellation.render(plan: cancelPlan, destination: cancelledOutput, identity: .init(batch: UUID(), job: UUID())) }
            try await Task.sleep(for: .milliseconds(100)); task.cancel()
            do { try await task.value; throw SpeechFailure(.protocolViolation) } catch is CancellationError {}
            withExtendedLifetime(held) {}; held = nil
            await cancellation.close()
            guard !FileManager.default.fileExists(atPath: cancelledOutput.path) else { throw SpeechFailure(.storage) }
            for file in ["foreground.wav", "background.wav"] { _ = try NativeAudio.inspect(output.appendingPathComponent(file)) }
            try JSONSerialization.data(withJSONObject: ["version": 1, "offline": true, "completionOrder": measurements.order,
                "residentBackgroundPeakWhileWaitingBytes": measurements.waitingPeak, "waitingCancellationReaped": true,
                "libroWorkerSHA256": try NativeG2P.sha256(URL(fileURLWithPath: args[0])),
                "voiceRelayWorkerSHA256": try NativeG2P.sha256(URL(fileURLWithPath: args[4]))], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("contention.json"), options: .atomic)
            print("Packaged native priority and waiting cancellation passed offline; background resident peak: \(measurements.waitingPeak) bytes.")
        } catch { await background.close(); await foreground.close(); throw error }
    }
}
