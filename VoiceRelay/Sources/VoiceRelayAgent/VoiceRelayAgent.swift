import Foundation
import Security
import Darwin
import VoiceRelayCore

private final class AgentListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = AgentXPCService(endpoint: AgentEndpoint())
    private let requirement: String
    init(requirement: String) { self.requirement = requirement }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid() else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: AgentXPCProtocol.self)
        connection.exportedObject = service
        connection.activate()
        return true
    }
}

@main struct VoiceRelayAgent {
    static func main() {
        umask(0o077)
        if CommandLine.arguments.dropFirst().elementsEqual(["--self-check"]) {
            Task { await selfCheck() }
            dispatchMain()
        }
        guard CommandLine.arguments.count == 1 else { fputs("Usage: VoiceRelayAgent [--self-check]\n", stderr); exit(64) }
        do {
            let requirement = try trustedPeerRequirement()
            let delegate = AgentListenerDelegate(requirement: requirement)
            let listener = NSXPCListener(machServiceName: AgentIdentity.machService)
            listener.delegate = delegate
            listener.activate()
            // A persistent LaunchAgent listener; the app has no enrollment/client path yet.
            withExtendedLifetime((listener, delegate)) { dispatchMain() }
        } catch {
            fputs("Agent listener unavailable: trusted app/agent signing is required. No processing started.\n", stderr)
            exit(78)
        }
    }
    private static func selfCheck() async -> Never {
        // No listener, registration, protected files, model, or persistent app state.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceRelay-agent-check-\(UUID().uuidString)")
        do {
            let request = AgentRequest(command: .snapshot)
            let response = try AgentWire.decodeResponse(await AgentEndpoint(stateRoot: root).handle(AgentWire.encode(request)), requestID: request.requestID)
            guard response.snapshot?.mode == "readOnlyFoundation", response.snapshot?.articles == 0,
                  !FileManager.default.fileExists(atPath: root.path) else { throw AgentFailure.invalidRequest }
            print("Agent contract self-check passed; no listener or persistent storage was started.")
            exit(0)
        } catch { fputs("Agent contract self-check failed.\n", stderr); exit(1) }
    }
    private static func trustedPeerRequirement() throws -> String {
        let flags = SecCSFlags(rawValue: 0)
        var current: SecCode?, code: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf(flags, &current) == errSecSuccess, let current,
              SecCodeCopyStaticCode(current, flags, &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any], let team = info[kSecCodeInfoTeamIdentifier as String] as? String else {
            throw AgentFailure.commandUnavailable
        }
        let own = try AgentIdentity.peerRequirement(team: team, agent: true)
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(own as CFString, flags, &parsed) == errSecSuccess,
              SecCodeCheckValidity(current, flags, parsed) == errSecSuccess else { throw AgentFailure.commandUnavailable }
        let peer = try AgentIdentity.peerRequirement(team: team)
        guard SecRequirementCreateWithString(peer as CFString, flags, &parsed) == errSecSuccess else { throw AgentFailure.invalidRequest }
        return peer
    }
}
