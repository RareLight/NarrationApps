import Foundation
import Darwin

/// An explicit derived comparison preserves source runs, including failed attempts.
/// It never picks between two successful renders of the same profile.
public enum CombinedEvidence {
    public static func create(sources: [URL], output: URL) throws {
        guard sources.count >= 2, !FileManager.default.fileExists(atPath: output.path) else {
            throw BenchError("Combine requires at least two source runs and a new output directory")
        }
        var matrix: Matrix?, orderedIDs: [String] = [], profiles: [String: Profile] = [:]
        var attempts: [(URL, Attempt)] = [], successes: Set<String> = [], ids: Set<String> = []
        var receipts: [[String: String]] = []
        var locks: [Int32] = []
        defer { for lock in locks { close(lock) } }
        for source in sources {
            let lock = open(source.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lock >= 0 else { throw BenchError("Cannot lock source run") }
            locks.append(lock)
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw BenchError("Source run is in use") }
            let matrixURL = source.appendingPathComponent("matrix.json")
            let input = try Files.read(Matrix.self, matrixURL)
            var settings = input; settings.profiles = []
            if let matrix {
                var expected = matrix; expected.profiles = []
                guard settings == expected else { throw BenchError("Combined runs require identical corpus, seed and measurement settings") }
            } else { matrix = input }
            let records = try Reports.attempts(source)
            guard !records.contains(where: { $0.outcome == "running" }) else { throw BenchError("Cannot combine a running source") }
            for profile in input.profiles {
                let completed = records.filter { $0.profile.id == profile.id && $0.outcome == "completed" }
                guard completed.count <= 1 else { throw BenchError("Multiple successful attempts require a separate comparison profile") }
                if profiles[profile.id] == nil { orderedIDs.append(profile.id); profiles[profile.id] = profile }
                if let success = completed.first {
                    guard successes.insert(profile.id).inserted else { throw BenchError("Cannot choose between successful attempts for \(profile.id)") }
                    profiles[profile.id] = success.profile
                }
            }
            for record in records {
                try Files.id(record.id)
                guard ids.insert(record.id).inserted else { throw BenchError("Duplicate source attempt") }
                for sample in record.measurements {
                    guard try Files.hash(Files.child(source, "attempts/\(record.id)/\(sample.wav)")) == sample.sha256 else { throw BenchError("Source audio changed") }
                }
                attempts.append((source, record))
            }
            receipts.append(["source": source.path, "matrixSHA256": try Files.hash(matrixURL),
                "attemptsSHA256": Files.hash(String(decoding: try Files.encoder.encode(records), as: UTF8.self))])
        }
        guard var matrix else { throw BenchError("No source matrices") }
        for id in successes {
            let records = attempts.map { $0.1 }.filter { $0.profile.id == id }
            let completed = records.first { $0.outcome == "completed" }!
            guard !records.contains(where: { $0.outcome != "completed" && $0.started > completed.started }) else {
                throw BenchError("A later unsuccessful attempt must not be hidden by an older success")
            }
        }
        matrix.profiles = orderedIDs.compactMap { profiles[$0] }
        try matrix.validate()
        let staging = output.deletingLastPathComponent().appendingPathComponent(".combine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try Files.write(matrix, staging.appendingPathComponent("matrix.json"))
        try Files.write(receipts, staging.appendingPathComponent("sources.json"))
        let destination = staging.appendingPathComponent("attempts")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for (source, record) in attempts {
            try FileManager.default.copyItem(at: Files.child(source, "attempts/" + record.id), to: destination.appendingPathComponent(record.id))
        }
        let provenance = staging.appendingPathComponent("provenance")
        for (index, source) in sources.enumerated() {
            let folder = provenance.appendingPathComponent(String(index + 1))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in ["matrix.json", "build.json", "environment.json", "asset-locks.json", "frozen-executables.json"] {
                let path = source.appendingPathComponent(file)
                if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.copyItem(at: path, to: folder.appendingPathComponent(file)) }
            }
        }
        try Reports.summary(root: staging, matrix: matrix, attempts: attempts.map { $0.1 }.sorted { $0.started < $1.started })
        try FileManager.default.moveItem(at: staging, to: output)
    }
}
