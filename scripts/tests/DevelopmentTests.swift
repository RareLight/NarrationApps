import Foundation

@main
enum DevelopmentTests {
    static func main() throws {
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fixture = source.deletingLastPathComponent().appendingPathComponent(".NarrationApps-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        var count = 0
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw ToolError("TEST FAILED: \(message)") }
            count += 1
        }
        func rejects(_ body: () throws -> Void) throws {
            do { try body() } catch { count += 1; return }
            throw ToolError("TEST FAILED: expected rejection")
        }
        let data = try Data(contentsOf: source.appendingPathComponent("DevelopmentBaseline.json"))
        let manifest = fixture.appendingPathComponent("DevelopmentBaseline.json")
        try data.write(to: manifest)
        try expect(try Baseline.load(fixture).components.count == 2, "baseline decodes")
        let original = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        func altered(_ edit: (inout [String: Any]) -> Void) throws {
            var object = original
            edit(&object)
            try JSONSerialization.data(withJSONObject: object).write(to: manifest)
            try rejects { _ = try Baseline.load(fixture) }
            try data.write(to: manifest)
        }
        try altered { $0["schemaVersion"] = 99 }
        try altered { $0["rootRevisionPolicy"] = "self-sha" }
        try altered { $0["components"] = [] }
        for (field, value) in [("path", "../Libro"), ("path", "/Libro"), ("revision", "main"), ("cloneURL", "file:///private")] {
            try altered {
                var components = $0["components"] as! [[String: Any]]
                components[0][field] = value
                $0["components"] = components
            }
        }
        try Data("{malformed".utf8).write(to: manifest)
        try rejects { _ = try Baseline.load(fixture) }
        try data.write(to: manifest)
        try rejects { _ = try Options(["health", "--clone-apps"]) }
        try rejects { _ = try Options(["setup", "--unknown"]) }
        try rejects { _ = try Options(["health", "--root"]) }
        try rejects { try setup(fixture, cloneApps: false, prepare: false, resolve: false) }

        // Real tiny independent Git checkouts, no app data or shared build caches.
        let seed = fixture.appendingPathComponent("seed")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        func checkedGit(_ directory: URL, _ arguments: [String]) throws -> String {
            let result = try git(directory, arguments)
            guard result.status == 0 else { throw ToolError(result.output) }
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try checkedGit(seed, ["init", "-q"])
        try Data("authored synthetic fixture\n".utf8).write(to: seed.appendingPathComponent("fixture"))
        _ = try checkedGit(seed, ["add", "fixture"])
        _ = try checkedGit(seed, ["-c", "user.name=Fixture", "-c", "user.email=fixture@localhost",
            "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture"])
        let revision = try checkedGit(seed, ["rev-parse", "HEAD"])
        var object = original
        var components = object["components"] as! [[String: Any]]
        for index in components.indices { components[index]["revision"] = revision }
        object["components"] = components
        try JSONSerialization.data(withJSONObject: object).write(to: manifest)
        var calls: [Command] = []
        let runner: Runner = { command in
            calls.append(command)
            if command.arguments.first == "clone" {
                return try capture(Command(executable: "/usr/bin/git",
                    arguments: ["clone", "--no-checkout", seed.path, command.arguments.last!], directory: fixture))
            }
            return try capture(command)
        }
        try setup(fixture, cloneApps: true, prepare: false, resolve: false, runner: runner)
        try expect(calls.filter { $0.arguments.first == "clone" }.count == 2, "explicit setup clones only missing apps")
        let libro = fixture.appendingPathComponent("Libro")
        let retained = libro.appendingPathComponent("private-edit")
        try Data("preserve me".utf8).write(to: retained)
        calls = []
        try setup(fixture, cloneApps: true, prepare: false, resolve: false, runner: runner)
        try expect(calls.isEmpty, "repeat setup preserves existing folders without git actions")
        try expect(try String(contentsOf: retained, encoding: .utf8) == "preserve me", "private edit preserved")
        let baseline = try Baseline.load(fixture)
        let state = try sourceState(fixture, component: baseline.components[0])
        try expect(state.matchesBaseline && state.dirty == true && state.baselineAvailable, "dirty state accurately recorded")
        var toolFailure = false
        var architecture = "arm64"
        var sdk = "27.0"
        let diagnosticRunner: Runner = { command in
            if command.executable == "/usr/bin/git" { return try capture(command) }
            let output: String
            switch command.arguments {
            case ["-m"]: output = architecture
            case ["--sdk", "macosx", "--show-sdk-version"]: output = sdk
            case ["-version"]: output = "Xcode 27.1\nBuild version 27A9275"
            default: output = "/synthetic/tool"
            }
            return Result(status: toolFailure ? 1 : 0, output: output)
        }
        for name in ["ZIPFoundation", "mlx-audio-swift", "mlx-swift", "mlx-swift-lm", "swift-huggingface"] {
            let directory = fixture.appendingPathComponent("swift-packages/.build/dependencies/\(name)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: directory.appendingPathComponent("Package.swift"))
        }
        let codec = fixture.appendingPathComponent("swift-packages/.build/codecs/lame/lib")
        try FileManager.default.createDirectory(at: codec, withIntermediateDirectories: true)
        try Data().write(to: codec.appendingPathComponent("libmp3lame.0.dylib"))
        let before = try checkedGit(libro, ["status", "--porcelain"])
        try expect(try health(fixture, strict: false, runner: diagnosticRunner), "dirty development divergence allowed")
        try expect(try !health(fixture, strict: true, runner: diagnosticRunner), "strict mode rejects dirty state")
        architecture = "x86_64"
        try expect(try !health(fixture, strict: false, runner: diagnosticRunner), "Rosetta rejected")
        architecture = "arm64"; sdk = "26.0"
        try expect(try !health(fixture, strict: false, runner: diagnosticRunner), "unsupported SDK rejected")
        sdk = "27.0"; toolFailure = true
        try expect(try !health(fixture, strict: false, runner: diagnosticRunner), "missing selected tools rejected")
        try expect(try checkedGit(libro, ["status", "--porcelain"]) == before, "health does not change app checkout")
        components[0]["revision"] = String(repeating: "0", count: 40)
        object["components"] = components
        try JSONSerialization.data(withJSONObject: object).write(to: manifest)
        let missing = try sourceState(fixture, component: Baseline.load(fixture).components[0])
        try expect(!missing.baselineAvailable && !missing.matchesBaseline, "unavailable checkpoint diagnosed without fetch")
        let absent = fixture.appendingPathComponent("absent")
        try FileManager.default.createDirectory(at: absent, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: absent.appendingPathComponent("DevelopmentBaseline.json"))
        try rejects { try setup(absent, cloneApps: true, prepare: false, resolve: false, runner: runner) }
        try expect(!FileManager.default.fileExists(atPath: absent.appendingPathComponent("Libro").path), "unavailable commit never installs partial app")
        try expect(try sourceState(absent, component: baseline.components[0]).revision == nil, "missing app state explicit")
        print("Development tooling: \(count) assertions passed; disposable sibling, no network/models/apps.")
    }
}
