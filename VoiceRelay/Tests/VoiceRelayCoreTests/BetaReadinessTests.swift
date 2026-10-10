import Foundation
import Testing
import CSQLite
@testable import VoiceRelayCore

private func betaStorage(_ root: URL, _ tag: String) -> ManagedSpeechStorage {
    ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("\(tag)-audio"),
        stateRoot: root.appendingPathComponent(tag), temporaryRoot: root.appendingPathComponent("\(tag)-scratch"), temporaryAudio: true)
}
private func betaRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-beta-\(UUID().uuidString)")
    try Files.directory(root); return root
}
private func betaEnqueue(_ storage: ManagedSpeechStorage, coordinator: FixtureCoordinator, tag: String) async throws -> SpeechQueueItem {
    let url = URL(string: "https://articles.example/\(tag)")!
    let html = String(decoding: try FixtureResource.html(), as: UTF8.self)
    let entry = ReadingListEntry(id: tag, safariID: tag, url: url, title: "Synthetic article", addedAt: Date(timeIntervalSince1970: 1_700_000_000))
    _ = try await coordinator.reconcile(ReadingListSnapshot(entries: [entry], skippedEntries: 0), stateRoot: storage.stateRoot)
    return try await coordinator.enqueueReadingList(tag, storage: storage, preferences: SpeechPreferences(), fetch: { _ in
        FetchedPage(originalURL: url, finalURL: url, bytes: Data(html.utf8), html: html,
            contentType: "text/html", encoding: "utf-8", fetchedAt: Date())
    })
}

@Test func libraryBackupIncludesCommittedWALAndIsStandalone() throws {
    let root = try betaRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = betaStorage(root, "source")
    let store = try NativeStore(url: ManagedSpeechStorage.prepareLibrary(stateRoot: storage.stateRoot))
    var profile = storage.profile; profile.backendSelector = "reviewed-article-speech"
    let episode = try store.episode(sourceKey: "synthetic", settings: profile)
    #expect(FileManager.default.fileExists(atPath: storage.profile.database.path + "-wal"))
    let copy = root.appendingPathComponent("copy.sqlite3")
    try store.backup(to: copy)
    #expect(try NativeStore(url: copy, readOnly: true).episodes().map(\.id) == [episode.id])
    #expect(!FileManager.default.fileExists(atPath: copy.path + "-wal"))
    #expect(!FileManager.default.fileExists(atPath: copy.path + "-shm"))
    #expect(try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int == 0o600)
}

@Test func libraryBackupRoundTripPreservesTextDatesGUIDQueueAndDelivery() async throws {
    let root = try betaRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let source = betaStorage(root, "source"), target = betaStorage(root, "target")
    let coordinator = FixtureCoordinator()
    let item = try await betaEnqueue(source, coordinator: coordinator, tag: "one")
    let original = try NativeStore(url: source.profile.database, readOnly: true).episodes().first!
    var ledger = DeliveryLedger(); ledger.destinationURL = URL(string: "https://dav.example/feed/")
    ledger.pendingRemoteDeletes = ["audio/\(item.id).m4a"]; ledger.remoteFeedPending = true
    try ledger.save(stateRoot: source.stateRoot)
    let backup = root.appendingPathComponent("library.voicerelaybackup")
    let summary = try await coordinator.backupLibrary(storage: source, destination: backup)
    #expect(summary.episodes == 1 && summary.queuedArticles == 1 && summary.retainedArticles == 1)
    #expect(try await coordinator.inspectLibraryBackup(backup) == summary)
    #expect(try await coordinator.inspectLibraryBackup(backup) == summary) // Read checks create no sidecars.
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: backup.path)) == ["native.sqlite3", "manifest.json", "delivery.json"])
    #expect(try await coordinator.restoreLibrary(backup: backup, storage: target) == nil)
    let restored = try NativeStore(url: target.profile.database, readOnly: true).episodes().first!
    #expect(restored.id == original.id && restored.readingListSavedAt == original.readingListSavedAt)
    #expect(restored.settings.voice == original.settings.voice)
    #expect(restored.settings.database == target.profile.database && restored.settings.work == target.profile.work)
    #expect(try DeliveryLedger.load(stateRoot: target.stateRoot) == ledger)
    let snapshotBytes = try NativeStore(url: target.profile.database, readOnly: true).snapshot(articleID: item.id)
    let snapshot = try #require(snapshotBytes)
    let review = try JSONDecoder().decode(StoredExtraction.self, from: snapshot).review()
    #expect(review.page.originalURL.absoluteString == "https://articles.example/one")
    // Offline admission after restore uses saved text, without fetching or speech.
    let reused = try await coordinator.enqueueReadingList("one", storage: target, preferences: SpeechPreferences(), fetch: { _ in
        Issue.record("Restore must retain usable offline text"); throw SourceFetchError.network
    })
    #expect(reused.id == item.id)
}

@Test func libraryRestoreKeepsPreviousLibraryAndNeverTouchesAudio() async throws {
    let root = try betaRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let source = betaStorage(root, "source"), target = betaStorage(root, "target")
    let coordinator = FixtureCoordinator()
    let new = try await betaEnqueue(source, coordinator: coordinator, tag: "new")
    let old = try await betaEnqueue(target, coordinator: coordinator, tag: "old")
    try Files.directory(target.audioDirectory)
    let audio = target.audioDirectory.appendingPathComponent("unrelated.m4a")
    try Files.write(Data("keep this".utf8), to: audio)
    let backup = root.appendingPathComponent("library.voicerelaybackup")
    _ = try await coordinator.backupLibrary(storage: source, destination: backup)
    let previousURL = try await coordinator.restoreLibrary(backup: backup, storage: target)
    let previous = try #require(previousURL)
    #expect(try await coordinator.queue(stateRoot: target.stateRoot).map(\.id) == [new.id])
    #expect(try await coordinator.queue(stateRoot: previous).map(\.id) == [old.id])
    #expect(try Data(contentsOf: audio) == Data("keep this".utf8))
}

@Test func libraryRestoreRejectsCorruptionLinksAndUnknownFilesBeforeChangingState() async throws {
    let root = try betaRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let source = betaStorage(root, "source"), target = betaStorage(root, "target")
    let coordinator = FixtureCoordinator()
    _ = try await betaEnqueue(source, coordinator: coordinator, tag: "new")
    let old = try await betaEnqueue(target, coordinator: coordinator, tag: "old")
    let backup = root.appendingPathComponent("library.voicerelaybackup")
    _ = try await coordinator.backupLibrary(storage: source, destination: backup)
    let db = backup.appendingPathComponent("native.sqlite3"), original = try Data(contentsOf: db)
    try Files.write(Data("broken".utf8), to: db)
    await #expect(throws: (any Error).self) { try await coordinator.restoreLibrary(backup: backup, storage: target) }
    try Files.write(original, to: db)
    let extra = backup.appendingPathComponent("extra")
    try Files.write(Data(), to: extra)
    await #expect(throws: (any Error).self) { try await coordinator.restoreLibrary(backup: backup, storage: target) }
    try FileManager.default.removeItem(at: extra)
    try FileManager.default.removeItem(at: db)
    try FileManager.default.createSymbolicLink(at: db, withDestinationURL: source.profile.database)
    await #expect(throws: (any Error).self) { try await coordinator.restoreLibrary(backup: backup, storage: target) }
    #expect(try await coordinator.queue(stateRoot: target.stateRoot).map(\.id) == [old.id])
}

@Test func libraryBackupRefusesOverwriteBusyWorkerAndCancelledRestore() async throws {
    let root = try betaRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = betaStorage(root, "source"), coordinator = FixtureCoordinator()
    _ = try await betaEnqueue(storage, coordinator: coordinator, tag: "one")
    let backup = root.appendingPathComponent("library.voicerelaybackup")
    _ = try await coordinator.backupLibrary(storage: storage, destination: backup)
    await #expect(throws: (any Error).self) { try await coordinator.backupLibrary(storage: storage, destination: backup) }
    let lease = try PipelineLease(database: storage.profile.database)
    await #expect(throws: (any Error).self) { try await coordinator.backupLibrary(storage: storage, destination: root.appendingPathComponent("other")) }
    lease.release()
    let target = betaStorage(root, "target")
    let task = Task { try Task.checkCancellation(); return try await coordinator.restoreLibrary(backup: backup, storage: target) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: target.stateRoot.path))
}

@Test func libraryRestoreReReadiesRunningRowsPreservesFailuresAndDropsScratchReferences() async throws {
    let root = try betaRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let source = betaStorage(root, "source"), target = betaStorage(root, "target"), coordinator = FixtureCoordinator()
    var running = try await betaEnqueue(source, coordinator: coordinator, tag: "running")
    var failed = try await betaEnqueue(source, coordinator: coordinator, tag: "failed")
    do {
        let store = try NativeStore(url: source.profile.database)
        running.state = .running; failed.state = .failed; failed.lastError = "Synthetic failure"
        try store.saveQueueItem(running); try store.saveQueueItem(failed)
    }
    let backup = root.appendingPathComponent("library.voicerelaybackup")
    _ = try await coordinator.backupLibrary(storage: source, destination: backup)
    _ = try await coordinator.restoreLibrary(backup: backup, storage: target)
    let queue = try await coordinator.queue(stateRoot: target.stateRoot)
    #expect(queue.first { $0.id == running.id }?.state == .queued)
    #expect(queue.first { $0.id == failed.id }?.state == .failed)
    #expect(try NativeStore(url: target.profile.database, readOnly: true).query("SELECT COUNT(*) FROM chunks") == [["0"]])
}

@Test func bundledRuntimeStagesOutsideCheckoutWithPinnedFilesAndPreservesLegacyChoice() throws {
    let root = try betaRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let managed = root.appendingPathComponent("app-managed")
    let sources = try SpeechRuntimeSetup.bundledSources()
    try SpeechRuntimeSetup.stageSources(at: managed)
    let bootstrap = try #require(ToolRunner.locate("python3"))
    try SpeechRuntimeSetup.run(python: bootstrap, root: managed, arguments: ["paths"], timeout: 5)
    #expect(!FileManager.default.fileExists(atPath: managed.appendingPathComponent("models").path))
    #expect(!FileManager.default.fileExists(atPath: managed.appendingPathComponent(".runtime").path))
    for name in SpeechRuntimeSetup.sourceNames {
        #expect(try Files.hash(managed.appendingPathComponent("runtime/kokoro/\(name)")) == Files.hash(sources[name]!))
    }
    #expect(!FileManager.default.fileExists(atPath: managed.appendingPathComponent("models").path))
    #expect(!FileManager.default.fileExists(atPath: managed.appendingPathComponent(".runtime").path))
    try SpeechRuntimeSetup.stageSources(at: managed)
    #expect(SpeechRuntimeSetup.preferredRoot(saved: managed, legacy: root) == managed)
    #expect(SpeechRuntimeSetup.preferredRoot(saved: nil, legacy: managed) == managed)
    #expect(SpeechRuntimeSetup.prerequisites(locate: { _ in nil }).allSatisfy { !$0.ready })
    #expect(throws: (any Error).self) { try SpeechRuntimeSetup.check(at: managed) }
    let foreign = root.appendingPathComponent("foreign")
    try Files.directory(foreign); try Files.write(Data("preserve".utf8), to: foreign.appendingPathComponent("owned-by-other"))
    #expect(throws: (any Error).self) { try SpeechRuntimeSetup.stageSources(at: foreign) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: foreign.path) == ["owned-by-other"])
}

@Test func runtimeSetupCancellationStopsOwnedInstallerChildren() async throws {
    let root = try betaRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("runtime/kokoro")
    try Files.directory(folder)
    let pidFile = root.appendingPathComponent("child.pid")
    let completedFile = root.appendingPathComponent("child-completed")
    let script = """
    import os, subprocess, sys, time
    if os.getpgrp() != os.getpid():
        os.setsid()
    child = subprocess.Popen([sys.executable, '-c', 'import time, pathlib; time.sleep(0.8); pathlib.Path("\(completedFile.path)").write_text("unexpected completion")'])
    with open('../../child.pid', 'w') as f:
        f.write(str(child.pid))
    time.sleep(30)
    """
    // Absolute synthetic file path, never a user endpoint or runtime command.
    let adjusted = script.replacingOccurrences(of: "'../../child.pid'", with: "'\(pidFile.path)'")
    try Files.write(Data(adjusted.utf8), to: folder.appendingPathComponent("runtime_setup.py"))
    let python = try #require(ToolRunner.locate("python3"))
    let worker = Task.detached { try SpeechRuntimeSetup.run(python: python, root: root, arguments: [], timeout: 5) }
    let deadline = Date().addingTimeInterval(4)
    while !FileManager.default.fileExists(atPath: pidFile.path) && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(Int32(try String(contentsOf: pidFile, encoding: .utf8)) != nil)
    worker.cancel()
    await #expect(throws: CancellationError.self) { try await worker.value }
    try await Task.sleep(for: .seconds(1))
    #expect(!FileManager.default.fileExists(atPath: completedFile.path))
}
