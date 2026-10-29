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
                    try setup(options.root, prepare: options.prepare, resolve: options.resolve)
                case "check":
                    exit(try validate(options))
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
    var prepare = false
    var resolve = false
    var tier = "full"
    var scope: String?
    var filter: String?
    var adhoc = false
    var skipArchives = false
    var workspace: String?
    var libroWorker: String?
    var voiceRelayWorker: String?

    init(_ arguments: [String]) throws {
        guard let first = arguments.first, ["health", "setup", "check"].contains(first) else {
            throw ToolError(
                "Usage: bash scripts/develop.sh health | setup <actions> | check [--tier quick|full|native|release]. See docs/DEVELOPMENT.md."
            )
        }
        command = first
        var remaining = Array(arguments.dropFirst())
        while !remaining.isEmpty {
            let argument = remaining.removeFirst()
            func value() throws -> String {
                guard let next = remaining.first, !next.hasPrefix("--"), !next.isEmpty else {
                    throw ToolError("\(argument) requires a value.")
                }
                return remaining.removeFirst()
            }
            switch argument {
            case "--root":
                root = URL(fileURLWithPath: try value()).standardizedFileURL
            case "--strict-baseline" where command == "health": strict = true
            case "--clone-apps" where command == "setup":
                throw ToolError(
                    "Both apps are included in the monorepo. Clone NarrationApps once, then use setup --resolve.")
            case "--prepare-dependencies" where command == "setup": prepare = true
            case "--resolve" where command == "setup": resolve = true
            case "--tier" where command == "check": tier = try value()
            case "--scope" where command == "check": scope = try value()
            case "--filter" where command == "check": filter = try value()
            case "--adhoc" where command == "check": adhoc = true
            case "--skip-archives" where command == "check": skipArchives = true
            case "--workspace" where command == "check": workspace = try value()
            case "--libro-worker" where command == "check": libroWorker = try value()
            case "--voicerelay-worker" where command == "check": voiceRelayWorker = try value()
            default: throw ToolError("Unknown or inapplicable argument: \(argument)")
            }
        }
        guard ["quick", "full", "native", "release"].contains(tier),
            scope == nil || ["presentation", "shared", "libro", "voicerelay"].contains(scope!),
            scope == nil || tier == "quick", filter == nil || scope != nil,
            !adhoc || tier == "release", !skipArchives || tier == "release",
            (workspace == nil && libroWorker == nil && voiceRelayWorker == nil) || tier == "native"
        else {
            throw ToolError("Invalid tier/scope/filter/signing/native option combination; see docs/DEVELOPMENT.md.")
        }
        if command == "check", tier == "release", !adhoc {
            throw ToolError(
                "Local release requires --adhoc. Normal account/distribution signing remains operator-owned.")
        }
    }
}
