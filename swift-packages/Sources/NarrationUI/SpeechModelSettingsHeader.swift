import SwiftUI
import AppPresentation
import NarrationCore

public struct SpeechModelSettingsHeader: View {
    private let status: SpeechSetupStatus
    private let validating: Bool
    private let canRepair: Bool
    private let repair: () -> Void
    private let explanation: String
    public init(status: SpeechSetupStatus, validating: Bool, canRepair: Bool,
                repair: @escaping () -> Void, explanation: String) {
        self.status = status; self.validating = validating; self.canRepair = canRepair
        self.repair = repair; self.explanation = explanation
    }
    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) {
                SettingsSectionHeader(title: "Voice Model", explanation: explanation)
                statusView
            }
            VStack(alignment: .leading, spacing: 4) {
                SettingsSectionHeader(title: "Voice Model", explanation: explanation)
                statusView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private var statusView: some View {
        if validating {
            Label("Validating…", systemImage: "clock").appFont(.secondary).foregroundStyle(.secondary)
        } else {
            switch status {
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill").appFont(.secondary).foregroundStyle(.green)
            case .failure(let message):
                Button(action: repair) { Label("Repair local model", systemImage: "wrench.and.screwdriver") }
                    .appFont(.secondary).disabled(!canRepair).help(message)
                    .accessibilityHint(message)
            case .notInstalled, .notChecked, .cancelled:
                EmptyView()
            }
        }
    }
}
