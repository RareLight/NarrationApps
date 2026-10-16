import SwiftUI
import AppPresentation
import NarrationCore

public enum SpeechSetupActivity: Equatable, Sendable { case installing, checking }
public enum SpeechSetupStatus: Equatable, Sendable {
    case notInstalled, notChecked, ready, cancelled, failure(String)
}

/// State and operations remain app-owned. No process, file or network work occurs during rendering.
public struct SpeechSetupControls: View {
    private let activity: SpeechSetupActivity?
    private let status: SpeechSetupStatus
    private let canManage: Bool
    private let canCheck: Bool
    private let disabledReason: String?
    private let installMessage: String
    private let install: () -> Void
    private let check: () -> Void
    private let cancel: () -> Void
    @State private var confirmingInstallation = false
    public init(activity: SpeechSetupActivity?, status: SpeechSetupStatus, canManage: Bool, canCheck: Bool = true, disabledReason: String? = nil,
                installMessage: String, install: @escaping () -> Void, check: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.activity = activity; self.status = status; self.canManage = canManage; self.canCheck = canCheck; self.disabledReason = disabledReason
        self.installMessage = installMessage; self.install = install; self.check = check; self.cancel = cancel
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(activity == .checking ? "Checking…" : "Check Speech Setup", action: check)
                    .disabled(!canManage || !canCheck).help(disabledReason ?? "Check the installed model offline")
                if let activity {
                    ProgressView().controlSize(.small)
                    Button(activity == .installing ? "Cancel Installation" : "Cancel Check", action: cancel)
                }
            }
            if activity == nil {
                SpeechSetupStatusView(status: status)
                if let disabledReason { Text(disabledReason).appFont(.secondary).foregroundStyle(.secondary) }
            }
            Button(activity == .installing ? "Installing…" : "Install Speech Model…") { confirmingInstallation = true }
                .disabled(!canManage).help(disabledReason ?? "Download the speech model and pronunciation assets")
        }
        .confirmationDialog("Install speech model?", isPresented: $confirmingInstallation) {
            Button("Install Speech Model", action: install)
        } message: { Text(installMessage) }
    }
}

public struct SpeechSetupStatusView: View {
    private let status: SpeechSetupStatus
    public init(status: SpeechSetupStatus) { self.status = status }
    public var body: some View {
        switch status {
        case .notInstalled: Text("Speech model not installed").foregroundStyle(.secondary)
        case .notChecked: Text("Speech setup not checked").foregroundStyle(.secondary)
        case .ready: Label("Speech setup ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .cancelled: Text("Cancelled. Check speech setup when ready.").foregroundStyle(.secondary)
        case .failure(let message): SettingsNotice(message: message)
        }
    }
}

public enum NarrationSettingsHelp {
    public static let speechSetup = "Install downloads the selected speech model and pronunciation assets. The native engine is bundled with the app; no external tools are required. Check loads the installed model offline without generating audio."
    public static let imageDescriptions = "Existing image descriptions take priority. Missing descriptions use available on-device Apple Intelligence and may contain mistakes. Turning this off keeps existing descriptions and text recognition active."
    public static let previewModelMissing = "Install the selected speech model to preview pronunciations."
    public static let previewCheckNeeded = "Check speech setup before previewing pronunciations."
    public static let previewBusy = "Wait for processing or speech setup to finish to preview pronunciations."
}

public struct ImageDescriptionSettingsSection: View {
    @Binding private var enabled: Bool
    private let additionalHelp: String
    public init(enabled: Binding<Bool>, additionalHelp: String) { _enabled = enabled; self.additionalHelp = additionalHelp }
    public var body: some View {
        Section {
            Toggle("Describe images with Apple Intelligence", isOn: $enabled)
        } header: {
            SettingsSectionHeader(title: "Narration", explanation: NarrationSettingsHelp.imageDescriptions + " " + additionalHelp)
        }
    }
}

public struct SpeechSpeedControl: View {
    @Binding private var speed: Double
    public init(speed: Binding<Double>) { _speed = speed }
    public var body: some View {
        Stepper(value: $speed, in: SpeechSpeedPolicy.range, step: SpeechSpeedPolicy.step) {
            LabeledContent("Speed") { Text("\(speed, format: .number.precision(.fractionLength(2)))×").monospacedDigit() }
        }
    }
}

public struct VoiceSampleButton: View {
    private let playing: Bool
    private let action: () -> Void
    public init(playing: Bool, action: @escaping () -> Void) { self.playing = playing; self.action = action }
    public var body: some View { Button(playing ? "Stop Sample" : "Play Sample", action: action) }
}
