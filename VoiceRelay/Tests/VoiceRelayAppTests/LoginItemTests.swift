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

@Test @MainActor func loginItemDefaultsOnOnceAndPreservesAnExplicitOptOut() async throws {
    let service = FixtureLoginItemService(), storage = loginItemStorage()
    let suite = "voicerelay-login-default-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(storage: storage, defaults: defaults, loginItemService: service)
    #expect(model.loginItemBusy)
    await model.waitForLoginItemChange()
    #expect(model.launchAtLoginEnabled && service.requests == [true])
    model.refreshLoginItemStatus()
    #expect(service.requests == [true])
    model.setLaunchAtLogin(true)
    model.setLaunchAtLogin(true)
    await model.waitForLoginItemChange()
    #expect(service.requests == [true] && model.launchAtLoginEnabled)
    let relaunched = AppModel(storage: storage, defaults: defaults, loginItemService: service)
    #expect(relaunched.launchAtLoginEnabled && service.requests == [true])
    relaunched.setLaunchAtLogin(false)
    await relaunched.waitForLoginItemChange()
    #expect(!relaunched.launchAtLoginEnabled && service.requests == [true, false])
    model.refreshLoginItemStatus()
    #expect(!model.launchAtLoginEnabled && service.requests == [true, false])
    let optedOut = AppModel(storage: storage, defaults: defaults, loginItemService: service)
    await optedOut.waitForLoginItemChange()
    #expect(!optedOut.launchAtLoginEnabled && service.requests == [true, false])
    await model.shutdown(); await relaunched.shutdown(); await optedOut.shutdown()
}

@Test @MainActor func loginItemDefaultPreservesLegacyPreferencesAndExternalRevocation() async throws {
    let suite = "voicerelay-login-legacy-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let service = FixtureLoginItemService()
    defaults.set(try JSONEncoder().encode(SpeechPreferences()), forKey: "speechPreferences")
    let legacy = AppModel(storage: loginItemStorage(), defaults: defaults, loginItemService: service)
    await legacy.waitForLoginItemChange()
    #expect(!legacy.launchAtLoginEnabled && service.requests.isEmpty)
    legacy.setLaunchAtLogin(true); await legacy.waitForLoginItemChange()
    service.status = .notRegistered // Disabled outside the app.
    let relaunched = AppModel(storage: loginItemStorage(), defaults: defaults, loginItemService: service)
    await relaunched.waitForLoginItemChange()
    #expect(!relaunched.launchAtLoginEnabled && service.requests == [true])
    await legacy.shutdown(); await relaunched.shutdown()
    defaults.removePersistentDomain(forName: suite)
    let storage = loginItemStorage(), existing = FixtureLoginItemService()
    try FileManager.default.createDirectory(at: storage.stateRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: storage.stateRoot.deletingLastPathComponent()) }
    let library = AppModel(storage: storage, defaults: defaults, loginItemService: existing)
    await library.waitForLoginItemChange()
    #expect(!library.launchAtLoginEnabled && existing.requests.isEmpty)
    await library.shutdown()
}

@Test @MainActor func loginItemDefaultNeverRetriesAFailureOrOverridesAnExistingOSDecision() async throws {
    let suite = "voicerelay-login-once-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let service = FixtureLoginItemService()
    service.failure = true
    let first = AppModel(storage: loginItemStorage(), defaults: defaults, loginItemService: service)
    await first.waitForLoginItemChange()
    #expect(first.loginItemError != nil && service.requests == [true])
    let retry = AppModel(storage: loginItemStorage(), defaults: defaults, loginItemService: service)
    await retry.waitForLoginItemChange()
    #expect(!retry.loginItemBusy && service.requests == [true])
    await first.shutdown(); await retry.shutdown()
    for status in [LoginItemStatus.enabled, .requiresApproval, .notFound] {
        defaults.removePersistentDomain(forName: suite)
        let existing = FixtureLoginItemService(); existing.status = status
        let model = AppModel(storage: loginItemStorage(), defaults: defaults, loginItemService: existing)
        await model.waitForLoginItemChange()
        #expect(model.loginItemStatus == status && existing.requests.isEmpty)
        await model.shutdown()
    }
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

@Test @MainActor func loginItemQuitJoinsDefaultEnrollmentAndRefusesFurtherChanges() async {
    let service = FixtureLoginItemService()
    service.hold = true
    let model = AppModel(storage: loginItemStorage(), loginItemService: service)
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
