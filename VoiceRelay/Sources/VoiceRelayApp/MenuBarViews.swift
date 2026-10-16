import AppPresentation
import SwiftUI
import AppKit
import Observation
import VoiceRelayCore

struct RelayMenu: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.appTextSize) private var textSize
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var popoverWindow = MenuPopoverWindowReference()
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            let health = model.appHealth
            if let section = health.settingsSection {
                Button { showSettings(section) } label: {
                    Label(health.title, systemImage: health.symbol)
                }.buttonStyle(PopoverMenuButtonStyle(foreground: health.symbol == "xmark.circle.fill" ? .red : .primary))
                    .disabled(model.preview || model.stopping)
            } else {
                Label(health.title, systemImage: health.symbol)
                    .foregroundStyle(health == .ready ? Color.green : Color.secondary)
                    .padding(8)
            }
            if model.syncBusy {
                SyncMenuProgress(model: model)
            } else {
                item("Sync Now") { model.syncNow() }.disabled(!model.canSyncNow)
            }
            Divider()
            VStack(spacing: 1) {
                item("Articles") { model.articleScope = .all; openWorkspace(.articles) }.disabled(model.preview)
                item("Server Audio") { openWorkspace(.savedAudio) }.disabled(model.preview)
            }.buttonStyle(PopoverMenuButtonStyle(verticalPadding: 4))
            Divider()
            VStack(spacing: 1) {
                item("Settings") { showSettings(.general) }.disabled(model.preview)
                item("Quit VoiceRelay") { model.quit() }.disabled(model.preview)
            }.buttonStyle(PopoverMenuButtonStyle(verticalPadding: 4))
        }.buttonStyle(PopoverMenuButtonStyle())
            .padding(6).frame(width: 280 * max(1, AppTypography.scale(size: textSize, dynamic: dynamicType)))
            .background(MenuPopoverWindowCapture(reference: popoverWindow, inert: model.preview).frame(width: 0, height: 0))
    }
    private func item(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
    }
    private func showSettings(_ section: SettingsSection) {
        popoverWindow.dismiss()
        model.settingsSection = section
        WindowPresence.shared.prepareToOpen()
        openSettings()
    }
    private func openWorkspace(_ section: WorkspaceSection? = nil) {
        popoverWindow.dismiss()
        if let section { model.workspaceSection = section }
        WindowPresence.shared.prepareToOpen()
        openWindow(id: "articles")
    }
}

/// Keep Button's actions and keyboard/accessibility behavior, adding menu-row hover feedback.
private struct PopoverMenuButtonStyle: ButtonStyle {
    var foreground: Color = .primary
    var verticalPadding: CGFloat = 8
    func makeBody(configuration: Configuration) -> some View {
        MenuLabel(label: configuration.label, pressed: configuration.isPressed,
                  foreground: foreground, verticalPadding: verticalPadding)
    }
    private struct MenuLabel: View {
        let label: ButtonStyleConfiguration.Label
        let pressed: Bool
        let foreground: Color
        let verticalPadding: CGFloat
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            let highlighted = enabled && (hovering || pressed)
            label.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, verticalPadding)
                .foregroundStyle(highlighted ? Color(nsColor: .selectedMenuItemTextColor) : (enabled ? foreground : .secondary))
                .background(highlighted ? Color(nsColor: .selectedContentBackgroundColor) : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .onDisappear { hovering = false }
        }
    }
}

struct SyncMenuProgress: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.syncProgressLabel).appFont(.secondary)
            if let fraction = model.syncProgressFraction {
                ProgressView(value: fraction).progressViewStyle(.linear).controlSize(.small)
                    .accessibilityLabel(model.syncPhase == .generating ? "Audio generation progress" : "Current audio file upload progress")
            } else {
                ProgressView().progressViewStyle(.linear).controlSize(.small)
                    .accessibilityLabel("Sync in progress")
            }
        }.padding(8)
    }
}

@MainActor
final class VoiceRelayApplicationDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var terminationTask: Task<Void, Never>?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if terminationTask == nil {
            terminationTask = Task {
                defer { terminationTask = nil }
                await model.shutdown()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

@main @MainActor
struct VoiceRelayApp: App {
    @NSApplicationDelegateAdaptor(VoiceRelayApplicationDelegate.self) private var delegate
    @State private var model: AppModel
    init() {
        umask(0o077)
        let model = AppModel()
        _model = State(initialValue: model)
        delegate.model = model
    }
    var body: some Scene {
        Group {
            MenuBarExtra("VoiceRelay", systemImage: "waveform.circle") {
                RelayMenu(model: model).appTextSizing(model.textSize)
            }
            .menuBarExtraStyle(.window)
            Window("Set Up VoiceRelay Speech", id: "speech-setup") {
                SpeechRuntimeOnboardingView(model: model).appTextSizing(model.textSize)
                    .background(StandaloneWindowRegistration(inert: model.preview).frame(width: 0, height: 0))
            }
            .windowResizability(.contentSize)
            .defaultLaunchBehavior(model.runtimeSetupNeededAtLaunch ? .presented : .suppressed)
            .restorationBehavior(.disabled)
            Settings {

                SettingsView(model: model).appTextSizing(model.textSize).background(StandaloneWindowRegistration(inert: model.preview).frame(width: 0, height: 0))
            }
            .windowResizability(.contentMinSize)
            Window("VoiceRelay", id: "articles") {
                WorkspaceView(model: model).appTextSizing(model.textSize)
                    .background(StandaloneWindowRegistration(inert: model.preview).frame(width: 0, height: 0))
                    .frame(minWidth: 760, minHeight: 480)
            }
            .defaultSize(width: 980, height: 640)
            WindowGroup("Article Preview", for: URL.self) { $url in
                if let url {
                    let profile = model.previewProfiles[url]
                    let options = profile.map { $0.narrationOptions ?? .init() } ?? model.preferences.effectiveNarrationOptions
                    ArticlePreviewView(url: url, inert: model.preview, settings: .init(voice: model.preferences.voice.rawValue, speed: Float(model.preferences.speed)), profile: profile, options: options)
                        .id(options.versionSuffix).appTextSizing(model.textSize)
                        .background(StandaloneWindowRegistration(inert: model.preview).frame(width: 0, height: 0))
                        .frame(minWidth: 560, minHeight: 420)
                }
            }
            .defaultSize(width: 720, height: 560)
            .commands { LibraryCommands(model: model) }
            WindowGroup("VoiceRelay Help", for: AppHelpTopic.self) { $topic in
                if let topic {
                    AppHelpView(topic: topic).appTextSizing(model.textSize)
                        .background(StandaloneWindowRegistration(inert: model.preview).frame(width: 0, height: 0))
                        .frame(minWidth: 420, minHeight: 320)
                }
            }.defaultSize(width: 560, height: 500)
        }.commands { AppHelpCommands(model: model); TextSizeCommands(model: model) }
    }
}


#if DEBUG
@MainActor private func menuPreviewModel() -> AppModel {
    let model = AppModel(preview: true)
    model.sourceReview.plist = URL(fileURLWithPath: "/synthetic/Bookmarks.plist")
    model.sourceReview.lastSyncedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
    model.runtimeTestResult = .success
    model.deliverySettings.enabled = true
    model.deliverySettings.feedFolderURL = URL(string: "https://upload.example/podcast/")
    model.deliverySettings.publicFolderURL = URL(string: "https://podcast.example/")
    model.deliverySettings.username = "synthetic@example.com"
    model.deliveryConnectionVerified = true
    return model
}
#Preview("Menu — inert setup needed") { RelayMenu(model: AppModel(preview: true)) }
#Preview("Menu — inert verified Ready") { RelayMenu(model: menuPreviewModel()) }
#Preview("Menu — inert sync generation") {
    let model = menuPreviewModel()
    model.running = true; model.processingSpeech = true; model.syncBusy = true; model.syncPhase = .generating
    model.batchProgress = QueueBatchProgress(stage: .synthesizing, completedChunks: 2, totalChunks: 8, completedArticles: 0, totalArticles: 2, currentArticleIndex: 1)
    return RelayMenu(model: model)
}
#Preview("Menu — inert sync checks") {
    let model = menuPreviewModel(); model.syncBusy = true; model.syncPhase = .reconciling
    return RelayMenu(model: model)
}
#endif

#if DEBUG
#Preview("Menu — large text, inert") {
    RelayMenu(model: menuPreviewModel()).appTextSizing(AppTextSize(percent: 200))
}
#endif
