import Foundation
import Darwin

// VS00 only: deliberately unreachable from app targets. Both fixture clients and
// their helpers use this protocol. No default path can touch the production lease.
enum ProofRank: Int, Codable { case api, libro, podcast }
enum ProofDelivery: String, Codable { case streaming, file }
struct ProofDemand: Codable, Equatable {
    let id: String
    let app: String
    let rank: ProofRank
    let delivery: ProofDelivery
    let order: Int
}

final class ProofLock {
    let fd: Int32
    init(_ url: URL, exclusive: Bool = false) throws {
        fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProofError.invalid }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_mode & 0o077 == 0 else { close(fd); throw ProofError.invalid }
        if exclusive && flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); throw ProofError.busy }
    }
    func tryLock() throws -> Bool {
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
        guard errno == EWOULDBLOCK else { throw ProofError.invalid }
        return false
    }
    func unlock() { _ = flock(fd, LOCK_UN) }
    deinit { close(fd) }
}
enum ProofError: Error { case invalid, busy, timeout }

final class ProofTicket {
    let demand: ProofDemand
    let lock: ProofLock
    let url: URL
    init(_ demand: ProofDemand, lock: ProofLock, url: URL) {
        self.demand = demand; self.lock = lock; self.url = url
    }
    deinit { _ = unlink(url.path); withExtendedLifetime(lock) {} }
}

struct ProofAdmission {
    let root: URL
    // Registration, rank/FIFO recheck and helper residency acquisition share one
    // gate. A client-side grant alone is insufficient to launch a helper.
    func gated<T>(_ operation: () throws -> T) throws -> T {
        let gate = try ProofLock(root.appendingPathComponent("admission"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(try gate.tryLock()) {
            guard ContinuousClock.now < deadline else { throw ProofError.timeout }
            Thread.sleep(forTimeInterval: 0.001)
        }
        defer { gate.unlock() }
        return try operation()
    }
    func register(id: String, app: String, rank: ProofRank, delivery: ProofDelivery) throws -> ProofTicket {
        try gated {
            let sequence = root.appendingPathComponent("sequence")
            let order = (Int((try? String(contentsOf: sequence, encoding: .utf8)) ?? "0") ?? 0) + 1
            try Data(String(order).utf8).write(to: sequence, options: .atomic)
            let demand = ProofDemand(id: id, app: app, rank: rank, delivery: delivery, order: order)
            let url = root.appendingPathComponent("ticket-\(order)")
            let lock = try ProofLock(url, exclusive: true)
            try FileHandle(fileDescriptor: lock.fd, closeOnDealloc: false).write(contentsOf: JSONEncoder().encode(demand))
            return ProofTicket(demand, lock: lock, url: url)
        }
    }
    // Caller holds gate; kernel ticket liveness, never timestamps/PIDs, is authority.
    func highestLocked() throws -> ProofDemand? {
        var live: [ProofDemand] = []
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix("ticket-") {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let lock = try ProofLock(url)
            if try lock.tryLock() { _ = unlink(url.path) }
            else { live.append(try JSONDecoder().decode(ProofDemand.self, from: Data(contentsOf: url))) }
        }
        return live.min { ($0.rank.rawValue, $0.order) < ($1.rank.rawValue, $1.order) }
    }
    func highest() throws -> ProofDemand? { try gated { try highestLocked() } }
    func acquireResidency(for id: String) throws -> ProofLock? {
        try gated {
            guard try highestLocked()?.id == id else { return nil }
            let lock = try ProofLock(root.appendingPathComponent("residency"))
            return try lock.tryLock() ? lock : nil
        }
    }
}
