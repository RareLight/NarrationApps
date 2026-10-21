import AppKit
import Carbon
import Foundation
import Testing
@testable import VoiceRelayApp
@testable import VoiceRelayCore

@MainActor
private final class FixtureLoginItemService: LoginItemService {
    var status: LoginItemStatus = .notRegistered
    var requests: [Bool] = []
    var settingsOpens = 0
    var failure = false
    var needsApproval = false
    var hold = false
    var pending: CheckedContinuation<Void, Never>?
    func setEnabled(_ enabled: Bool) async throws {
        requests.append(enabled)
        if hold { await withCheckedContinuation { pending = $0 } }
        if failure { throw CocoaError(.fileReadNoPermission) }
        status = enabled ? (needsApproval ? .requiresApproval : .enabled) : .notRegistered
    }
    func openSettings() { settingsOpens += 1 }
}

private func loginItemStorage() -> ManagedSpeechStorage {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voicerelay-login-\(UUID())")
    return ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"),
        stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
}

@Test @MainActor func loginItemDefaultsOffAndChangesOnlyWithExplicitOptIn() async {
    let service = FixtureLoginItemService(), storage = loginItemStorage()
    let model = AppModel(storage: storage, loginItemService: service)
    #expect(!model.launchAtLoginEnabled && service.requests.isEmpty)
    model.refreshLoginItemStatus()
    #expect(service.requests.isEmpty)
    model.setLaunchAtLogin(true)
    model.setLaunchAtLogin(true)
    #expect(model.loginItemBusy)
    await model.waitForLoginItemChange()
    #expect(service.requests == [true] && model.launchAtLoginEnabled)
    let relaunched = AppModel(storage: storage, loginItemService: service)
    #expect(relaunched.launchAtLoginEnabled && service.requests == [true])
    relaunched.setLaunchAtLogin(false)
    await relaunched.waitForLoginItemChange()
    #expect(!relaunched.launchAtLoginEnabled && service.requests == [true, false])
    model.refreshLoginItemStatus()
    #expect(!model.launchAtLoginEnabled && service.requests == [true, false])
    await model.shutdown(); await relaunched.shutdown()
}

@Test @MainActor func loginItemApprovalAndExternalChangesReflectOSWithoutReregistering() async {
    let service = FixtureLoginItemService()
    service.needsApproval = true
    let model = AppModel(storage: loginItemStorage(), loginItemService: service)
    model.setLaunchAtLogin(true)
    await model.waitForLoginItemChange()
    #expect(model.loginItemStatus == .requiresApproval && model.launchAtLoginEnabled)
    model.openLoginItemSettings()
    #expect(service.settingsOpens == 1)
    service.status = .enabled; model.refreshLoginItemStatus()
    #expect(model.loginItemStatus == .enabled)
    service.status = .requiresApproval; model.refreshLoginItemStatus()
    #expect(service.requests == [true]) // revoked consent is never silently restored
    model.setLaunchAtLogin(false); await model.waitForLoginItemChange()
    #expect(model.loginItemStatus == .notRegistered && service.requests == [true, false])
    await model.shutdown()
}

@Test @MainActor func loginItemFailureReadsActualStateAndPreviewNeverEnrolls() async {
    let service = FixtureLoginItemService()
    service.failure = true
    let model = AppModel(storage: loginItemStorage(), loginItemService: service)
    model.setLaunchAtLogin(true); await model.waitForLoginItemChange()
    #expect(!model.launchAtLoginEnabled && model.loginItemError != nil && !model.loginItemBusy)
    service.status = .enabled
    model.refreshLoginItemStatus()
    model.setLaunchAtLogin(false); await model.waitForLoginItemChange()
    #expect(model.launchAtLoginEnabled && model.loginItemError != nil)
    let preview = AppModel(preview: true, loginItemService: service)
    preview.setLaunchAtLogin(true); preview.openLoginItemSettings()
    #expect(!preview.canChangeLoginItem && service.requests == [true, false] && service.settingsOpens == 0)
    let inert = AppModel(storage: loginItemStorage())
    #expect(!inert.canChangeLoginItem && !inert.launchAtLoginEnabled)
    await model.shutdown(); await preview.shutdown(); await inert.shutdown()
}

@Test @MainActor func loginItemQuitJoinsOwnedChangeAndRefusesFurtherEnrollment() async {
    let service = FixtureLoginItemService()
    service.hold = true
    let model = AppModel(storage: loginItemStorage(), loginItemService: service)
    model.setLaunchAtLogin(true)
    while service.pending == nil { await Task.yield() }
    let quit = Task { await model.shutdown() }
    while !model.stopping { await Task.yield() }
    #expect(model.loginItemBusy)
    model.setLaunchAtLogin(false)
    service.pending?.resume(); service.pending = nil
    await quit.value
    #expect(!model.loginItemBusy && service.requests == [true])
    model.setLaunchAtLogin(false)
    #expect(service.requests == [true])
}

@Test func loginItemLaunchEventDistinguishesManualLaunchAndReopen() {
    func event(_ id: AEEventID, login: Bool) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: id,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if login { event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData) }
        return event
    }
    #expect(!LoginLaunchContext.isLoginItemLaunch(nil))
    #expect(!LoginLaunchContext.isLoginItemLaunch(event(kAEOpenApplication, login: false)))
    #expect(LoginLaunchContext.isLoginItemLaunch(event(kAEOpenApplication, login: true)))
    #expect(!LoginLaunchContext.isLoginItemLaunch(event(kAEReopenApplication, login: true)))
}
