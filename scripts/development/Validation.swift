import Foundation

struct Step {
    let name: String
    let kind: String
    let command: Command
}

func validationPlan(_ options: Options, evidence: URL) -> [Step] {
    let root = options.root
    func step(
        _ name: String, _ kind: String, _ executable: String, _ arguments: [String],
        environment: [String: String] = [:]
    ) -> Step {
        Step(
            name: name, kind: kind,
            command: Command(
                executable: executable, arguments: arguments,
                directory: root, environment: environment))
    }
    func shell(_ name: String, _ kind: String, _ script: String) -> Step {
        step(name, kind, "/bin/bash", [script])
    }
    let fixture = root.appendingPathComponent("swift-packages/.build/debug/NarrationFixtureWorker").path
    let environment = [
        "NARRATION_FIXTURE_WORKER": fixture,
        "NARRATION_MP3_LIBRARY": root.appendingPathComponent("swift-packages/.build/codecs/lame/lib/libmp3lame.0.dylib")
            .path,
    ]
    if options.tier == "full" { return [shell("full-fixtures", "tests-and-static", "scripts/check-full.sh")] }
    if options.tier == "quick" {
        var steps = [
            shell("static", "static", "scripts/check-static.sh"),
            shell("tooling", "tests", "scripts/test-development.sh"),
        ]
        if let scope = options.scope {
            let path = [
                "presentation": "swift-packages/AppPresentation", "shared": "swift-packages",
                "libro": "Libro/macos/LibroCore", "voicerelay": "VoiceRelay",
            ][scope]!
            if scope != "presentation" {
                steps.append(
                    step(
                        "fixture-worker", "build", "/usr/bin/swift",
                        [
                            "build", "--package-path", "swift-packages", "--disable-sandbox", "--skip-update",
                            "--force-resolved-versions", "--product", "NarrationFixtureWorker", "--jobs", "4",
                        ]))
            }
            var arguments =
                ["test", "--package-path", path] + (scope == "libro" ? [] : ["--disable-sandbox"]) + [
                    "--skip-update",
                    "--force-resolved-versions", "--no-parallel", "--jobs", "4",
                ]
            if scope == "libro" { arguments += ["--scratch-path", "Libro/macos/.build/CoreTests"] }
            if let filter = options.filter { arguments += ["--filter", filter] }
            steps.append(step("\(scope)-tests", "tests", "/usr/bin/swift", arguments, environment: environment))
        }
        return steps
    }
    if options.tier == "native" {
        guard let workspace = options.workspace, let libro = options.libroWorker,
            let relay = options.voiceRelayWorker
        else { return [] }
        var steps = [
            step(
                "native-harness", "build", "/usr/bin/swift",
                [
                    "build", "--package-path", "swift-packages",
                    "--disable-sandbox", "--skip-update", "--force-resolved-versions", "--product",
                    "NarrationNativeCheck", "--jobs", "4",
                ]),
            step(
                "fixture-worker", "build", "/usr/bin/swift",
                [
                    "build", "--package-path", "swift-packages",
                    "--disable-sandbox", "--skip-update", "--force-resolved-versions", "--product",
                    "NarrationFixtureWorker", "--jobs", "4",
                ]),
            step(
                "safety-fixtures", "tests", "/usr/bin/swift",
                [
                    "test", "--package-path", "swift-packages",
                    "--disable-sandbox", "--skip-update", "--force-resolved-versions", "--no-parallel", "--jobs", "4",
                    "--filter",
                    "SchedulingTests|InferenceLeaseTests|InferencePriorityTests|PreparedSpeechTransferTests",
                ], environment: environment),
        ]
        let harness = root.appendingPathComponent("swift-packages/.build/debug/NarrationNativeCheck").path
        for (name, worker) in [("Libro", libro), ("VoiceRelay", relay)] {
            steps.append(
                step(
                    "\(name)-frontend", "offline-native", harness,
                    [
                        worker, workspace, evidence.appendingPathComponent("\(name)-frontend").path, "frontend",
                        root.appendingPathComponent("swift-packages/Tests/Fixtures/Longform/frontend.json").path,
                    ]))
            steps.append(
                step(
                    "\(name)-mixed", "offline-native", harness,
                    [worker, workspace, evidence.appendingPathComponent("\(name)-mixed").path, "mixed"]))
        }
        steps.append(
            step(
                "contention-cancellation", "offline-native", harness,
                [libro, workspace, evidence.appendingPathComponent("contention").path, "contention", relay]))
        return steps
    }
    let derived = root.appendingPathComponent(".build/WorkspaceDerivedData").path
    let common = [
        "-workspace", "NarrationApps.xcworkspace", "-destination", "platform=macOS,arch=arm64",
        "-derivedDataPath", derived, "-disableAutomaticPackageResolution", "-skipPackageUpdates",
        "-onlyUsePackageVersionsFromResolvedFile", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES",
        "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "CODE_SIGN_ENTITLEMENTS=",
        "PROVISIONING_PROFILE_SPECIFIER=", "-jobs", "4",
    ]
    var steps: [Step] = []
    for configuration in ["Debug", "Release"] {
        steps.append(
            step(
                "workspace-\(configuration)", "build", "/usr/bin/xcodebuild",
                common + ["-scheme", "Build Both Apps", "-configuration", configuration, "build"]))
        for app in ["Libro", "VoiceRelay"] {
            steps.append(
                step(
                    "\(app)-\(configuration)-bundle", "packaging", "/usr/bin/swift",
                    ["scripts/check-bundle.swift", "\(derived)/Build/Products/\(configuration)/\(app).app", app]))
        }
    }
    for app in ["Libro", "VoiceRelay"] {
        let archive = evidence.appendingPathComponent("\(app).xcarchive").path
        steps.append(
            step(
                "\(app)-archive", "archive", "/usr/bin/xcodebuild",
                common + ["-scheme", app, "-configuration", "Release", "-archivePath", archive, "archive"]))
        steps.append(
            step(
                "\(app)-archive-bundle", "packaging", "/usr/bin/swift",
                ["scripts/check-bundle.swift", "\(archive)/Products/Applications/\(app).app", app]))
    }
    return steps
}

struct StepRecord: Codable {
    let name: String
    let kind: String
    let outcome: String
    let exitCode: Int32?
    let log: String?
    let observations: [String]
}

struct ValidationSummary: Encodable {
    let schemaVersion = 2
    let started: Date
    var finished: Date?
    let tier: String
    let scope: String?
    let filter: String?
    let signingClass: String
    let source: [SourceState]
    let toolchain: [String: String]
    let fingerprints: [String: String]
    var outcome = "running"
    var steps: [StepRecord] = []
    var bundles: [String: [String: String]] = [:]
    var bundleSigningClasses: [String: String] = [:]
    let operatorAcceptance = "not-performed"
    let distributionAcceptance = "not-performed"
    let unrequestedGates: [String]
}

func boundedRun(_ command: Command) throws -> Result {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command.executable)
    process.arguments = command.arguments
    process.currentDirectoryURL = command.directory
    var environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
    for name in [
        "NARRATION_PRONUNCIATION_NATIVE", "VOICE_SAMPLE_NATIVE_CHECK", "NARRATION_NATIVE_PCM_WAV",
        "VOICERELAY_REVIEW_FIXTURES", "VOICERELAY_REVIEW_OUTPUT", "NARRATION_CHECK_POLICY",
        "NARRATION_CHECK_OUTPUT_FORMAT",
    ] { environment.removeValue(forKey: name) }
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    var tail = Data()
    while let data = try pipe.fileHandleForReading.read(upToCount: 65_536), !data.isEmpty {
        tail.append(data)
        if tail.count > 2_097_152 { tail.removeFirst(tail.count - 2_097_152) }
    }
    process.waitUntilExit()
    return Result(status: process.terminationStatus, output: String(decoding: tail, as: UTF8.self))
}

func executePlan(_ steps: [Step], runner: Runner, record: (StepRecord) throws -> Void) throws -> String {
    var failed = false
    for step in steps {
        if failed {
            try record(
                StepRecord(
                    name: step.name, kind: step.kind, outcome: "not-run", exitCode: nil, log: nil, observations: []))
            continue
        }
        FileHandle.standardOutput.write(Data("RUNNING \(step.name)\n".utf8))
        let result: Result
        do { result = try runner(step.command) } catch {
            result = Result(status: 2, output: "Unable to execute step: \(error)")
        }
        let noTests = result.output.contains("No matching test cases were run")
        failed = result.status != 0 || noTests
        let observations = result.output.split(separator: "\n").filter {
            $0.contains("Executed ") || $0.contains(" skipped") || $0.contains(" tests passed")
                || $0.contains("Test run with ") || $0.contains("No matching test") || $0.contains("assertions passed")
        }.suffix(80).map(String.init)
        try record(
            StepRecord(
                name: step.name, kind: step.kind, outcome: failed ? "failed" : "passed",
                exitCode: noTests && result.status == 0 ? 1 : result.status, log: result.output,
                observations: observations))
    }
    return failed ? "failed" : "passed"
}

func validate(_ options: Options, runner: Runner = boundedRun) throws -> Int32 {
    _ = try Baseline.load(options.root)
    let evidence = options.root.appendingPathComponent(".local/validation/\(options.tier)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
    let source = try [sourceState(options.root)]
    var toolchain: [String: String] = [:]
    for (name, executable, arguments) in [
        ("xcode", "/usr/bin/xcodebuild", ["-version"]), ("swift", "/usr/bin/swift", ["--version"]),
        ("sdk", "/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-version"]),
        ("architecture", "/usr/bin/uname", ["-m"]),
    ] {
        toolchain[name] = try capture(Command(executable: executable, arguments: arguments, directory: options.root))
            .output
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var summary = ValidationSummary(
        started: Date(), tier: options.tier, scope: options.scope, filter: options.filter,
        signingClass: options.adhoc ? "ad-hoc-engineering" : "not-applicable", source: source, toolchain: toolchain,
        fingerprints: try fingerprints(options.root),
        unrequestedGates: ["quick", "full", "native", "release"].filter { $0 != options.tier })
    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(summary).write(to: evidence.appendingPathComponent("summary.json"), options: .atomic)
    }
    try save()
    FileHandle.standardOutput.write(Data("Evidence: \(evidence.path)\n".utf8))
    let steps =
        options.tier == "native" && !nativePrerequisites(options) ? [] : validationPlan(options, evidence: evidence)
    if steps.isEmpty {
        summary.outcome = "unavailable"
        summary.steps = [
            StepRecord(
                name: "native-assets", kind: "offline-native", outcome: "unavailable",
                exitCode: nil, log: nil,
                observations: [
                    "Supply --workspace (isolated, prepared models), --libro-worker and --voicerelay-worker. No download/build/GUI attempted."
                ])
        ]
    } else {
        summary.outcome = try executePlan(steps, runner: runner) { record in
            FileHandle.standardOutput.write(Data("\(record.outcome.uppercased()) \(record.name)\n".utf8))
            let path = evidence.appendingPathComponent("\(record.name).log")
            if let output = record.log { try Data(output.utf8).write(to: path) }
            summary.steps.append(
                StepRecord(
                    name: record.name, kind: record.kind, outcome: record.outcome,
                    exitCode: record.exitCode, log: record.log == nil ? nil : path.lastPathComponent,
                    observations: record.observations))
            if record.kind == "packaging", record.outcome == "passed", let output = record.log,
                let bundle = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
                let artifacts = bundle["artifacts"] as? [String: String]
            {
                summary.bundles[record.name] = artifacts
                summary.bundleSigningClasses[record.name] = bundle["signingClass"] as? String
            }
            try save()
        }
    }
    summary.finished = Date()
    try save()
    print("\(options.tier): \(summary.outcome); operator acceptance not performed.")
    return summary.outcome == "passed" ? 0 : (summary.outcome == "unavailable" ? 3 : 1)
}
