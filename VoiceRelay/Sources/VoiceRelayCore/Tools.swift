import Foundation
import Darwin

public enum ToolRunner {
    public static func locate(_ tool: String) -> URL? {
        if tool.contains("/") {
            return FileManager.default.isExecutableFile(atPath: tool) ? URL(fileURLWithPath: tool) : nil
        }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        return paths.map { URL(fileURLWithPath: $0).appendingPathComponent(tool) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func run(_ tool: String, _ arguments: [String], timeout: Int, directory: URL) throws -> Data {
        try Task.checkCancellation()
        guard let executable = locate(tool) else { throw RelayError.setup("Required audio tool is unavailable to this process.") }
        let output = directory.appendingPathComponent(".tool-\(UUID().uuidString).log")
        try Data().write(to: output, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = handle; process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { throw RelayError.tool("Audio tool could not start.") }
        func stop() {
            if process.isRunning { process.terminate() }
            let deadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < deadline { _ = finished.wait(timeout: .now() + 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            while process.isRunning { _ = finished.wait(timeout: .now() + 0.01) }
        }
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while process.isRunning {
            if Task.isCancelled { stop(); throw CancellationError() }
            if Date() >= deadline { stop(); throw RelayError.tool("Audio tool exceeded its configured deadline.") }
            _ = finished.wait(timeout: .now() + 0.02)
        }
        guard process.terminationStatus == 0 else { throw RelayError.tool("Audio tool failed. Private artifacts are retained for inspection.") }
        let size = (try output.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard size <= 4_194_304 else { throw RelayError.tool("Audio tool output exceeded the inspection limit.") }
        return try Data(contentsOf: output)
    }
}
