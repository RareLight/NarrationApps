import NarrationCore
import Foundation
import Darwin

/// Foundation Data.write(.atomic) can use OS replacement scratch. Native
/// inventories instead use a synchronized sibling and same-directory rename.
package enum NativeAtomicFile {
    package static func write(_ data: Data, to destination: URL, workspace: NativeWorkspace) throws {
        _ = try workspace.managed(destination)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = try workspace.managed(destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID()).tmp"))
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        try Task.checkCancellation()
        _ = try workspace.managed(destination)
        guard rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
