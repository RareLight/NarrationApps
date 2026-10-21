#!/usr/bin/env swift
// Operator-run actual-speech driver. Requires the installed local runtime.
import Foundation
import CryptoKit
import CSQLite
import Darwin

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(message) }
}

struct Episode: Decodable {
    let id: String
    let stage: String
    let publicationDate: Double?
}

func episode(in directory: URL) throws -> Episode {
    var database: OpaquePointer?
    let path = directory.appendingPathComponent("private/native.sqlite3").path
    let status = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil)
    defer { sqlite3_close(database) }
    try require(status == SQLITE_OK, "Cannot inspect fixture state read-only")
    var statement: OpaquePointer?
    let prepared = sqlite3_prepare_v2(database, "SELECT record FROM episodes", -1, &statement, nil)
    defer { sqlite3_finalize(statement) }
    try require(prepared == SQLITE_OK, "Cannot read fixture episode")
    try require(sqlite3_step(statement) == SQLITE_ROW, "Expected one fixture episode")
    guard let value = sqlite3_column_text(statement, 0) else {
        throw CheckFailure("Missing fixture episode record")
    }
    let data = Data(bytes: value, count: Int(sqlite3_column_bytes(statement, 0)))
    let result = try JSONDecoder().decode(Episode.self, from: data)
    try require(sqlite3_step(statement) == SQLITE_DONE, "Duplicate episode after interruption")
    return result
}

func digest(_ file: URL) throws -> Data {
    Data(SHA256.hash(data: try Data(contentsOf: file)))
}

struct RunResult {
    let reason: Process.TerminationReason
    let status: Int32
    let output: String
    var succeeded: Bool { reason == .exit && status == 0 }
}

func run(_ cli: URL, arguments: [String], in root: URL) throws -> RunResult {
    let log = root.appendingPathComponent("child-\(UUID().uuidString).log")
    try Data().write(to: log)
    let handle = try FileHandle(forWritingTo: log)
    defer { try? handle.close(); try? FileManager.default.removeItem(at: log) }
    let child = Process()
    child.executableURL = cli
    child.arguments = arguments
    child.currentDirectoryURL = root // Deliberately no implicit config.toml.
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = handle
    child.standardError = handle
    try child.run()
    let deadline = ProcessInfo.processInfo.systemUptime + 600
    while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    if child.isRunning {
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        throw CheckFailure("Speech fixture child exceeded the 600-second deadline")
    }
    child.waitUntilExit()
    try handle.synchronize()
    return RunResult(reason: child.terminationReason, status: child.terminationStatus,
                     output: String(decoding: try Data(contentsOf: log), as: UTF8.self))
}

func main() throws {
    try require(CommandLine.arguments.count == 3,
                "Usage: swift -I Sources/CSQLite scripts/check-process-recovery.swift <voicerelay-cli> <VoiceRelay-project-root>")
    let cli = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    try require(FileManager.default.isExecutableFile(atPath: cli.path), "CLI is not executable")
    for boundary in ["chunk-committed", "encoded", "audio-placed", "episode-committed", "feed-replaced"] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicerelay-kill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("fixture", isDirectory: true)
        let command = ["speech-fixture", "--project-root", CommandLine.arguments[2], "--directory", directory.path]
        let killed = try run(cli, arguments: command + ["--terminate-after", boundary], in: root)
        try require(killed.reason == .uncaughtSignal && killed.status == SIGKILL,
                    "Expected SIGKILL at \(boundary)")
        let before = try episode(in: directory)
        let resumed = try run(cli, arguments: command, in: root)
        try require(resumed.succeeded, "Resume failed at \(boundary)")
        if boundary != "chunk-committed" {
            try require(resumed.output.contains("0 synthesized this run"),
                        "Unnecessary synthesis at \(boundary)")
        }
        let after = try episode(in: directory)
        try require(after.id == before.id && after.stage == "PUBLISHED",
                    "Episode identity or publication changed at \(boundary)")
        if let date = before.publicationDate {
            try require(after.publicationDate == date, "Publication date changed at \(boundary)")
        }
        let audio = directory.appendingPathComponent("media/\(after.id).m4a")
        let feed = directory.appendingPathComponent("private/feed.xml")
        let audioHash = try digest(audio), feedHash = try digest(feed)
        let repeated = try run(cli, arguments: command, in: root)
        try require(repeated.succeeded && repeated.output.contains("0 synthesized this run"),
                    "Repeat was not idempotent at \(boundary)")
        try require(digest(audio) == audioHash && digest(feed) == feedHash,
                    "Published bytes changed on repeat at \(boundary)")
        print("PASS SIGKILL/restart/idempotence: \(boundary)")
    }
}

do { try main() }
catch {
    // This driver uses only synthetic inputs; avoid dumping child logs or file paths.
    let message = (error as? CheckFailure)?.description ?? "Recovery check failed; inspect the build and tool setup."
    FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
    exit(1)
}
