import AppPresentation
import SwiftUI

/// Shared first-launch presentation. Apps retain installation, cancellation and window ownership.
/// Building this view never checks storage, downloads a model or changes preferences.
public struct SpeechSetupOnboardingView: View {
    public static let windowTitle = "Model Setup"
    private let activity: SpeechSetupActivity?
    private let canInstall: Bool
    private let install: () -> Void
    private let cancel: () -> Void
    private let notNow: () -> Void
    private let chooseFolder: () -> Void
    private let check: () -> Void
    private let status: SpeechSetupStatus
    @Environment(\.appTextSize) private var textSize
    @Environment(\.dynamicTypeSize) private var dynamicType

    public init(status: SpeechSetupStatus, activity: SpeechSetupActivity?,
                canInstall: Bool,
                install: @escaping () -> Void, check: @escaping () -> Void,
                chooseFolder: @escaping () -> Void, cancel: @escaping () -> Void, notNow: @escaping () -> Void) {
        self.activity = activity; self.canInstall = canInstall
        self.install = install; self.cancel = cancel; self.notNow = notNow
        self.status = status; self.chooseFolder = chooseFolder; self.check = check
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Set up local speech", systemImage: "waveform.circle").appFont(.headline)
            Text("Download once. Generate speech locally on your Mac.")
                .fixedSize(horizontal: false, vertical: true)
            if let activity {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(activity == .installing ? "Installing model…" : "Checking model…")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if activity == nil, status != .notInstalled {
                SpeechSetupStatusView(status: status)
            }
            HStack(spacing: 8) {
                Button("Choose Custom Model Folder…", action: chooseFolder)
                    .disabled(!canInstall || activity != nil)
                Spacer()
                if activity != nil {
                    Button("Cancel", action: cancel)
                } else {
                    Button("Not Now", action: notNow).keyboardShortcut(.cancelAction)
                    Button(status == .notChecked ? "Check Model" : "Install Model", action: status == .notChecked ? check : install)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(!canInstall)
                        .help(status == .notChecked ? "Verify the installed model offline" : "Download the selected model; internet required")
                }
            }
        }
        .padding(20)
        .frame(width: 460 * max(1, AppTypography.scale(size: textSize, dynamic: dynamicType)))
        .onChange(of: status) { _, status in if status == .ready { notNow() } }
    }
}

#if DEBUG
#Preview("Speech setup — missing model") {
    SpeechSetupOnboardingView(status: .notInstalled,
        activity: nil, canInstall: true, install: {}, check: {}, chooseFolder: {}, cancel: {}, notNow: {})
}
#Preview("Speech setup — installation, large text") {
    SpeechSetupOnboardingView(status: .notInstalled,
        activity: .installing, canInstall: false, install: {}, check: {}, chooseFolder: {}, cancel: {}, notNow: {})
    .appTextSizing(AppTextSize(percent: 200))
}
#endif
