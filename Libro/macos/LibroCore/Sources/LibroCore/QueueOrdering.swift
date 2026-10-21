import Foundation
import CoreTransferable
import UniformTypeIdentifiers

public struct QueueRowDrag: Codable, Transferable, Sendable {
    public let queue: UUID
    public let ids: [UUID]
    public init(queue: UUID, ids: [UUID]) { self.queue = queue; self.ids = ids }
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "app.libro.queue-rows", conformingTo: .data))
    }
}

public enum QueueOrdering {
    /// SwiftUI supplies an insertion index in the original collection. Preserve
    /// the relative order of a discontiguous selection when removing it first.
    public static func moving(_ order: [UUID], ids: Set<UUID>, to index: Int,
                              active: [UUID] = [], pending: Set<UUID> = []) -> [UUID]? {
        guard (0...order.count).contains(index), !ids.isEmpty, ids.isSubset(of: Set(order)) else { return nil }
        let moved = order.filter { ids.contains($0) }
        let insertion = index - order.prefix(index).filter { ids.contains($0) }.count
        var rest = order.filter { !ids.contains($0) }
        rest.insert(contentsOf: moved, at: insertion)
        if !active.isEmpty {
            guard Array(order.prefix(active.count)) == active, pending.isSubset(of: Set(active)) else { return nil }
            if ids.isSubset(of: pending) {
                guard rest.enumerated().allSatisfy({ pending.contains($0.element) || order[$0.offset] == $0.element }) else { return nil }
            } else {
                guard ids.isDisjoint(with: Set(active)), Array(rest.prefix(active.count)) == active else { return nil }
            }
        }
        return rest
    }
    public static func retainingOrder(_ previous: [UUID], discovered: [UUID]) -> [UUID] {
        let available = Set(discovered), old = Set(previous)
        return previous.filter { available.contains($0) } + discovered.filter { !old.contains($0) }
    }
}
