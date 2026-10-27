import Foundation
import BenchmarkCore
import Darwin

@main struct Command {
    static func main() async {
        Runtime.installSignals()
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch { fputs("tts-benchmark: \(error)\n", stderr); exit(1) }
    }
    static let help = """
    Swift TTS model benchmark (developer utility)
      inventory                         Print the default model matrix; no downloads
      init MATRIX.json                  Save an editable matrix (refuses replacement)
      prepare MATRIX WORKSPACE          Explicitly download and lock model/dependency files
      preflight MATRIX WORKSPACE        Verify local asset inventories; no network
      run MATRIX WORKSPACE RUN WORKER [REFERENCE_WORKER PRODUCT_WORKER]
                                       Serial offline comparison; durable attempts/resume
      report RUN                        Rebuild summary from recorded evidence
      combine OUTPUT RUN RUN [...]      Derive a comparison retaining all source attempts
      bracket RUN                       Create/resume server-free blind listening web app
      import-progress RUN JSON          Validate a browser progress backup into Swift state
      choose RUN MATCH a|b|tie|neither|defer [NOTE]
      revise RUN MATCH a|b|tie|neither|defer [NOTE]
      retain RUN ENTRANT                Keep an extra contender for blind confirmation
      finalists RUN MATRIX.json         Prepare a finalist matrix with held-out long-form text
      blind RUN [CONFIRMATION_RUN]       Generate held-out pack after bracket completion
    All paths are explicit. Cold/warm states are timing measurements, not entrants.
    """
    static func run(_ args: [String]) async throws {
        guard let command = args.first else { print(help); return }
        func url(_ i: Int) throws -> URL {
            guard args.count > i else { throw BenchError(help) }
            return URL(fileURLWithPath: args[i]).standardizedFileURL
        }
        if command == "--help" || command == "help" { print(help); return }
        if command == "inventory" { print(String(decoding: try Files.encoder.encode(Catalog.matrix()), as: UTF8.self)); return }
        if command == "init" {
            let file = try url(1); guard !FileManager.default.fileExists(atPath: file.path) else { throw BenchError("Matrix exists") }
            try Files.write(Catalog.matrix(), file); return
        }
        if command == "combine" {
            guard args.count >= 4 else { throw BenchError(help) }
            try CombinedEvidence.create(sources: try (2..<args.count).map { try url($0) }, output: url(1)); return
        }
        if ["prepare", "preflight", "run"].contains(command) {
            var matrix = try Files.read(Matrix.self, url(1)); try matrix.validate()
            let workspace = try url(2)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            if command == "prepare" {
                var seen: Set<String> = []
                for p in matrix.profiles where p.blockedReason == nil {
                    if p.family == "kokoro", p.voice?.hasPrefix("b") == true { try await Assets.prepareBritish(workspace) }
                    for repo in [p.repository] + p.dependencies where seen.insert(repo).inserted {
                        let revision = repo == Catalog.g2pRepo ? Catalog.g2pRevision : (repo == p.repository ? p.revision : nil)
                        _ = try await Assets.prepare(workspace, repository: repo, revision: revision)
                    }
                }
                return
            }
            var blocked: [String: String] = [:]
            for i in matrix.profiles.indices {
                if let reason = matrix.profiles[i].blockedReason { blocked[matrix.profiles[i].id] = reason; continue }
                do {
                    let p = matrix.profiles[i]
                    let snap = try Assets.verify(Assets.directory(workspace, repository: p.repository))
                    guard p.revision == nil || p.revision == snap.revision else { throw BenchError("Profile revision mismatch") }
                    matrix.profiles[i].revision = snap.revision
                    if p.family == "kokoro", p.voice?.hasPrefix("b") == true { _ = try Assets.verify(Assets.britishDirectory(workspace)) }
                    for dep in p.dependencies { _ = try Assets.verify(Assets.directory(workspace, repository: dep)) }
                    if let reference = p.referenceAudio { _ = try Wave.inspect(Files.child(workspace, reference)) }
                    print("READY \(p.id)")
                } catch { blocked[matrix.profiles[i].id] = "\(error)"; print("BLOCKED \(matrix.profiles[i].id): \(error)") }
            }
            if command == "preflight" { for (id, why) in blocked.sorted(by: { $0.key < $1.key }) { print("BLOCKED \(id): \(why)") }; if blocked.count == matrix.profiles.count { throw BenchError("No prepared profiles") }; return }
            let output = try url(3), worker = try url(4)
            guard !FileManager.default.fileExists(atPath: output.appendingPathComponent("sources.json").path) else {
                throw BenchError("A derived comparison is for reporting/listening; use a new directory for inference")
            }
            guard matrix.footprintLimitBytes <= ProcessInfo.processInfo.physicalMemory * 3 / 4 else { throw BenchError("Worker memory budget leaves insufficient machine headroom") }
            guard FileManager.default.isExecutableFile(atPath: worker.path) else { throw BenchError("Worker not executable") }
            var referenceWorker: URL?, productWorker: URL?
            if args.count == 7 {
                referenceWorker = try url(5); productWorker = try url(6)
                guard FileManager.default.isExecutableFile(atPath: referenceWorker!.path), FileManager.default.isExecutableFile(atPath: productWorker!.path) else { throw BenchError("Reference executables are missing") }
                for source in matrix.profiles.filter({ ["kokoro-heart", "soprano"].contains($0.id) }) {
                    var profile = source; profile.id += "-product-reference"; profile.label += " (product reference)"; profile.productReference = true
                    matrix.profiles.append(profile)
                }
            } else if args.count != 5 { throw BenchError(help) }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let matrixFile = output.appendingPathComponent("matrix.json")
            if FileManager.default.fileExists(atPath: matrixFile.path) {
                guard try Files.read(Matrix.self, matrixFile) == matrix else { throw BenchError("Run matrix changed; select a new run directory") }
            } else { try Files.write(matrix, matrixFile) }
            // A single advisory host lock prevents concurrent run/bracket mutations.
            let lock = open(output.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw BenchError("Run already in use") }
            defer { close(lock) }
            let productHash = try productWorker.map { try Files.hash($0) } ?? ""
            let referenceHash = try referenceWorker.map { try Files.hash($0) } ?? ""
            let buildEvidence = worker.deletingLastPathComponent().appendingPathComponent("benchmark-build.json")
            guard FileManager.default.fileExists(atPath: buildEvidence.path) else { throw BenchError("Missing build evidence; use scripts/build.sh") }
            let buildHash = try Files.hash(buildEvidence)
            let hostHash = try Files.hash(URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
            var locks: [String: Snapshot] = [:]
            for p in matrix.profiles where blocked[p.id] == nil {
                for repo in [p.repository] + p.dependencies {
                    let file = try Assets.directory(workspace, repository: repo).appendingPathComponent("benchmark-assets.json")
                    locks[repo] = try Files.read(Snapshot.self, file)
                }
                if p.family == "kokoro", p.voice?.hasPrefix("b") == true {
                    locks["british-g2p"] = try Files.read(Snapshot.self, Assets.britishDirectory(workspace).appendingPathComponent("benchmark-assets.json"))
                }
            }
            let assetHash = Files.hash(String(decoding: try Files.encoder.encode(locks), as: UTF8.self))
            let identity = Files.hash(String(decoding: try Files.encoder.encode(matrix), as: UTF8.self) + (try Files.hash(worker)) + productHash + referenceHash + buildHash + hostHash + assetHash)
            guard try Reports.attempts(output).allSatisfy({ $0.identity == identity }) else { throw BenchError("Benchmark executable/build identity changed; use a new run directory") }
            let recordedBuild = output.appendingPathComponent("build.json")
            if !FileManager.default.fileExists(atPath: recordedBuild.path) { try FileManager.default.copyItem(at: buildEvidence, to: recordedBuild) }
            if !FileManager.default.fileExists(atPath: output.appendingPathComponent("environment.json").path) {
                try Files.write(EnvironmentEvidence(workerHash: try Files.hash(worker), productWorkerHash: productHash), output.appendingPathComponent("environment.json"))
            }
            try Files.write(locks, output.appendingPathComponent("asset-locks.json"))
            var rng = SplitMix(seed: matrix.seed)
            for profile in matrix.profiles.shuffled(using: &rng) {
                if Runtime.cancelled != 0 { break }
                let prior = try Reports.attempts(output).filter { $0.profile.id == profile.id }
                for var stale in prior where stale.outcome == "running" {
                    stale.outcome = "interrupted"; stale.reason = "Previous host exited without a terminal record; original evidence retained."
                    try Files.write(stale, output.appendingPathComponent("attempts/\(stale.id)/attempt.json"))
                }
                if prior.contains(where: { $0.identity == identity && ["completed", "failed", "blocked", "cancelled"].contains($0.outcome) }) { print("RETAINED prior attempt: \(profile.id)"); continue }
                let id = profile.id + "-" + UUID().uuidString.lowercased()
                let directory = try Files.child(output, "attempts/" + id)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var attempt = Attempt(id: id, identity: identity, profile: profile, outcome: "running")
                try Files.write(attempt, directory.appendingPathComponent("attempt.json"))
                if let reason = blocked[profile.id] { attempt.outcome = "blocked"; attempt.reason = reason }
                else {
                    let assetDir = try Assets.directory(workspace, repository: profile.repository)
                    let g2p = profile.family == "kokoro" ? (profile.voice?.hasPrefix("b") == true ? Assets.britishDirectory(workspace).path : try Assets.directory(workspace, repository: Catalog.g2pRepo).path) : nil
                    let job = WorkerJob(matrix: matrix, profile: profile, workspace: workspace.path, output: directory.path, assetDirectory: assetDir.path, g2pDirectory: g2p, productWorker: productWorker?.path)
                    print("RUNNING \(profile.label)"); fflush(stdout)
                    do { attempt = try Supervisor.run(executable: profile.productReference ? referenceWorker! : worker, job: job, attempt: attempt, directory: directory) }
                    catch { attempt.outcome = "failed"; attempt.reason = "\(error)" }
                }
                try Files.write(attempt, directory.appendingPathComponent("attempt.json"))
                print("\(attempt.outcome.uppercased()) \(profile.id): \(attempt.measurements.count) recordings \(attempt.reason ?? "")"); fflush(stdout)
                try Reports.summary(root: output, matrix: matrix, attempts: Reports.attempts(output))
            }
            let attempts = try Reports.attempts(output)
            try Reports.summary(root: output, matrix: matrix, attempts: attempts)
            guard attempts.contains(where: { $0.outcome == "completed" }) else { throw BenchError("No completed profiles; failure evidence and reports retained") }
            return
        }
        let root = try url(1), matrix = try Files.read(Matrix.self, root.appendingPathComponent("matrix.json"))
        let mutationLock = open(root.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard mutationLock >= 0, flock(mutationLock, LOCK_EX | LOCK_NB) == 0 else { throw BenchError("Run already in use") }
        defer { close(mutationLock) }
        if command == "report" { try Reports.summary(root: root, matrix: matrix, attempts: Reports.attempts(root)); return }
        let stateURL = root.appendingPathComponent("bracket.json")
        var bracket: Bracket
        if FileManager.default.fileExists(atPath: stateURL.path) { bracket = try Files.read(Bracket.self, stateURL) }
        else {
            guard command == "bracket" else { throw BenchError("Create the preference bracket first") }
            bracket = try Bracket(entrants: Reports.entrants(root: root, matrix: matrix, attempts: Reports.attempts(root)), seed: matrix.seed)
        }
        if command == "choose" || command == "revise" {
            guard args.count >= 4 else { throw BenchError(help) }
            try bracket.answer(match: args[2], choice: args[3].lowercased(), note: args.dropFirst(4).joined(separator: " "), revise: command == "revise")
        } else if command == "import-progress" {
            guard args.count == 3 else { throw BenchError(help) }
            bracket = try WebBracket.importProgress(Data(contentsOf: url(2)), root: root, matrix: matrix, bracket: bracket)
        } else if command == "retain" {
            guard args.count == 3, bracket.entrants.contains(where: { $0.id == args[2] }) else { throw BenchError("Unknown entrant") }
            if !bracket.retained.contains(args[2]) { bracket.retained.append(args[2]) }
        } else if command == "finalists" {
            let target = try url(2)
            guard !FileManager.default.fileExists(atPath: target.path) else { throw BenchError("Finalist matrix exists") }
            let ids = try bracket.shortlist()
            guard ids.count >= 2 else { throw BenchError("At least two finalists required") }
            var confirmation = matrix
            confirmation.profiles = matrix.profiles.filter { ids.contains($0.id) && !$0.productReference }
            confirmation.passages = matrix.passages.filter { $0.role == "heldout" } + [Longform.passage]
            confirmation.repetitions = 2
            confirmation.timeoutSeconds = try Reports.finalistTimeout(matrix: confirmation, attempts: Reports.attempts(root))
            try confirmation.validate(); try Files.write(confirmation, target)
            print("Finalist matrix saved; run it into a new directory, then use blind RUN CONFIRMATION_RUN."); return
        } else if command == "blind" {
            var listeningMatrix = matrix, listeningBracket = bracket
            if args.count == 3 {
                let confirmationRoot = try url(2)
                listeningMatrix = try Files.read(Matrix.self, confirmationRoot.appendingPathComponent("matrix.json"))
                guard listeningMatrix.passages.contains(where: { $0.role == "longform" }),
                      !listeningMatrix.passages.contains(where: { $0.role == "calibration" }) else { throw BenchError("Confirmation run needs held-out material") }
                let recordings = try Reports.entrants(root: confirmationRoot, matrix: listeningMatrix, attempts: Reports.attempts(confirmationRoot))
                for id in try bracket.shortlist() {
                    guard let index = listeningBracket.entrants.firstIndex(where: { $0.id == id }),
                          let source = recordings.first(where: { $0.id == id }), source.identity == listeningBracket.entrants[index].identity else { throw BenchError("Missing or changed finalist identity") }
                    for (passage, clip) in source.clips {
                        let relative = "confirmation/\(id)/\(passage)-\(source.hashes[passage]!.prefix(12)).wav"
                        let destination = try Files.child(root, relative)
                        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: Files.child(confirmationRoot, clip), to: destination) }
                        guard try Files.hash(destination) == source.hashes[passage] else { throw BenchError("Confirmation copy differs") }
                        listeningBracket.entrants[index].clips[passage] = relative
                        listeningBracket.entrants[index].hashes[passage] = source.hashes[passage]
                    }
                }
            } else if args.count != 2 { throw BenchError(help) }
            try Reports.blindPack(listeningBracket, matrix: listeningMatrix, root: root)
            print("Blind pack: \(root.appendingPathComponent("blind/index.html").path)"); return
        }
        else if command != "bracket" { throw BenchError(help) }
        try Files.write(bracket, stateURL); try Reports.bracketPage(bracket, matrix: matrix, root: root)
        print("Listening page: \(root.appendingPathComponent("bracket.html").path)")
        if let next = try bracket.view().pending { print("Pending \(next.id); identities hidden until final reveal.") }
        else { print("Preliminary bracket complete; generate blind confirmation when ready.") }
    }
}
