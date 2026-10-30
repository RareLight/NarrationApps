import SwiftUI
import AppPresentation
import NarrationCore

public struct SpeechSetupRequiredHeader: View {
    private let model: SpeechModel
    private let isPresented: Bool
    private let activity: SpeechSetupActivity?
    private let progress: ModelPreparationProgress?
    private let canDownload: Bool
    private let detail: String?
    private let download: () -> Void
    private let cancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: SpeechModel, isPresented: Bool, activity: SpeechSetupActivity?,
                progress: ModelPreparationProgress?, canDownload: Bool, detail: String? = nil,
                download: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.model = model; self.isPresented = isPresented; self.activity = activity
        self.progress = progress; self.canDownload = canDownload; self.detail = detail
        self.download = download; self.cancel = cancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isPresented {
                content
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .default, value: isPresented)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Speech Setup Required", systemImage: "gearshape").appFont(.headline)
            Text(guidance)
                .appFont(.secondary).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            progressLine
            if let detail, activity == nil {
                Text(detail).appFont(.secondary).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if activity == nil {
                    Button("Download Model", action: download).disabled(!canDownload)
                        .help("Download \(model.label); internet required")
                } else {
                    Button("Cancel", action: cancel)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(alignment: .bottom) { Divider() }
    }

    @ViewBuilder private var progressLine: some View {
        if let progress {
            VStack(alignment: .leading, spacing: 4) {
                Text(progressLabel(progress)).appFont(.secondary)
                if progress.phase == .downloading, progress.totalBytes > 0 {
                    ProgressView(value: Double(progress.completedBytes), total: Double(progress.totalBytes))
                        .progressViewStyle(.linear)
                    Text("\(ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))")
                        .appFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
        } else if let activity {
            VStack(alignment: .leading, spacing: 4) {
                Text(activity == .installing ? "Preparing \(model.label)…" : "Checking \(model.label) offline…")
                    .appFont(.secondary)
                ProgressView().progressViewStyle(.linear)
            }
        }
    }

    private var guidance: String {
        if activity == .checking { return "Checking \(model.label) speech setup offline…" }
        if detail != nil { return "\(model.label) speech setup needs attention before it can generate speech." }
        return "\(model.label) is not available in the selected model folder. Download it once to generate speech on your Mac."
    }

    private func progressLabel(_ value: ModelPreparationProgress) -> String {
        let scope = value.scope == .primary ? model.label : "English pronunciation assets"
        switch value.phase {
        case .waiting: return "Waiting for \(scope)…"
        case .checking: return "Checking \(scope)…"
        case .reusing: return "Reusing existing \(scope) files."
        case .downloading: return "Downloading \(scope)…"
        case .validating: return "Validating \(scope)…"
        case .publishing: return "Finishing \(scope) installation…"
        }
    }
}
