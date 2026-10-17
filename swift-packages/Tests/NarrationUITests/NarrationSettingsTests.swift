import SwiftUI
import Testing
import NarrationCore
@testable import NarrationUI

@Test @MainActor func narrationSettingsComposeWithMissingBusyFailureAndReadyStatesWithoutOperations() {
    var calls = 0
    let statuses: [SpeechSetupStatus] = [.notInstalled, .notChecked, .ready, .cancelled, .failure("Synthetic failure")]
    for status in statuses {
        let activities: [SpeechSetupActivity?] = [nil, .installing, .checking]
        for activity in activities {
            _ = SpeechSetupControls(activity: activity, status: status, canManage: activity == nil,
                installMessage: "Synthetic model download", install: { calls += 1 }, check: { calls += 1 }, cancel: { calls += 1 }).body
        }
        _ = SpeechSetupStatusView(status: status).body
    }
    _ = ImageDescriptionSettingsSection(enabled: .constant(true), additionalHelp: "Future work only.").body
    _ = SpeechSpeedControl(speed: .constant(1.25)).body
    _ = VoiceSampleButton(playing: false) { calls += 1 }.body
    _ = NarrationOptionsControls(options: .constant(.init())).body
    _ = NarrationOptionsControls(options: .constant(.init(experimentalPDFWordJoining: true))).body
    #expect(calls == 0)
}
