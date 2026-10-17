import Foundation

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Baseline: Codable {
    struct Component: Codable {
        let name: String
        let path: String
        let cloneURL: String
        let branch: String
        let revision: String
    }

    struct Toolchain: Codable {
        let xcodeVersion: String
        let xcodeBuild: String
        let swiftVersion: String
        let swiftBuild: String
        let macOSSDK: String
        let architecture: String
        let deploymentTarget: String
    }

    let schemaVersion: Int
    let baseline: String
    let rootRevisionPolicy: String
    let components: [Component]
    let verifiedToolchain: Toolchain
    let validationRecord: String

    static func load(_ root: URL) throws -> Baseline {
        let value: Baseline
        do {
            value = try JSONDecoder().decode(
                Baseline.self, from: Data(contentsOf: root.appendingPathComponent("DevelopmentBaseline.json")))
        } catch {
            throw ToolError("Cannot decode DevelopmentBaseline.json: \(error)")
        }
        try value.validate()
        return value
    }

    func validate() throws {
        guard schemaVersion == 1, rootRevisionPolicy == "containing-git-commit",
            Set(components.map(\.name)) == ["Libro", "VoiceRelay"], components.count == 2,
            validationRecord == "docs/IMPLEMENTATION_STATUS.md"
        else { throw ToolError("Unsupported baseline schema, component inventory or revision policy.") }
        for component in components {
            guard component.path == component.name,
                component.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
                component.cloneURL.range(
                    of: #"^(git@github\.com:|https://github\.com/)[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$"#,
                    options: .regularExpression) != nil
            else { throw ToolError("Invalid path, full commit ID or GitHub clone URL for \(component.name).") }
        }
        guard verifiedToolchain.architecture == "arm64",
            [
                verifiedToolchain.xcodeVersion, verifiedToolchain.swiftVersion,
                verifiedToolchain.macOSSDK, verifiedToolchain.deploymentTarget,
            ].allSatisfy({
                $0.range(of: #"^\d+\.\d+(\.\d+)?$"#, options: .regularExpression) != nil
            })
        else { throw ToolError("Invalid toolchain versions or architecture in baseline.") }
    }
}

struct Command: Equatable {
    let executable: String
    var arguments: [String] = []
    var directory: URL
    var environment: [String: String] = [:]
}

struct Result {
    let status: Int32
    let output: String
}

typealias Runner = (Command) throws -> Result

func capture(_ command: Command) throws -> Result {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command.executable)
    process.arguments = command.arguments
    process.currentDirectoryURL = command.directory
    process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
}

func git(_ root: URL, _ arguments: [String], runner: Runner = capture) throws -> Result {
    try runner(
        Command(
            executable: "/usr/bin/git", arguments: ["--no-optional-locks", "-C", root.path] + arguments,
            directory: root, environment: ["GIT_TERMINAL_PROMPT": "0"]))
}

struct SourceState: Codable {
    let name: String
    let revision: String?
    let dirty: Bool?
    let baselineAvailable: Bool
    let matchesBaseline: Bool
}

func sourceState(_ root: URL, component: Baseline.Component?, runner: Runner = capture) throws -> SourceState {
    let directory = component.map { root.appendingPathComponent($0.path) } ?? root
    guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) else {
        return SourceState(
            name: component?.name ?? "root", revision: nil, dirty: nil,
            baselineAvailable: false, matchesBaseline: false)
    }
    let head = try git(directory, ["rev-parse", "HEAD"], runner: runner)
    let status = try git(directory, ["status", "--porcelain", "--untracked-files=normal"], runner: runner)
    guard head.status == 0, status.status == 0 else {
        throw ToolError("Cannot inspect Git state for \(directory.lastPathComponent).")
    }
    let revision = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
    let available =
        try component.map {
            try git(directory, ["cat-file", "-e", "\($0.revision)^{commit}"], runner: runner).status == 0
        } ?? true
    return SourceState(
        name: component?.name ?? "root", revision: revision, dirty: !status.output.isEmpty,
        baselineAvailable: available, matchesBaseline: component.map { revision == $0.revision } ?? true)
}

func health(_ root: URL, strict: Bool, runner: Runner = capture) throws -> Bool {
    let baseline = try Baseline.load(root)
    var healthy = true
    let rootState = try sourceState(root, component: nil, runner: runner)
    if let revision = rootState.revision {
        print("root HEAD: \(revision); dirty=\(rootState.dirty == true); dirty work is not a committed composition.")
    } else {
        print("UNAVAILABLE root Git checkout: run this tool from the complete NarrationApps source layout.")
        healthy = false
    }
    for component in baseline.components {
        let state = try sourceState(root, component: component, runner: runner)
        guard let revision = state.revision else {
            print(
                "UNAVAILABLE \(component.name): missing independent checkout. Use setup --clone-apps only with network authorization."
            )
            healthy = false
            continue
        }
        print("\(component.name): \(revision); dirty=\(state.dirty == true); matchesBaseline=\(state.matchesBaseline)")
        if !state.baselineAvailable {
            print("WARNING \(component.name): recorded commit unavailable locally; no fetch attempted.")
        }
        if !state.matchesBaseline || state.dirty == true {
            print(
                "WARNING \(component.name): deliberate development divergence is allowed; preserve edits. --strict-baseline enforces the checkpoint."
            )
        }
        if strict && (!state.baselineAvailable || !state.matchesBaseline || state.dirty == true) { healthy = false }
    }
    for (tool, args) in [
        ("/usr/bin/uname", ["-m"]), ("/usr/bin/xcode-select", ["-p"]),
        ("/usr/bin/xcodebuild", ["-version"]), ("/usr/bin/xcrun", ["swift", "--version"]),
        ("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-version"]),
        ("/usr/bin/xcrun", ["--find", "metal"]),
    ] {
        let result = try runner(Command(executable: tool, arguments: args, directory: root))
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        print("\(URL(fileURLWithPath: tool).lastPathComponent) \(args.joined(separator: " ")): \(text)")
        if result.status != 0 { healthy = false }
        if args == ["-m"] && text != "arm64" {
            healthy = false; print("ERROR Native arm64 execution required; leave Rosetta.")
        }
        if args.contains("--show-sdk-version"),
            text.compare(baseline.verifiedToolchain.deploymentTarget, options: .numeric) == .orderedAscending
        {
            healthy = false;
            print("ERROR Selected SDK is older than deployment target \(baseline.verifiedToolchain.deploymentTarget).")
        }
        if args == ["-version"] && !text.contains(baseline.verifiedToolchain.xcodeBuild) {
            print(
                "WARNING Toolchain differs from tested Xcode \(baseline.verifiedToolchain.xcodeBuild); validate this composition before recording it."
            )
        }
    }
    for tool in [
        "/usr/bin/git", "/usr/bin/plutil", "/usr/bin/codesign", "/usr/bin/shasum", "/usr/bin/sandbox-exec",
        "/usr/bin/make",
    ] {
        if !FileManager.default.isExecutableFile(atPath: tool) {
            healthy = false; print("ERROR Required tool missing: \(tool)")
        }
    }
    for dependency in ["ZIPFoundation", "mlx-audio-swift", "mlx-swift", "mlx-swift-lm", "swift-huggingface"] {
        let path = root.appendingPathComponent("swift-packages/.build/dependencies/\(dependency)/Package.swift")
        if !FileManager.default.fileExists(atPath: path.path) {
            print("UNAVAILABLE \(dependency): run authorized setup --prepare-dependencies. No network attempted.")
            healthy = false
        }
    }
    let codec = root.appendingPathComponent("swift-packages/.build/codecs/lame/lib/libmp3lame.0.dylib")
    if !FileManager.default.fileExists(atPath: codec.path) {
        healthy = false; print("UNAVAILABLE Prepared LAME library; run setup --prepare-dependencies.")
    }
    print(
        "Health checks source/tool presence only; full validates prepared patches. Metal execution is release/native evidence, not inferred from compiler presence. Models are never probed or installed."
    )
    return healthy
}
