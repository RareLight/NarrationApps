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
    private let repair: () -> Void
    private let status: SpeechSetupStatus
    @Environment(\.appTextSize) private var textSize
    @Environment(\.dynamicTypeSize) private var dynamicType

    public init(status: SpeechSetupStatus, activity: SpeechSetupActivity?,
                canInstall: Bool,
                install: @escaping () -> Void, repair: @escaping () -> Void,
                chooseFolder: @escaping () -> Void, cancel: @escaping () -> Void, notNow: @escaping () -> Void) {
        self.activity = activity; self.canInstall = canInstall
        self.install = install; self.cancel = cancel; self.notNow = notNow
        self.status = status; self.chooseFolder = chooseFolder; self.repair = repair
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Set up local speech", systemImage: "waveform.circle").appFont(.headline)
            Text("Download once. Generate speech locally on your Mac.")
                .fixedSize(horizontal: false, vertical: true)
            if let activity {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(activity == .installing ? "Installing model…" : "Validating model…")
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
                if activity == .installing {
                    Button("Cancel", action: cancel)
                } else if activity != nil {
                    Button("Not Now", action: notNow).keyboardShortcut(.cancelAction)
                } else {
                    Button("Not Now", action: notNow).keyboardShortcut(.cancelAction)
                    switch status {
                    case .failure:
                        Button("Repair local model", action: repair)
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                            .disabled(!canInstall)
                            .help("Reinstall the selected model; internet required")
                    case .notInstalled, .cancelled:
                        Button("Install Model", action: install)
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                            .disabled(!canInstall)
                            .help("Download the selected model; internet required")
                    case .notChecked, .ready:
                        EmptyView()
                    }
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
        activity: nil, canInstall: true, install: {}, repair: {}, chooseFolder: {}, cancel: {}, notNow: {})
}
#Preview("Speech setup — installation, large text") {
    SpeechSetupOnboardingView(status: .notInstalled,
        activity: .installing, canInstall: false, install: {}, repair: {}, chooseFolder: {}, cancel: {}, notNow: {})
    .appTextSizing(AppTextSize(percent: 200))
}
#endif
