import AppPresentation
import SwiftUI
import AppKit
import Observation
import VoiceRelayCore

struct RelayMenu: View {
    @Bindable var model: AppModel
    var dismissMenu: (() -> Void)? = nil
    var sceneOpenWindow: OpenWindowAction? = nil
    var sceneOpenSettings: OpenSettingsAction? = nil
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var popoverWindow = MenuPopoverWindowReference()
    @State private var keyboardNavigation = false
    @FocusState private var focusedItem: String?
    var body: some View {
        PopoverMenuLayout {
            let health = model.appHealth
            Group {
                if let section = health.settingsSection {
                    Button { showSettings(section) } label: {
                        Label(health.title, systemImage: health.symbol)
                    }.buttonStyle(PopoverMenuButtonStyle(foreground: health.symbol == "xmark.circle.fill" ? .red : .primary))
                        .focused($focusedItem, equals: "status")
                        .disabled(model.preview || model.stopping)
                } else {
                    Label(health.title, systemImage: health.symbol)
                        .foregroundStyle(health == .ready ? Color.green : Color.secondary)
                        .padding(8)
                }
            }
            if model.syncBusy {
                SyncMenuProgress(model: model)
            } else {
                item("Sync Now") { model.syncNow() }.disabled(!model.canSyncNow)
                    .layoutValue(key: PopoverMenuLayout.WidthSource.self, value: true)
            }
            Divider()
            VStack(spacing: 1) {
                item("Articles") { model.articleScope = .all; openWorkspace(.articles) }.disabled(model.preview)
                item("Server Audio") { openWorkspace(.savedAudio) }.disabled(model.preview)
                item("Copy Podcast URL") { model.copyDeliverySubscriptionURL(); dismissPopover() }
                    .disabled(model.preview || model.deliverySubscriptionURL == nil)
            }
            .buttonStyle(PopoverMenuButtonStyle(verticalPadding: 4))
            .layoutValue(key: PopoverMenuLayout.WidthSource.self, value: true)
            Divider()
            VStack(spacing: 1) {
                item("Settings") { showSettings(.general) }.disabled(model.preview)
                item("Quit VoiceRelay") { model.quit() }.disabled(model.preview)
            }
            .buttonStyle(PopoverMenuButtonStyle(verticalPadding: 4))
            .layoutValue(key: PopoverMenuLayout.WidthSource.self, value: true)
        }.buttonStyle(PopoverMenuButtonStyle())
            // Only command labels establish width; status/progress wrap within it.
            .fixedSize().padding(PopoverMenuLayout.outerPadding)
            .focusEffectDisabled(!keyboardNavigation)
            .onKeyPress(.tab) { keyboardNavigation = true; return .ignored }
            .onChange(of: focusedItem) { _, _ in
                // AppKit may move focus for Shift-Tab before SwiftUI's key handler.
                if NSApp.currentEvent?.type == .keyDown, NSApp.currentEvent?.keyCode == 48 {
                    keyboardNavigation = true
                }
            }
            .background(MenuPopoverWindowCapture(reference: popoverWindow, inert: model.preview).frame(width: 0, height: 0))
    }
    private func item(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).focused($focusedItem, equals: title)
    }
    private func showSettings(_ section: SettingsSection) {
        dismissPopover()
        model.settingsSection = section
        WindowPresence.shared.prepareToOpen()
        (sceneOpenSettings ?? openSettings)()
    }
    private func openWorkspace(_ section: WorkspaceSection? = nil) {
        dismissPopover()
        if let section { model.workspaceSection = section }
        WindowPresence.shared.prepareToOpen()
        (sceneOpenWindow ?? openWindow)(id: "articles")
    }
    private func dismissPopover() {
        if let dismissMenu { dismissMenu() }
        else { popoverWindow.dismiss() }
    }
}

/// Measure commands first, then give status/progress that width and their full
/// wrapped height. Flexible progress and changing status must not size the popup.
struct PopoverMenuLayout: Layout {
    struct WidthSource: LayoutValueKey { static let defaultValue = false }
    static let outerPadding: CGFloat = 6
    private let spacing: CGFloat = 2
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let commandWidth = subviews.filter { $0[WidthSource.self] }
            .map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        // Expand the complete previous width (including outer padding) by 25%.
        let width = (commandWidth + 2 * Self.outerPadding) * 1.25 - 2 * Self.outerPadding
        let rowProposal = ProposedViewSize(width: width, height: nil)
        let height = subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(rowProposal).height }
        return CGSize(width: width, height: height + CGFloat(max(0, subviews.count - 1)) * spacing)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rowProposal = ProposedViewSize(width: bounds.width, height: nil)
        var y = bounds.minY
        for row in subviews {
            row.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: rowProposal)
            y += row.sizeThatFits(rowProposal).height + spacing
        }
    }
}

/// Keep live model observation and scene actions in the hosted SwiftUI content.
private struct StatusItemMenuContent: View {
    @Bindable var model: AppModel
    let openWindow: OpenWindowAction
    let openSettings: OpenSettingsAction
    let dismiss: () -> Void
    var body: some View {
        RelayMenu(model: model, dismissMenu: dismiss, sceneOpenWindow: openWindow, sceneOpenSettings: openSettings)
            .appTextSizing(model.textSize)
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
    private var menuHost: StatusItemPopoverHost?
    private var terminating = false
    func installMenu(_ content: @escaping () -> AnyView) {
        guard !terminating, model?.preview == false else { return }
        if let menuHost { menuHost.content = content; return }
        let host = StatusItemPopoverHost(content: content)
        menuHost = host
        // Scene updates never perform AppKit status-item creation during layout.
        DispatchQueue.main.async { [weak self, weak host] in
            guard self?.terminating == false else { return }
            host?.start()
        }
    }
    func dismissMenu() { menuHost?.dismiss() }
    func applicationWillFinishLaunching(_ notification: Notification) {
        captureLoginLaunch()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        captureLoginLaunch()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The native status item and background work outlive ordinary scene windows.
        false
    }
    private func captureLoginLaunch() {
        if LoginLaunchContext.isLoginItemLaunch(NSAppleEventManager.shared().currentAppleEvent) {
            model?.launchedAtLogin = true
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if terminationTask == nil {
            terminating = true
            terminationTask = Task {
                defer { terminationTask = nil }
                await model.shutdown()
                menuHost?.stop()
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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    init() {
        umask(0o077)
        let model = AppModel()
        model.launchedAtLogin = LoginLaunchContext.isLoginItemLaunch(NSAppleEventManager.shared().currentAppleEvent)
        _model = State(initialValue: model)
        delegate.model = model
    }
    var body: some Scene {
        Group {
            Window("Set Up VoiceRelay Speech", id: "speech-setup") {
                SpeechRuntimeOnboardingView(model: model).appTextSizing(model.textSize)
                    .background(StandaloneWindowRegistration(inert: model.preview).frame(width: 0, height: 0))
            }
            .windowResizability(.contentSize)
            .defaultLaunchBehavior(model.runtimeSetupNeededAtLaunch && !model.launchedAtLogin ? .presented : .suppressed)
            .restorationBehavior(.disabled)
            Settings {

                SettingsView(model: model).appTextSizing(model.textSize).background(StandaloneWindowRegistration(inert: model.preview).frame(width: 0, height: 0))
            }
            .windowResizability(.contentMinSize)
            .restorationBehavior(model.launchedAtLogin ? .disabled : .automatic)
            Window("VoiceRelay", id: "articles") {
                WorkspaceView(model: model).appTextSizing(model.textSize)
                    .background(StandaloneWindowRegistration(inert: model.preview).frame(width: 0, height: 0))
                    .frame(minWidth: 760, minHeight: 480)
            }
            .defaultSize(width: 980, height: 640)
            .defaultLaunchBehavior(model.launchedAtLogin ? .suppressed : .automatic)
            .restorationBehavior(model.launchedAtLogin ? .disabled : .automatic)
            WindowGroup("Article Preview", for: URL.self) { $url in
                if let url {
                    let profile = model.previewProfiles[url]
                    let options = profile.map { $0.narrationOptions ?? .init() } ?? model.preferences.effectiveNarrationOptions
                    ArticlePreviewView(url: url, inert: model.preview, review: model.previewReviews[url], settings: .init(voice: model.preferences.voice.rawValue, speed: Float(model.preferences.speed)), profile: profile, options: options, sourceTitle: model.previewSourceTitles[url])
                        .id(options.versionSuffix).appTextSizing(model.textSize)
                        .background(StandaloneWindowRegistration(inert: model.preview).frame(width: 0, height: 0))
                        .frame(minWidth: 560, minHeight: 420)
                }
            }
            .defaultSize(width: 720, height: 560)
            .restorationBehavior(model.launchedAtLogin ? .disabled : .automatic)
            .commands { LibraryCommands(model: model) }
            WindowGroup("VoiceRelay Help", for: AppHelpTopic.self) { $topic in
                if let topic {
                    AppHelpView(topic: topic).appTextSizing(model.textSize)
                        .background(StandaloneWindowRegistration(inert: model.preview).frame(width: 0, height: 0))
                        .frame(minWidth: 420, minHeight: 320)
                }
            }.defaultSize(width: 560, height: 500)
                .restorationBehavior(model.launchedAtLogin ? .disabled : .automatic)
        }.commands { AppHelpCommands(model: model); TextSizeCommands(model: model) }
            .onChange(of: model.preview, initial: true) {
                let menuModel = model, windowAction = openWindow, settingsAction = openSettings
                delegate.installMenu { [weak delegate = delegate] in
                    AnyView(StatusItemMenuContent(model: menuModel, openWindow: windowAction, openSettings: settingsAction,
                        dismiss: { delegate?.dismissMenu() }))
                }
            }
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
