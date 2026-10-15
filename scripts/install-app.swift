#!/usr/bin/swift
import Foundation
import Darwin

// Swap only staged bundles on the destination filesystem. Failure leaves the
// prior package intact; the caller removes old staging after a successful swap.
func install(staged: URL, destination: URL) throws {
    let manager = FileManager.default
    let stagedAttributes = try manager.attributesOfItem(atPath: staged.path)
    guard stagedAttributes[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileWriteInvalidFileName) }
    let parentAttributes = try manager.attributesOfItem(atPath: destination.deletingLastPathComponent().path)
    guard stagedAttributes[.systemNumber] as? NSNumber == parentAttributes[.systemNumber] as? NSNumber else { throw CocoaError(.fileWriteUnsupportedScheme) }
    let existing = try? manager.attributesOfItem(atPath: destination.path)
    if let existing {
        guard existing[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileWriteInvalidFileName) }
        guard renamex_np(staged.path, destination.path, UInt32(RENAME_SWAP)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    } else {
        // RENAME_EXCL also protects against a destination appearing after inspection.
        guard renamex_np(staged.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
guard CommandLine.arguments.count == 3 else { fputs("Usage: install-app.swift staged.app destination.app\n", stderr); exit(2) }
do {
    try install(staged: URL(fileURLWithPath: CommandLine.arguments[1]), destination: URL(fileURLWithPath: CommandLine.arguments[2]))
} catch { fputs("App package exchange failed: \(error.localizedDescription)\n", stderr); exit(1) }
