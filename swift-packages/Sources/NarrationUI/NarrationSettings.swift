import SwiftUI
import AppPresentation
import NarrationCore

public enum SpeechSetupActivity: Equatable, Sendable { case installing, checking }
public enum SpeechSetupStatus: Equatable, Sendable {
    case notInstalled, notChecked, ready, cancelled, failure(String)
}

public struct SpeechSetupStatusView: View {
    private let status: SpeechSetupStatus
    public init(status: SpeechSetupStatus) { self.status = status }
    public var body: some View {
        switch status {
        case .notInstalled: Text("Speech model not installed").foregroundStyle(.secondary)
        case .notChecked: Text("Speech setup is validated automatically.").foregroundStyle(.secondary)
        case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .cancelled: Text("Cancelled.").foregroundStyle(.secondary)
        case .failure(let message): SettingsNotice(message: message)
        }
    }
}

public enum NarrationSettingsHelp {
    public static let qwenDeliveryInstruction = "Describe tone or pacing, e.g. ‘calm and measured’. Leave blank for default delivery. Up to 128 characters."
    public static let speechSetup = "Download installs the selected model. Setup is validated automatically."
    public static let imageDescriptions = "Add missing descriptions with on-device Apple Intelligence. Results may contain mistakes; existing descriptions and OCR stay active."
    public static let previewModelMissing = "Install the selected speech model to preview pronunciations."
    public static let previewCheckNeeded = "Repair the speech model or wait for automatic validation to preview pronunciations."
    public static let previewBusy = "Wait for processing or speech setup to finish to preview pronunciations."
}

public struct ImageDescriptionSettingsSection: View {
    @Binding private var enabled: Bool
    private let additionalHelp: String
    private let showsExample: Bool
    public init(enabled: Binding<Bool>, additionalHelp: String, showsExample: Bool = false) {
        _enabled = enabled; self.additionalHelp = additionalHelp; self.showsExample = showsExample
    }
    public var body: some View {
        Section {
            Toggle("Describe images with Apple Intelligence", isOn: $enabled)
                .help("Describe uncaptioned images on-device.")
            if showsExample {
                DocumentTextExample(source: "Text + an uncaptioned image",
                    narration: enabled ? "Text + a generated image description" : "Text only",
                    detail: "Example assumes image descriptions are available. Generated descriptions may contain mistakes.")
            }
        } header: {
            SettingsSectionHeader(title: showsExample ? "Image descriptions" : "Narration", explanation: NarrationSettingsHelp.imageDescriptions + " " + additionalHelp)
        }
    }
}

/// Illustration only: no document, model or pronunciation work runs in Settings.
struct DocumentTextExample: View {
    let source: String
    let narration: String
    var detail: String? = nil
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Show example", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Document: \(source)").appFont(.caption).monospaced()
                Text("Narration: \(narration)").appFont(.caption).monospaced()
                if let detail { Text(detail).appFont(.caption).foregroundStyle(.secondary) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 6))
            .accessibilityElement(children: .combine)
        }
        .disclosureGroupStyle(DocumentExampleDisclosureStyle())
    }
}

private struct DocumentExampleDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    configuration.label
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .appFont(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: configuration.isExpanded)
    }
}

public struct SpeechSpeedControl: View {
    @Binding private var speed: Double
    private let showsLabel: Bool
    public init(speed: Binding<Double>, showsLabel: Bool = true) {
        _speed = speed; self.showsLabel = showsLabel
    }
    public var body: some View {
        if showsLabel {
            Stepper(value: $speed, in: SpeechSpeedPolicy.range, step: SpeechSpeedPolicy.step) {
                LabeledContent("Speed") { Text("\(speed, format: .number.precision(.fractionLength(2)))×").monospacedDigit() }
            }
        } else {
            Stepper(value: $speed, in: SpeechSpeedPolicy.range, step: SpeechSpeedPolicy.step) {
                Text("\(speed, format: .number.precision(.fractionLength(2)))×").monospacedDigit()
            }.fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Speaking speed")
        }
    }
}

public struct VoiceSampleButton: View {
    private let playing: Bool
    private let action: () -> Void
    public init(playing: Bool, action: @escaping () -> Void) { self.playing = playing; self.action = action }
    public var body: some View { Button(playing ? "Stop Sample" : "Play Sample", action: action) }
}
