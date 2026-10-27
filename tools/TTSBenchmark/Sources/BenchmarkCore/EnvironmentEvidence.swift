import Foundation
import Darwin

public struct EnvironmentEvidence: Codable, Sendable {
    public var os = ProcessInfo.processInfo.operatingSystemVersionString
    public var physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
    public var cpuCount = ProcessInfo.processInfo.processorCount
    public var cpu: String
    public var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    public var thermalState = ProcessInfo.processInfo.thermalState.rawValue
    public var workerHash: String
    public var productWorkerHash: String
    public var mlxAudioBase = Catalog.codePin
    public var measurementBoundary = "Model call through materialized PCM; request through WAV write; first nonempty PCM event; no postprocessing gain. Seeded single session order; not counterbalanced. Physical footprint sampling 20 ms."
    public var coverage = "Numerical/audio validity only. Reading fidelity and naturalness require operator listening; optional ASR not run automatically."
    public init(workerHash: String, productWorkerHash: String) {
        self.workerHash = workerHash; self.productWorkerHash = productWorkerHash
        var length = 0
        if sysctlbyname("machdep.cpu.brand_string", nil, &length, nil, 0) == 0, length > 0 {
            var bytes = [CChar](repeating: 0, count: length)
            if sysctlbyname("machdep.cpu.brand_string", &bytes, &length, nil, 0) == 0 { cpu = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
            else { cpu = "unavailable" }
        } else { cpu = "unavailable" }
    }
}
