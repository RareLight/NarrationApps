import AppPresentation
import NarrationUI
import Foundation
import SwiftUI
import Testing
@testable import VoiceRelayCore
@testable import VoiceRelayApp

@Test @MainActor func appTextSizePersistsAcrossWindowsAndRelaunchWithoutChangingSpeechPreferences() async throws {
    let name = "voicerelay-text-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"), stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    defaults.set(150, forKey: "interfaceTextSizePercent")
    let model = AppModel(storage: storage, defaults: defaults)
    #expect(model.textSize.percent == 150)
    let speech = model.preferences
    model.textSize = model.textSize.adjusted(by: 10)
    #expect(defaults.integer(forKey: "interfaceTextSizePercent") == 160 && model.preferences == speech)
    model.describeArticleImages = false
    let reopened = AppModel(storage: storage, defaults: defaults)
    #expect(!reopened.describeArticleImages)
    #expect(reopened.textSize == model.textSize)
    _ = TextSizeCommands(model: model).body
    _ = SettingsView(model: model).appTextSizing(model.textSize).dynamicTypeSize(.accessibility3)
    _ = WorkspaceView(model: model).appTextSizing(model.textSize)
    model.textSize = AppTextSize()
    #expect(defaults.integer(forKey: "interfaceTextSizePercent") == 100)
    let preview = AppModel(preview: true, defaults: defaults)
    preview.textSize = AppTextSize(percent: 200)
    #expect(defaults.integer(forKey: "interfaceTextSizePercent") == 100)
    await model.shutdown(); await reopened.shutdown()
}

@Test @MainActor func settingsStatusAndSampleAvailabilityPreserveProcessingAndPreferenceOwnership() async throws {
    let suite = "settings-alignment-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = ManagedSpeechStorage(audioDirectory: root.appendingPathComponent("audio"), stateRoot: root.appendingPathComponent("state"), temporaryRoot: root.appendingPathComponent("scratch"))
    let model = AppModel(storage: storage, defaults: defaults, runtimeInstalled: { _ in false })
    #expect(model.speechSetupStatus == .notInstalled)
    #expect(model.pronunciationUnavailableReason == NarrationSettingsHelp.previewModelMissing)
    model.running = true
    #expect(model.canPlayVoiceSample)
    #expect(model.pronunciationUnavailableReason == NarrationSettingsHelp.previewBusy)
    model.preferences = SpeechPreferences(voice: .emma, speed: 1.137)
    model.textSize = AppTextSize(percent: 180)
    model.describeArticleImages = false
    let saved = try JSONDecoder().decode(SpeechPreferences.self, from: #require(defaults.data(forKey: "speechPreferences")))
    #expect(saved.voice == .emma && saved.speed == 1.137)
    #expect(defaults.integer(forKey: "interfaceTextSizePercent") == 180)
    #expect(defaults.bool(forKey: "describeArticleImages") == false)
    model.running = false
    model.runtimeTestResult = .failure("Synthetic setup failure")
    model.runtimeVerificationFailed = true
    #expect(model.speechSetupStatus == .failure("Synthetic setup failure"))
    #expect(model.pronunciationUnavailableReason == NarrationSettingsHelp.previewCheckNeeded)
    await model.shutdown()
    #expect(!model.canPlayVoiceSample)
}
