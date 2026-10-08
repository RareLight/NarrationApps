import Foundation
import Darwin

enum PublishedAudioAvailability { case available, missing, unavailable }

private func capturedAudioFolderStat(_ episode: Episode) -> stat? {
    guard UUID(uuidString: episode.id) != nil else { return nil }
    let folder = episode.settings.audio
    let file = folder.appendingPathComponent(episode.id + ".m4a")
    var info = stat()
    guard lstat(folder.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
          access(folder.path, R_OK | X_OK) == 0,
          !Files.hasSymlink(file, below: folder) else { return nil }
    let volume = try? folder.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey])
    if let captured = episode.audioVolumeID {
        guard volume?.volumeUUIDString == captured else { return nil }
    } else if folder.path.hasPrefix("/Volumes/") {
        let name = folder.path.split(separator: "/").dropFirst().first.map(String.init)
        guard let name, (volume?.allValues[.volumeURLKey] as? URL)?.path == "/Volumes/\(name)" else { return nil }
    }
    return info
}

func audioAvailability(_ episode: Episode, beforeMissingRecheck: (() -> Void)? = nil) -> PublishedAudioAvailability {
    guard let folder = capturedAudioFolderStat(episode) else { return .unavailable }
    let file = episode.settings.audio.appendingPathComponent(episode.id + ".m4a")
    var fileInfo = stat()
    if lstat(file.path, &fileInfo) == 0 {
        return (fileInfo.st_mode & S_IFMT) == S_IFREG && access(file.path, R_OK) == 0 ? .available : .unavailable
    }
    let firstError = errno
    guard firstError == ENOENT else { return .unavailable }
    beforeMissingRecheck?()
    guard let rechecked = capturedAudioFolderStat(episode),
          rechecked.st_dev == folder.st_dev, rechecked.st_ino == folder.st_ino else { return .unavailable }
    var secondInfo = stat()
    if lstat(file.path, &secondInfo) == 0 {
        return (secondInfo.st_mode & S_IFMT) == S_IFREG && access(file.path, R_OK) == 0 ? .available : .unavailable
    }
    return errno == ENOENT ? .missing : .unavailable
}

func temporaryAudioIsMissing(_ episode: Episode) -> Bool {
    guard episode.settings.temporaryAudio == true || episode.localAudioReleased == true else { return false }
    guard UUID(uuidString: episode.id) != nil else { return false }
    let file = episode.settings.audio.appendingPathComponent(episode.id + ".m4a")
    guard !Files.hasSymlink(file, below: episode.settings.audio.deletingLastPathComponent()) else { return false }
    var info = stat()
    return lstat(file.path, &info) != 0 && errno == ENOENT
}

extension FixtureCoordinator {
    public func savedAudio(storage: ManagedSpeechStorage) throws -> [Episode] {
        try library(storage: storage).filter {
            ($0.stage == .published || ($0.stage == .expired && ($0.manualAudioDeletionRequested == true
                    || (($0.settings.temporaryAudio == true || $0.localAudioReleased == true) && $0.delivery?.remotePath.isEmpty == false))))
                && $0.audioHash != nil && $0.info != nil
                && ($0.settings.temporaryAudio == true || $0.localAudioReleased == true
                    || $0.delivery?.status == .uploaded || audioAvailability($0) == .available)
        }
    }
    /// Release recorded native audio only after byte-confirmed upload AND feed membership.
    /// Diagnostic local-output profiles retain their files; the running app opts into cleanup.
    /// A crash between intent and unlink is retried locally on the next drain.
    public func releaseConfirmedTemporaryAudio(storage: ManagedSpeechStorage, settings: DeliverySettings) throws {
        guard storage.temporaryAudio, FileManager.default.fileExists(atPath: storage.profile.database.path) else { return }
        let episodes = try library(storage: storage)
        let settings = try settings.normalized()
        let summary = try deliverySummary(stateRoot: storage.stateRoot, settings: settings)
        let store = try NativeStore(url: storage.profile.database)
        for var episode in episodes where episode.stage == .published {
            guard episode.audioFinalizationComplete != false,
                  episode.settings.temporaryAudio != true || episode.audioFinalizationComplete == true,
                  summary.publicationStates[episode.id] == .published else { continue }
            // A temporary output folder from another session is never silently adopted.
            if episode.settings.temporaryAudio == true && !Files.samePath(episode.settings.audio, storage.audioDirectory) { continue }
            try Task.checkCancellation()
            let file = episode.settings.audio.appendingPathComponent(episode.id + ".m4a")
            if temporaryAudioIsMissing(episode) || audioAvailability(episode) == .missing {
                if episode.localAudioReleased != true { episode.localAudioReleased = true; try store.save(episode) }
                continue
            }
            guard audioAvailability(episode) == .available else {
                throw RelayError.storage("Published audio could not be cleaned up; its server copy and history are preserved.")
            }
            let identity = try verifiedAudioIdentity(file: file, episode: episode)
            episode.localAudioReleased = true
            try store.save(episode)
            try deleteOwnedAudio(episode, known: (file, identity), fm: .default)
        }
    }
    public func reconcileMissingAudio(storage: ManagedSpeechStorage) throws -> [String] {
        try Task.checkCancellation()
        let episodes = try library(storage: storage)
        guard !episodes.isEmpty else { return [] }
        let store = try NativeStore(url: storage.profile.database)
        var changed: [Episode] = []
        for var episode in episodes where episode.stage == .published
            && episode.settings.temporaryAudio != true && episode.localAudioReleased != true
            && episode.delivery?.status != .uploaded {
            guard audioAvailability(episode) == .missing else { continue }
            episode.stage = .expired
            changed.append(episode)
        }
        let pending = try store.query("SELECT pending FROM feed_status WHERE singleton=1").first?.first == "1"
        guard !changed.isEmpty || pending else { return [] }
        if !changed.isEmpty { try retireEpisodes(changed, store: store, stateRoot: storage.stateRoot) }
        let changedIDs = Set(changed.map(\.id))
        let remaining = episodes.filter { $0.stage == .published && !changedIDs.contains($0.id) }
        let settings = remaining.first?.settings ?? episodes[0].settings
        do {
            let feed = try RSS.render(remaining, settings: settings)
            try writeLocalFeed(feed, to: settings.feed)
            try store.markFeed(Files.hash(feed))
        } catch let error as RelayError {
            throw error
        } catch {
            throw RelayError.storage("The local feed could not be written; pending repair is retained. Reopen Server Audio to retry.")
        }
        return changed.map(\.id)
    }
    private func retireEpisodes(_ episodes: [Episode], store: NativeStore, stateRoot: URL) throws {
        try store.execute("BEGIN IMMEDIATE")
        do {
            for episode in episodes {
                try store.execute("UPDATE episodes SET record=? WHERE id=?",
                    [String(decoding: try Files.json(episode), as: UTF8.self), episode.id])
            }
            try store.execute("UPDATE feed_status SET pending=1 WHERE singleton=1")
            try store.execute("COMMIT")
        } catch { try? store.execute("ROLLBACK"); throw error }
        recordRemoteRetirement(episodes, stateRoot: stateRoot, store: store)
    }
    /// Retire performs no network I/O: remote intent is only recorded in the durable
    /// ledger. A ledger failure is recorded on the affected records without changing
    /// the retire result.
    private func recordRemoteRetirement(_ episodes: [Episode], stateRoot: URL, store: NativeStore) {
        let touched = episodes.filter { $0.delivery?.remotePath.isEmpty == false }
        guard !touched.isEmpty else { return }
        do {
            var ledger = try DeliveryLedger.load(stateRoot: stateRoot)
            var dirty = false
            for episode in touched {
                guard let path = episode.delivery?.remotePath, !path.isEmpty else { continue }
                if episode.stage == .expired {
                    if !ledger.pendingRemoteDeletes.contains(path) { ledger.pendingRemoteDeletes.append(path) }
                    ledger.remoteFeedPending = true
                    dirty = true
                } else if episode.stage == .published, ledger.pendingRemoteDeletes.contains(path) {
                    ledger.pendingRemoteDeletes.removeAll { $0 == path }
                    dirty = true
                }
            }
            if dirty { try ledger.save(stateRoot: stateRoot) }
        } catch {
            for var episode in touched {
                episode.delivery?.lastError = "Remote cleanup could not be recorded; it will be reconciled on a later drain."
                try? store.save(episode)
            }
        }
    }
    private func writeLocalFeed(_ feed: Data, to destination: URL) throws {
        do {
            if (try? Data(contentsOf: destination)) != feed { try Files.write(feed, to: destination) }
        } catch let error as RelayError { throw error }
        catch { throw RelayError.storage("The local feed could not be written; pending repair is retained. Reopen Server Audio to retry.") }
    }
    private func verifiedAudioIdentity(file: URL, episode: Episode) throws -> stat {
        var info = stat()
        guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              Int64(info.st_size) == episode.info?.byteLength, let hash = episode.audioHash,
              try Files.hash(file, description: "saved audio awaiting removal") == hash else {
            throw RelayError.artifact("A selected audio file changed or is not owned by this library. Nothing was deleted; the item stays listed.")
        }
        return info
    }
    private func deleteOwnedAudio(_ episode: Episode, known: (file: URL, identity: stat)?, fm: FileManager) throws {
        if temporaryAudioIsMissing(episode) { return }
        switch audioAvailability(episode) {
        case .missing: return
        case .unavailable:
            throw RelayError.setup("The audio folder for a selected item is unavailable. Reconnect its storage; nothing was deleted.")
        case .available: break
        }
        let file = episode.settings.audio.appendingPathComponent(episode.id + ".m4a")
        let identity = try verifiedAudioIdentity(file: file, episode: episode)
        if let known {
            guard Files.samePath(file, known.file), identity.st_dev == known.identity.st_dev,
                  identity.st_ino == known.identity.st_ino else {
                throw RelayError.artifact("Audio changed during removal. It was left in place; reopen Server Audio to reconcile.")
            }
        }
        beforeOwnedAudioUnlink?(file)
        var current = stat()
        guard lstat(file.path, &current) == 0, current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
              current.st_size == identity.st_size,
              current.st_mtimespec.tv_sec == identity.st_mtimespec.tv_sec,
              current.st_mtimespec.tv_nsec == identity.st_mtimespec.tv_nsec,
              current.st_ctimespec.tv_sec == identity.st_ctimespec.tv_sec,
              current.st_ctimespec.tv_nsec == identity.st_ctimespec.tv_nsec else {
            throw RelayError.artifact("Audio changed during removal. It was left in place; reopen Server Audio to reconcile.")
        }
        do { try fm.removeItem(at: file) } catch {
            throw RelayError.artifact("The audio file could not be deleted. Restore write access to the audio folder and retry the removal.")
        }
    }
    public func removeSavedAudio(ids: [String], storage: ManagedSpeechStorage) throws -> [String] {
        guard !ids.isEmpty else { return [] }
        try Task.checkCancellation()
        _ = try library(storage: storage)
        beforeAudioRemovalLease?()
        let lease = try PipelineLease(database: storage.profile.database)
        defer { lease.release() }
        let episodes = try library(storage: storage)
        let store = try NativeStore(url: storage.profile.database)
        let targetIDs = Set(ids)
        let targets = episodes.filter { targetIDs.contains($0.id) }
        guard targets.count == targetIDs.count else {
            throw RelayError.setup("A selected item is no longer in the saved library. Reopen Server Audio and try again.")
        }
        var files: [String: (file: URL, identity: stat)] = [:]
        var retired: [String] = []
        for episode in targets {
            guard episode.stage == .published || (episode.stage == .expired && (episode.manualAudioDeletionRequested != nil
                || ((episode.settings.temporaryAudio == true || episode.localAudioReleased == true) && episode.delivery?.remotePath.isEmpty == false))),
                  let info = episode.info, info.byteLength > 0, episode.audioHash != nil else {
                throw RelayError.artifact("A selected item is not finalized saved audio. Reopen Server Audio and try again.")
            }
            // false is the durable completion of local removal. Its server delete
            // may still be pending or already confirmed; either repeated request is a no-op.
            // Do not rewrite a retired record: delivery may have just cleared its remote path.
            if episode.stage == .expired && episode.manualAudioDeletionRequested == false {
                retired.append(episode.id); continue
            }
            if temporaryAudioIsMissing(episode) { continue }
            let file = episode.settings.audio.appendingPathComponent(episode.id + ".m4a")
            switch audioAvailability(episode) {
            case .missing: continue
            case .unavailable:
                throw RelayError.setup("The audio folder for a selected item is unavailable. Reconnect its storage; nothing was deleted.")
            case .available:
                files[episode.id] = (file: file, identity: try verifiedAudioIdentity(file: file, episode: episode))
            }
        }
        let retiredIDs = Set(retired)
        var intent = targets.filter { !retiredIDs.contains($0.id) }
        guard !intent.isEmpty else { return retired }
        for index in intent.indices {
            intent[index].stage = .expired
            intent[index].manualAudioDeletionRequested = true
        }
        try retireEpisodes(intent, store: store, stateRoot: storage.stateRoot)
        let settings = episodes.first(where: { $0.stage == .published && !targetIDs.contains($0.id) })?.settings
            ?? episodes[0].settings
        let feed = try RSS.render(episodes.filter { $0.stage == .published && !targetIDs.contains($0.id) }, settings: settings)
        try writeLocalFeed(feed, to: storage.profile.feed)
        let fm = FileManager.default
        var finalized: [Episode] = [], removed: [String] = retired
        for var episode in intent {
            try Task.checkCancellation()
            try deleteOwnedAudio(episode, known: files[episode.id], fm: fm)
            episode.manualAudioDeletionRequested = false
            finalized.append(episode); removed.append(episode.id)
        }
        try store.execute("BEGIN IMMEDIATE")
        do {
            for episode in finalized {
                try store.execute("UPDATE episodes SET record=? WHERE id=?",
                    [String(decoding: try Files.json(episode), as: UTF8.self), episode.id])
            }
            try store.execute("COMMIT")
        } catch { try? store.execute("ROLLBACK"); throw error }
        try store.markFeed(Files.hash(feed))
        return removed
    }
    public func resumePendingAudioRemovals(storage: ManagedSpeechStorage) throws -> [String] {
        try Task.checkCancellation()
        let episodes = try library(storage: storage)
        let flagged = episodes.filter { $0.manualAudioDeletionRequested == true }
        guard !flagged.isEmpty else { return [] }
        beforeAudioRemovalLease?()
        let lease = try PipelineLease(database: storage.profile.database)
        defer { lease.release() }
        let current = try library(storage: storage)
        let pending = current.filter { $0.manualAudioDeletionRequested == true }
        guard !pending.isEmpty else { return [] }
        for episode in pending {
            guard episode.stage == .expired, episode.audioHash != nil,
                  let info = episode.info, info.byteLength > 0, info.duration > 0 else {
                throw RelayError.setup("A pending audio removal record is invalid. Nothing was changed; reopen Server Audio after reconciling it.")
            }
        }
        let store = try NativeStore(url: storage.profile.database)
        let remaining = current.filter { $0.stage == .published }
        let feed = try RSS.render(remaining, settings: remaining.first?.settings ?? current[0].settings)
        try writeLocalFeed(feed, to: storage.profile.feed)
        // These items already left the feed; queue their remote copies for deletion again
        // so a crash before the ledger write cannot strand remote media.
        recordRemoteRetirement(pending, stateRoot: storage.stateRoot, store: store)
        let fm = FileManager.default
        var finalized: [Episode] = [], firstError: (any Error)?
        for var episode in pending {
            do {
                try Task.checkCancellation()
                try deleteOwnedAudio(episode, known: nil, fm: fm)
                episode.manualAudioDeletionRequested = false
                finalized.append(episode)
            } catch { if firstError == nil { firstError = error } }
        }
        if !finalized.isEmpty {
            try store.execute("BEGIN IMMEDIATE")
            do {
                for episode in finalized {
                    try store.execute("UPDATE episodes SET record=? WHERE id=?",
                        [String(decoding: try Files.json(episode), as: UTF8.self), episode.id])
                }
                try store.execute("COMMIT")
            } catch { try? store.execute("ROLLBACK"); throw error }
            try store.markFeed(Files.hash(feed))
        }
        if let firstError { throw firstError }
        return finalized.map(\.id)
    }
}
