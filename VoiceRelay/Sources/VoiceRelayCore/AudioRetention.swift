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
        try releaseTemporaryAudio(storage: storage, settings: settings, continueOnFailure: false)
    }
    /// Publishing isolates cleanup failures per item, retaining diagnostics without blocking the drain.
    func releaseTemporaryAudio(storage: ManagedSpeechStorage, settings: DeliverySettings, continueOnFailure: Bool,
                               debugLog: DeliveryDebugLog? = nil) throws {
        guard storage.temporaryAudio, FileManager.default.fileExists(atPath: storage.profile.database.path) else { return }
        let episodes = try library(storage: storage)
        let settings = try settings.normalized()
        let summary = try deliverySummary(stateRoot: storage.stateRoot, settings: settings)
        let store = try NativeStore(url: storage.profile.database)
        for var episode in episodes where episode.stage == .published {
            guard episode.localAudioDiscarded != true else { continue }
            guard episode.audioFinalizationComplete != false,
                  episode.settings.temporaryAudio != true || episode.audioFinalizationComplete == true,
                  summary.publicationStates[episode.id] == .published else { continue }
            // A temporary output folder from another session is never silently adopted.
            if episode.settings.temporaryAudio == true && !Files.samePath(episode.settings.audio, storage.audioDirectory) { continue }
            try Task.checkCancellation()
            do {
                let file = episode.settings.audio.appendingPathComponent(episode.id + ".m4a")
                if temporaryAudioIsMissing(episode) || audioAvailability(episode) == .missing {
                    if episode.localAudioReleased != true || episode.localCleanupNotice != nil {
                        episode.localAudioReleased = true; episode.localCleanupNotice = nil; try store.save(episode)
                    }
                    continue
                }
                guard audioAvailability(episode) == .available else {
                    throw RelayError.storage("Published audio could not be cleaned up; its server copy and history are preserved.")
                }
                // A server winner may release a replaced/altered local artifact without
                // authorizing its deletion. Retain it; crash cleanup still retries matching bytes.
                if episode.localAudioReleased == true, (try? Files.hash(file)) != episode.audioHash {
                    if !continueOnFailure { continue }
                    throw RelayError.artifact("The server copy is verified, but the local file differs. The local file was retained.")
                }
                let identity = try verifiedAudioIdentity(file: file, episode: episode)
                episode.localAudioReleased = true
                try store.save(episode)
                try deleteOwnedAudio(episode, known: (file, identity), fm: .default)
                if episode.localCleanupNotice != nil { episode.localCleanupNotice = nil; try store.save(episode) }
            } catch is CancellationError { throw CancellationError() }
            catch {
                if !continueOnFailure { throw error }
                episode.localCleanupNotice = "The server copy is confirmed, but the local file could not be safely verified for cleanup. Nothing was deleted; review this item in Uploads."
                try store.save(episode)
                debugLog?.record(.localCleanupFailed)
            }
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
    /// Explicitly discard one tracked local upload, leaving server membership and text intact.
    /// Unlike automatic cleanup, this authorizes changed bytes in this library's temporary folder.
    public func discardLocalUpload(id: String, storage: ManagedSpeechStorage) throws {
        try Task.checkCancellation()
        try storage.validateState()
        let lease = try PipelineLease(database: storage.profile.database)
        defer { lease.release() }
        guard var episode = try library(storage: storage).first(where: { $0.id == id }),
              episode.stage == .published, episode.manualAudioDeletionRequested != true,
              episode.info != nil, episode.audioHash != nil else {
            throw RelayError.setup("This local upload is no longer available. Reopen Uploads and try again.")
        }
        let store = try NativeStore(url: storage.profile.database)
        let file = episode.settings.audio.appendingPathComponent(episode.id + ".m4a")
        episode.localAudioDiscarded = true
        episode.localCleanupNotice = "Local removal could not finish safely. Nothing else was removed; retry this item's × in Uploads."
        try store.execute("BEGIN IMMEDIATE")
        do {
            try store.execute("UPDATE episodes SET record=? WHERE id=?",
                [String(decoding: try Files.json(episode), as: UTF8.self), id])
            // A preexisting interrupted/ready job must not recreate explicitly discarded bytes.
            try store.execute("DELETE FROM speech_queue WHERE article_id=?", [id])
            try store.execute("COMMIT")
        } catch { try? store.execute("ROLLBACK"); throw error }
        do {
            if !temporaryAudioIsMissing(episode) {
                guard !Files.hasSymlink(file, below: episode.settings.audio.deletingLastPathComponent()),
                      audioAvailability(episode) != .unavailable else {
                    throw RelayError.artifact("Local storage changed or is unavailable. The file was left in place; retry its × in Uploads.")
                }
                if audioAvailability(episode) == .available {
                    var removal = episode
                    if storage.temporaryAudio && episode.settings.temporaryAudio == true
                        && Files.samePath(episode.settings.audio, storage.audioDirectory) {
                        var captured = stat()
                        guard lstat(file.path, &captured) == 0, (captured.st_mode & S_IFMT) == S_IFREG else {
                            throw RelayError.artifact("The local file changed; nothing was deleted.")
                        }
                        // Only the removal snapshot uses these bytes; never rewrite the server proof.
                        removal.audioHash = try Files.hash(file, description: "local upload awaiting removal")
                        let info = episode.info!
                        removal.info = AudioInfo(duration: info.duration, byteLength: Int64(captured.st_size),
                            sampleRate: info.sampleRate, channels: info.channels, codec: info.codec)
                        try Task.checkCancellation()
                        try deleteOwnedAudio(removal, known: (file, captured), fm: .default)
                    } else {
                        // Legacy storage retains its stricter original-byte ownership check.
                        try Task.checkCancellation()
                        try deleteOwnedAudio(removal, known: nil, fm: .default)
                    }
                }
            }
            episode.localAudioReleased = true; episode.localCleanupNotice = nil
            try store.save(episode)
        } catch is CancellationError { throw CancellationError() }
        catch { throw error } // Persisted item notice remains; unrelated work can continue.
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
                episode.localCleanupNotice = nil
                finalized.append(episode)
            } catch is CancellationError { throw CancellationError() }
            catch {
                episode.localCleanupNotice = "The local file could not be safely removed. Nothing was deleted; other removals continue."
                try store.save(episode)
                if firstError == nil { firstError = error }
            }
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
