import Foundation

func setup(_ root: URL, prepare: Bool, resolve: Bool, runner: Runner = capture) throws {
    let baseline = try Baseline.load(root)
    guard prepare || resolve else {
        throw ToolError(
            "Setup requires an explicit action: --prepare-dependencies or --resolve. Network authorization is required."
        )
    }
    func run(_ executable: String, _ arguments: [String]) throws {
        let result = try runner(
            Command(
                executable: executable, arguments: arguments, directory: root,
                environment: ["GIT_TERMINAL_PROMPT": "0"]))
        guard result.status == 0 else {
            throw ToolError(
                "Setup action failed (\(result.status)); existing state is preserved. Inspect locally, including remote availability/credentials. No model installation attempted."
            )
        }
        print(result.output)
    }
    let problems = try sourceLayoutProblems(root, baseline: baseline, runner: runner)
    guard problems.isEmpty else { throw ToolError(problems.joined(separator: "\n")) }
    if resolve {
        try run(
            "/bin/bash",
            [
                "scripts/resolve-xcode-workspace.sh", "-derivedDataPath",
                root.appendingPathComponent(".build/WorkspaceDerivedData").path,
            ])
        for package in ["swift-packages", "Libro/macos/LibroCore", "VoiceRelay"] {
            var arguments = ["package", "--package-path", package, "--force-resolved-versions"]
            if package == "Libro/macos/LibroCore" { arguments += ["--scratch-path", "Libro/macos/.build/CoreTests"] }
            try run("/usr/bin/swift", arguments + ["resolve"])
        }
    } else if prepare {
        try run("/bin/bash", ["swift-packages/scripts/prepare-dependencies.sh"])
    }
}
