import Foundation
import Darwin

private func retentionPathIsSafe(_ file: URL, folder: URL) -> Bool {
    // Inspect the captured folder itself and its child, allowing macOS's /var and /tmp aliases.
    var info = stat()
    return lstat(folder.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
        && !Files.hasSymlink(file, below: folder)
}

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

public enum AudioRetention: String, Codable, CaseIterable, Sendable, Identifiable {
    case twelveHours, oneDay, threeDays, oneWeek, twoWeeks, oneMonth
    case twoMonths, threeMonths, sixMonths, never
    public var id: String { rawValue }
    public static let defaultValue: Self = .oneMonth
    public var label: String {
        switch self {
        case .twelveHours: "12 hours"
        case .oneDay: "1 day"
        case .threeDays: "3 days"
        case .oneWeek: "1 week"
        case .twoWeeks: "2 weeks"
        case .oneMonth: "1 month"
        case .twoMonths: "2 months"
        case .threeMonths: "3 months"
        case .sixMonths: "6 months"
        case .never: "Never"
        }
    }
    public func cutoff(before now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .twelveHours: now.addingTimeInterval(-12 * 3600)
        case .oneDay: now.addingTimeInterval(-24 * 3600)
        case .threeDays: now.addingTimeInterval(-3 * 24 * 3600)
        case .oneWeek: now.addingTimeInterval(-7 * 24 * 3600)
        case .twoWeeks: now.addingTimeInterval(-14 * 24 * 3600)
        case .oneMonth: calendar.date(byAdding: .month, value: -1, to: now)
        case .twoMonths: calendar.date(byAdding: .month, value: -2, to: now)
        case .threeMonths: calendar.date(byAdding: .month, value: -3, to: now)
        case .sixMonths: calendar.date(byAdding: .month, value: -6, to: now)
        case .never: nil
        }
    }
}

extension FixtureCoordinator {
    public func savedAudio(storage: ManagedSpeechStorage) throws -> [Episode] {
        try library(storage: storage).filter {
            ($0.stage == .published || ($0.stage == .expired && $0.manualAudioDeletionRequested == true))
                && $0.audioHash != nil && $0.info != nil && audioAvailability($0) == .available
        }
    }
    public func reconcileMissingAudio(storage: ManagedSpeechStorage) throws -> [String] {
        try Task.checkCancellation()
        let episodes = try library(storage: storage)
        guard !episodes.isEmpty else { return [] }
        let store = try NativeStore(url: storage.profile.database)
        var changed: [Episode] = []
        for var episode in episodes where episode.stage == .published {
            guard audioAvailability(episode) == .missing else { continue }
            episode.stage = .expired
            changed.append(episode)
        }
        let pending = try store.query("SELECT pending FROM feed_status WHERE singleton=1").first?.first == "1"
        guard !changed.isEmpty || pending else { return [] }
        if !changed.isEmpty { try retireEpisodes(changed, store: store) }
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
            throw RelayError.storage("The local feed could not be written; pending repair is retained. Reopen Saved Audio to retry.")
        }
        return changed.map(\.id)
    }
    /// Only native-library media is eligible. Age comes exclusively from the filesystem;
    /// EXPIRED records retirement intent so a crash cannot leave a missing PUBLISHED enclosure.
    public func expireAudio(storage: ManagedSpeechStorage, retention: AudioRetention,
                            now: Date = Date(), calendar: Calendar = .current) throws -> [String] {
        try Task.checkCancellation()
        _ = try reconcileMissingAudio(storage: storage)
        var episodes = try library(storage: storage)
        guard !episodes.isEmpty else { return [] }
        let cutoff = retention.cutoff(before: now, calendar: calendar)
        let store = try NativeStore(url: storage.profile.database)
        let protected = Set(try store.queue().map(\.id))
        var deleting: [Episode] = [], changed: [Episode] = []
        let fm = FileManager.default
        for index in episodes.indices {
            try Task.checkCancellation()
            var episode = episodes[index]
            guard episode.manualAudioDeletionRequested != true else { continue }
            guard episode.stage == .published || episode.stage == .expired else { continue }
            if episode.stage == .published && (cutoff == nil || protected.contains(episode.id)) { continue }
            let file = episode.settings.audio.appendingPathComponent(episode.id + ".m4a")
            // A disconnected volume is not evidence that its contents were deleted.
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: episode.settings.audio.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            guard retentionPathIsSafe(file, folder: episode.settings.audio) else {
                throw RelayError.setup("Audio cleanup refused a linked storage path. Restore the original audio folder.")
            }
            guard fm.fileExists(atPath: file.path) else { continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values.isRegularFile == true, let modified = values.contentModificationDate else {
                throw RelayError.artifact("Audio cleanup requires a regular file with a modification date.")
            }
            let eligible = cutoff.map { modified <= $0 } == true && !protected.contains(episode.id)
            guard eligible || episode.stage == .expired else { continue }
            guard let hash = episode.audioHash, try Files.hash(file, description: "audio awaiting expiry") == hash else {
                throw RelayError.artifact("Audio awaiting expiry has changed. Cleanup left it in place.")
            }
            if eligible {
                deleting.append(episode)
                if episode.stage != .expired { episode.stage = .expired; changed.append(episode) }
            } else {
                // A longer policy/Never, or newly queued work, can cancel an unfinished retirement.
                episode.stage = .published; changed.append(episode)
            }
            episodes[index] = episode
        }
        // Reconcile a prior crash after intent/feed commit but before unlink, including absent files.
        let pending = try store.query("SELECT pending FROM feed_status WHERE singleton=1").first?.first == "1"
        guard !changed.isEmpty || !deleting.isEmpty || (pending && episodes.contains(where: { $0.stage == .expired })) else { return [] }
        let settings = episodes.first(where: { $0.stage == .published })?.settings ?? episodes[0].settings
        let feed = try RSS.render(episodes.filter { $0.stage == .published }, settings: settings)
        try Task.checkCancellation()
        try retireEpisodes(changed, store: store)
        // Remove enclosures before deleting media. Durable EXPIRED intent permits safe retries.
        try writeLocalFeed(feed, to: settings.feed)
        var removed: [String] = []
        for episode in deleting {
            try Task.checkCancellation()
            let file = episode.settings.audio.appendingPathComponent(episode.id + ".m4a")
            // Recheck immediately before removal; a replacement/linked file is never ours to delete.
            guard retentionPathIsSafe(file, folder: episode.settings.audio),
                  try Files.hash(file, description: "audio awaiting expiry") == episode.audioHash,
                  let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  cutoff.map({ modified <= $0 }) == true else {
                throw RelayError.artifact("Audio changed during cleanup. It was left in place; reopen Saved Audio to reconcile.")
            }
            try fm.removeItem(at: file); removed.append(episode.id)
        }
        try store.markFeed(Files.hash(feed))
        return removed
    }
    private func retireEpisodes(_ episodes: [Episode], store: NativeStore) throws {
        try store.execute("BEGIN IMMEDIATE")
        do {
            for episode in episodes {
                try store.execute("UPDATE episodes SET record=? WHERE id=?",
                    [String(decoding: try Files.json(episode), as: UTF8.self), episode.id])
            }
            try store.execute("UPDATE feed_status SET pending=1 WHERE singleton=1")
            try store.execute("COMMIT")
        } catch { try? store.execute("ROLLBACK"); throw error }
    }
    private func writeLocalFeed(_ feed: Data, to destination: URL) throws {
        do {
            if (try? Data(contentsOf: destination)) != feed { try Files.write(feed, to: destination) }
        } catch let error as RelayError { throw error }
        catch { throw RelayError.storage("The local feed could not be written; pending repair is retained. Reopen Saved Audio to retry.") }
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
                throw RelayError.artifact("Audio changed during removal. It was left in place; reopen Saved Audio to reconcile.")
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
            throw RelayError.artifact("Audio changed during removal. It was left in place; reopen Saved Audio to reconcile.")
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
            throw RelayError.setup("A selected item is no longer in the saved library. Reopen Saved Audio and try again.")
        }
        var files: [String: (file: URL, identity: stat)] = [:]
        for episode in targets {
            guard episode.stage == .published || (episode.stage == .expired && episode.manualAudioDeletionRequested == true),
                  let info = episode.info, info.byteLength > 0, episode.audioHash != nil else {
                throw RelayError.artifact("A selected item is not finalized saved audio. Reopen Saved Audio and try again.")
            }
            let file = episode.settings.audio.appendingPathComponent(episode.id + ".m4a")
            switch audioAvailability(episode) {
            case .missing: continue
            case .unavailable:
                throw RelayError.setup("The audio folder for a selected item is unavailable. Reconnect its storage; nothing was deleted.")
            case .available:
                files[episode.id] = (file: file, identity: try verifiedAudioIdentity(file: file, episode: episode))
            }
        }
        var intent = targets
        for index in intent.indices {
            intent[index].stage = .expired
            intent[index].manualAudioDeletionRequested = true
        }
        try retireEpisodes(intent, store: store)
        let settings = episodes.first(where: { $0.stage == .published && !targetIDs.contains($0.id) })?.settings
            ?? episodes[0].settings
        let feed = try RSS.render(episodes.filter { $0.stage == .published && !targetIDs.contains($0.id) }, settings: settings)
        try writeLocalFeed(feed, to: storage.profile.feed)
        let fm = FileManager.default
        var finalized: [Episode] = [], removed: [String] = []
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
                throw RelayError.setup("A pending audio removal record is invalid. Nothing was changed; reopen Saved Audio after reconciling it.")
            }
        }
        let store = try NativeStore(url: storage.profile.database)
        let remaining = current.filter { $0.stage == .published }
        let feed = try RSS.render(remaining, settings: remaining.first?.settings ?? current[0].settings)
        try writeLocalFeed(feed, to: storage.profile.feed)
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
