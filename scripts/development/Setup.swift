import Foundation

func setup(_ root: URL, cloneApps: Bool, prepare: Bool, resolve: Bool, runner: Runner = capture) throws {
    let baseline = try Baseline.load(root)
    guard cloneApps || prepare || resolve else {
        throw ToolError("Setup requires an explicit action: --clone-apps, --prepare-dependencies or --resolve. Network authorization is required.")
    }
    func run(_ executable: String, _ arguments: [String]) throws {
        let result = try runner(Command(executable: executable, arguments: arguments, directory: root,
            environment: ["GIT_TERMINAL_PROMPT": "0"]))
        guard result.status == 0 else {
            throw ToolError("Setup action failed (\(result.status)); existing state is preserved. Inspect locally, including remote availability/credentials. No model installation attempted.")
        }
        print(result.output)
    }
    if cloneApps {
        for component in baseline.components {
            let path = root.appendingPathComponent(component.path)
            guard !FileManager.default.fileExists(atPath: path.path),
                (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) == nil
            else {
                print("PRESERVED \(component.name): path exists; no fetch, checkout or overwrite.")
                continue
            }
            let stage = root.appendingPathComponent(".local/setup-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stage) }
            let checkout = stage.appendingPathComponent(component.name)
            try run("/usr/bin/git", ["clone", "--no-checkout", "--", component.cloneURL, checkout.path])
            guard try git(checkout, ["cat-file", "-e", "\(component.revision)^{commit}"], runner: runner).status == 0 else {
                throw ToolError("\(component.name): recorded commit is not available from this remote clone. Ask its owner to publish it; existing app paths remain unchanged.")
            }
            try run("/usr/bin/git", ["-C", checkout.path, "checkout", "--detach", component.revision])
            guard !FileManager.default.fileExists(atPath: path.path) else { throw ToolError("App path appeared during setup; refusing replacement.") }
            try FileManager.default.moveItem(at: checkout, to: path)
        }
    }
    if resolve {
        for component in baseline.components {
            guard try sourceState(root, component: component, runner: runner).revision != nil else {
                throw ToolError("Workspace resolution requires both independent app checkouts.")
            }
        }
    }
    if resolve {
        try run("/bin/bash", ["scripts/resolve-xcode-workspace.sh", "-derivedDataPath",
            root.appendingPathComponent(".build/WorkspaceDerivedData").path])
        for package in ["swift-packages", "Libro/macos/LibroCore", "VoiceRelay"] {
            var arguments = ["package", "--package-path", package, "--force-resolved-versions"]
            if package == "Libro/macos/LibroCore" { arguments += ["--scratch-path", "Libro/macos/.build/CoreTests"] }
            try run("/usr/bin/swift", arguments + ["resolve"])
        }
    } else if prepare {
        try run("/bin/bash", ["swift-packages/scripts/prepare-dependencies.sh"])
    }
}
