import Foundation
import Darwin
import NIOCore

public struct VoiceServerConfiguration: Codable, Equatable, Sendable {
    public enum Access: String, Codable, Sendable, CaseIterable { case loopback, tailscale, otherVPN }
    public var enabled = false
    public var port = 8_080
    public var access: Access? // First enablement requires an explicit choice.
    public var addresses: [String] = []
    public var modes = VoiceServerResponseModes()
    public init() {}
    public func bindings(local: Set<String>, tailscale: VoiceServerTailscaleStatus) throws -> [VoiceServerBinding] {
        guard let access, modes.isValid else { throw VoiceServerError(503, code: "access_required", message: "Choose an access mode and at least one response mode in VoiceServer settings.") }
        var selected = ["127.0.0.1", "::1"]
        if access != .loopback {
            guard !addresses.isEmpty, Set(addresses).count == addresses.count,
                  addresses.allSatisfy({ local.contains($0) }),
                  access != .tailscale || (tailscale.connected && addresses.allSatisfy({ tailscale.addresses.contains($0) })) else {
                throw VoiceServerError(503, code: "interface_unavailable", message: "Select an available private interface address. VoiceServer does not substitute another address.")
            }
            selected += addresses.filter { !selected.contains($0) }
        }
        return try selected.map { try VoiceServerBinding(address: $0, port: port) }
    }
}

public struct VoiceServerTailscaleStatus: Sendable, Equatable {
    public let connected: Bool
    public let addresses: [String]
    public let magicDNS: String?
    public static let unavailable = Self(connected: false, addresses: [], magicDNS: nil)
    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= 262_144 else { throw VoiceServerError.failed }
        struct Node: Decodable { let TailscaleIPs: [String]?; let DNSName: String? }
        struct Status: Decodable {
            let BackendState: String?; let selfNode: Node?
            enum CodingKeys: String, CodingKey { case BackendState; case selfNode = "Self" }
        }
        let status = try JSONDecoder().decode(Status.self, from: data)
        guard status.BackendState == "Running", let node = status.selfNode else { return .unavailable }
        let addresses = (node.TailscaleIPs ?? []).filter {
            $0 != "0.0.0.0" && $0 != "::" && (try? SocketAddress(ipAddress: $0, port: 1)) != nil
        }
        let name = node.DNSName?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let dns = name.flatMap { candidate -> String? in
            guard candidate.utf8.count <= 253, candidate.contains("."),
                  candidate.split(separator: ".").allSatisfy({ label in
                      !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                      && label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
                  }) else { return nil }
            return candidate
        }
        return .init(connected: !addresses.isEmpty, addresses: Array(Set(addresses)).sorted(), magicDNS: dns)
    }
    public func baseURL(port: Int) -> URL? {
        guard connected, let magicDNS, (1...65_535).contains(port) else { return nil }
        var parts = URLComponents(); parts.scheme = "http"; parts.host = magicDNS; parts.port = port; parts.path = "/v1"
        return parts.url
    }
}

public enum VoiceServerDiscovery {
    public static func localAddresses() -> Set<String> {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }; defer { freeifaddrs(head) }
        var result = Set<String>(), entry = head
        while let current = entry {
            defer { entry = current.pointee.ifa_next }
            guard current.pointee.ifa_flags & UInt32(IFF_UP) != 0, let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            // Scoped link-local addresses need interface-specific routing. Do not
            // advertise them as a portable private API URL.
            if !name.contains("%"), name != "0.0.0.0", name != "::" { result.insert(name) }
        }
        return result
    }
    public static func tailscale() async -> VoiceServerTailscaleStatus {
        let control = VoiceServerRequestControl()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let status = (try? runTailscale(control: control)).flatMap { try? VoiceServerTailscaleStatus.parse($0) } ?? .unavailable
                    continuation.resume(returning: status)
                }
            }
        } onCancel: { control.cancel() }
    }
    private static func runTailscale(control: VoiceServerRequestControl) throws -> Data {
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw VoiceServerError.failed }
        try control.check()
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = ["status", "--json", "--peers=false"]
        var environment = ProcessInfo.processInfo.environment; environment["TAILSCALE_BE_CLI"] = "1"; process.environment = environment
        process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        let fd = output.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw VoiceServerError.failed }
        try process.run(); try? output.fileHandleForWriting.close()
        defer {
            if process.isRunning {
                process.terminate()
                let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
                while process.isRunning, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit(); try? output.fileHandleForReading.close()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            try control.check()
            guard ContinuousClock.now < deadline else { throw VoiceServerError.deadline }
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                guard bytes.count + count <= 262_144 else { throw VoiceServerError.failed }
                bytes.append(contentsOf: buffer.prefix(count))
            } else if count == 0 { break }
            else if errno == EAGAIN || errno == EWOULDBLOCK { Thread.sleep(forTimeInterval: 0.01) }
            else if errno != EINTR { throw VoiceServerError.failed }
        }
        guard !process.isRunning || ContinuousClock.now < deadline else { throw VoiceServerError.deadline }
        // EOF is not a successful exit; still bound a process that closes stdout
        // before hanging, then inspect its status after it is joined.
        while process.isRunning {
            try control.check(); guard ContinuousClock.now < deadline else { throw VoiceServerError.deadline }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw VoiceServerError.failed }
        return bytes
    }
}
