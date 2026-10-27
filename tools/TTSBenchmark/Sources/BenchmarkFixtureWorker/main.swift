import Foundation
import BenchmarkCore
import Darwin

let job = try Files.read(WorkerJob.self, URL(fileURLWithPath: CommandLine.arguments[1]))
let mode = CommandLine.arguments.dropFirst(2).first ?? "valid"
if mode == "timeout" { sleep(60); exit(0) }
if mode == "memory" {
    let bytes = [UInt8](repeating: 0xAB, count: 180 * 1024 * 1024)
    _ = withExtendedLifetime(bytes) { sleep(60) }; exit(0)
}
if mode == "child" {
    let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["60"]
    try child.run()
    try Data(String(child.processIdentifier).utf8).write(to: URL(fileURLWithPath: job.output).appendingPathComponent("grandchild.pid"))
    child.waitUntilExit(); exit(0)
}
if mode == "crash" { exit(9) }
if mode == "malformed" { print("not JSON"); exit(0) }
func emit(_ event: WorkerEvent) throws {
    let encoder = JSONEncoder(); let data = try encoder.encode(event)
    try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
}
try emit(WorkerEvent("loaded", seconds: 0.01))
for p in job.matrix.passages { for repeatIndex in 0...job.matrix.repetitions {
    let name = "\(p.id)-\(repeatIndex).wav"
    let url = URL(fileURLWithPath: job.output).appendingPathComponent(name)
    let samples: [Float] = (0..<2400).map { sin(Float($0) * 0.2) * 0.05 }
    let info = try Wave.write(samples, rate: 24000, to: url)
    var m = Measurement(profile: job.profile.id, passage: p.id, repetition: repeatIndex, state: repeatIndex == 0 ? "cold" : "warm",
        seconds: 0.01, requestSeconds: 0.012, firstPCMSeconds: nil, admissionSeconds: 0, duration: info.duration, frames: info.frames, sampleRate: info.rate,
        chunks: [p.text], wav: name, sha256: try Files.hash(url), peakAmplitude: info.peak, clippedSamples: info.clipped, generationParameters: "synthetic fixture; not speech")
    if mode == "bad-evidence" { m.duration = .nan }
    if mode == "bad-coverage" { m.chunks = ["Missing input"] }
    try emit(WorkerEvent("measurement", measurement: m))
} }
if mode != "unfinished" { try emit(WorkerEvent("finished")) }
