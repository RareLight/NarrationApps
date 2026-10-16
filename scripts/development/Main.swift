import Foundation

#if !TOOL_TESTS
@main
enum DevelopmentTool {
    static func main() {
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            switch options.command {
            case "health":
                exit(try health(options.root, strict: options.strict) ? 0 : 1)
            case "setup":
                try setup(options.root, cloneApps: options.cloneApps, prepare: options.prepare, resolve: options.resolve)
            default:
                throw ToolError("Unknown command.")
            }
        } catch {
            print("ERROR \(error)")
            exit(2)
        }
    }
}
#endif

struct Options {
    var command: String
    var root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var strict = false
    var cloneApps = false
    var prepare = false
    var resolve = false

    init(_ arguments: [String]) throws {
        guard let first = arguments.first, ["health", "setup"].contains(first) else {
            throw ToolError("Usage: bash scripts/develop.sh health [--strict-baseline] | setup [--clone-apps] [--prepare-dependencies] [--resolve]")
        }
        command = first
        var remaining = Array(arguments.dropFirst())
        while !remaining.isEmpty {
            let argument = remaining.removeFirst()
            switch argument {
            case "--root":
                guard !remaining.isEmpty else { throw ToolError("--root requires a path.") }
                root = URL(fileURLWithPath: remaining.removeFirst()).standardizedFileURL
            case "--strict-baseline" where command == "health": strict = true
            case "--clone-apps" where command == "setup": cloneApps = true
            case "--prepare-dependencies" where command == "setup": prepare = true
            case "--resolve" where command == "setup": resolve = true
            default: throw ToolError("Unknown or inapplicable argument: \(argument)")
            }
        }
    }
}
