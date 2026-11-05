import Foundation
import Darwin
import ProcessingPipeline
import AudioOutput

/// Receipt for one owned, closed WAV. It contains no PCM or serialized job state.
/// Validation and SQLite writer acquisition happen before the final commit fence.
final class SpeechCheckpointReceipt: @unchecked Sendable {
    private enum State { case pending, committed, rejected, uncertain, discarded }
    private let lock = NSLock()
    private let job: SpeechWorkJob
    private let receipt: SpeechUnitReceipt
    private let file: URL
    private let device: dev_t
    private let inode: ino_t
    private var state: State = .pending
    private var delivered = false
    private let afterCommit: @Sendable () -> Void
    init(job: SpeechWorkJob, receipt: SpeechUnitReceipt, file: URL, afterCommit: @escaping @Sendable () -> Void = {}) throws {
        self.job = job; self.receipt = receipt; self.file = file
        self.afterCommit = afterCommit
        var info = stat()
        guard file.standardizedFileURL == file.resolvingSymlinksInPath().standardizedFileURL,
              lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else { throw RelayError.artifact("Generated checkpoint file ownership is invalid.") }
        device = info.st_dev; inode = info.st_ino
    }
    /// Optional review retention runs after SQLite writer release, outside the
    /// admission/epoch fences. A rejected attempt never reaches retained review.
    func didCommit() {
        let deliver = lock.withLock {
            guard state == .committed, !delivered else { return false }
            delivered = true; return true
        }
        if deliver { afterCommit() }
    }
    func isCurrent() throws -> Bool {
        try lock.withLock {
            guard state == .pending else { return false }
            return try job.checkpointIsCurrent(receipt)
        }
    }
    func commit(index: Int, _ operation: () throws -> Void) throws -> Bool {
        try lock.withLock {
            guard state == .pending else { return false }
            do {
                let accepted = try job.commit(receipt, index: index, operation: operation)
                state = accepted ? .committed : .rejected
                return accepted
            } catch {
                // A throwing durable transaction is retained for inspection;
                // cleanup must never assume that it could not have committed.
                state = .uncertain; throw error
            }
        }
    }
    /// Call only after the writer/validation has joined. Preserve committed,
    /// uncertain or replaced files, including files now owned by another attempt.
    func discard() {
        lock.withLock {
            guard state == .pending || state == .rejected else { return }
            state = .discarded; job.discardResult(receipt)
            var current = stat()
            guard file.standardizedFileURL == file.resolvingSymlinksInPath().standardizedFileURL,
                  lstat(file.path, &current) == 0, current.st_mode & S_IFMT == S_IFREG,
                  current.st_uid == getuid(), current.st_nlink == 1,
                  current.st_dev == device, current.st_ino == inode else { return }
            _ = unlink(file.path)
        }
    }
}

/// Automatic rollback, never a failed article or a terminal backend cancellation.
struct SpeechCheckpointSuspension: AudioWorkInterruption, Sendable { let index: Int }
