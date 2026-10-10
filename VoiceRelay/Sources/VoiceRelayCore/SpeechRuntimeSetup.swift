import Foundation
import Darwin
import VoiceRelayRuntimeResources

public enum SpeechRuntimeSetup {
    public static let sourceNames = ["provider.py", "runtime_setup.py", "selection.json", "requirements.lock", "python-downloads.json"]
    public static var managedRoot: URL { AppStorage.root.appendingPathComponent("SpeechRuntime", isDirectory: true) }
    public static func bundledSources() throws -> [String: URL] {
        try Dictionary(uniqueKeysWithValues: sourceNames.map { name in
            guard let file = VoiceRelayRuntimeResources.file(name) else {
                throw RelayError.setup("The app is missing its bundled speech setup files. Rebuild or reinstall VoiceRelay.")
            }
            return (name, file)
        })
    }
    /// Preserve explicit/legacy installations; new users need no checkout path.
    public static func preferredRoot(saved: URL?, legacy: URL) -> URL {
        if let saved { return saved }
        if FileManager.default.fileExists(atPath: legacy.appendingPathComponent("runtime/kokoro/provider.py").path) { return legacy }
        return managedRoot
    }
    public static func prerequisites(locate: (String) -> URL? = ToolRunner.locate) -> [SetupDiagnostic] {
        ["python3", "uv", "ffmpeg", "ffprobe"].map {
            SetupDiagnostic(id: $0, ready: locate($0) != nil, message: locate($0) == nil ? "\($0) is missing" : "\($0) is available")
        }
    }
    /// Only explicit installation writes these files. Build/readiness checks never download.
    public static func stageSources(at root: URL, sources: [String: URL]? = nil) throws {
        let sources = try sources ?? bundledSources()
        guard root.isFileURL, root.path != "/", !Files.samePath(root, FileManager.default.homeDirectoryForCurrentUser),
              Set(sources.keys) == Set(sourceNames) else { throw RelayError.setup("The speech runtime location or setup files are invalid.") }
        let marker = root.appendingPathComponent(".voicerelay-runtime")
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            let existing = try fm.contentsOfDirectory(atPath: root.path)
            guard existing.isEmpty || (try? String(contentsOf: marker, encoding: .utf8)) == "VoiceRelay managed runtime v1\n" else {
                throw RelayError.setup("The app-managed runtime folder belongs to another installation. It was not changed.")
            }
        }
        let folder = root.appendingPathComponent("runtime/kokoro", isDirectory: true)
        guard !Files.hasSymlink(folder, below: root.deletingLastPathComponent()) else {
            throw RelayError.setup("The managed runtime contains an unexpected link.")
        }
        try Files.directory(folder)
        try Files.write(Data("VoiceRelay managed runtime v1\n".utf8), to: marker)
        for name in sourceNames {
            try Task.checkCancellation()
            let file = sources[name]!
            let bytes = try Data(contentsOf: file)
            guard bytes.count <= 2_000_000 else { throw RelayError.setup("A bundled runtime setup file exceeds its size limit.") }
            try Files.write(bytes, to: folder.appendingPathComponent(name))
        }
    }
    public static func check(at root: URL) throws {
        guard ToolRunner.locate("ffmpeg") != nil, ToolRunner.locate("ffprobe") != nil else {
            throw RelayError.setup("Audio tools are missing. Install ffmpeg and ffprobe before generating speech.")
        }
        let python = root.appendingPathComponent(".runtime/kokoro/.venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw RelayError.setup("Speech runtime is not installed. Choose Install Speech Runtime in General settings.")
        }
        try run(python: python, root: root, arguments: ["check"], timeout: 180)
    }
    public static func install(at root: URL = managedRoot, sources: [String: URL]? = nil) throws {
        let missing = prerequisites().filter { !$0.ready }.map(\.id)
        guard missing.isEmpty, let python = ToolRunner.locate("python3") else {
            throw RelayError.setup("Install these setup tools first: \(missing.joined(separator: ", ")). See the setup guide.")
        }
        try stageSources(at: root, sources: sources)
        try run(python: python, root: root, arguments: ["setup", "--download"], timeout: 5_400)
        try check(at: root)
    }
    /// The Python entrypoint isolates its process group before spawning setup children.
    static func run(python: URL, root: URL, arguments: [String], timeout: TimeInterval) throws {
        let script = root.appendingPathComponent("runtime/kokoro/runtime_setup.py")
        guard Files.contains(root, script), !Files.hasSymlink(script, below: root),
              FileManager.default.fileExists(atPath: script.path) else {
            throw RelayError.setup("Speech setup files are missing from this runtime installation.")
        }
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = python
        process.arguments = ["-I", "-B", script.path] + arguments + ["--app-managed"]
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("UV_") || key.hasPrefix("PIP_") || ["PYTHONHOME", "PYTHONPATH", "VIRTUAL_ENV"].contains(key) {
            environment.removeValue(forKey: key)
        }
        environment["PATH"] = [environment["PATH"] ?? "", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { throw RelayError.setup("Speech setup could not start. Check the required setup tools.") }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var grouped = false
        func stop() {
            let pid = process.processIdentifier
            let isolated = grouped || getpgid(pid) == pid
            if isolated { kill(-pid, SIGTERM) } else if process.isRunning { kill(pid, SIGTERM) }
            let until = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < until { _ = finished.wait(timeout: .now() + 0.01) }
            if isolated { kill(-pid, SIGKILL) } else if process.isRunning { kill(pid, SIGKILL) }
            while process.isRunning { _ = finished.wait(timeout: .now() + 0.01) }
        }
        while process.isRunning {
            grouped = grouped || getpgid(process.processIdentifier) == process.processIdentifier
            if Task.isCancelled { stop(); throw CancellationError() }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                stop(); throw RelayError.setup("Speech setup exceeded its deadline. Retry explicit installation when ready.")
            }
            _ = finished.wait(timeout: .now() + 0.02)
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            throw RelayError.setup("Speech setup or verification failed. Check network access, free space and the setup guide, then retry.")
        }
    }
}
