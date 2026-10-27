import AppKit
import SwiftUI
import ServiceManagement
import Carbon

/// One native button opens the same SwiftUI popover for either mouse button.
/// Own the item directly: macOS 27's MenuBarExtra presentation cannot be driven
/// reliably by changing its underlying button's target/action.
@MainActor
final class StatusItemPopoverHost: NSObject, NSPopoverDelegate {
    var content: () -> AnyView
    private var item: NSStatusItem?
    private let popover = NSPopover()

    init(content: @escaping () -> AnyView) {
        self.content = content
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }
    func start() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.item = item
        if let button = item.button { configure(button) }
    }
    func configure(_ button: NSStatusBarButton) {
        let configuration = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize * 2, weight: .regular)
        let image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "VoiceRelay")?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        button.symbolConfiguration = configuration
        button.imageScaling = .scaleProportionallyDown
        button.image = image
        button.toolTip = "VoiceRelay"
        button.setAccessibilityLabel("VoiceRelay")
        button.target = self
        button.action = #selector(toggle(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    @objc private func toggle(_ sender: Any?) {
        guard let button = item?.button else { return }
        if popover.isShown { dismiss(); return }
        let controller = NSHostingController(rootView: content())
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    func dismiss() { popover.performClose(nil) }
    func popoverDidClose(_ notification: Notification) { popover.contentViewController = nil }
    func stop() {
        dismiss()
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }
}

enum LoginLaunchContext {
    static func isLoginItemLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard event?.eventID == kAEOpenApplication else { return false }
        return event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

enum LoginItemStatus: Equatable {
    case notRegistered, enabled, requiresApproval, notFound
    var requested: Bool { self == .enabled || self == .requiresApproval }
}

/// The OS registration is the source of truth; no preference silently re-enables a revoked item.
@MainActor
protocol LoginItemService {
    var status: LoginItemStatus { get }
    func setEnabled(_ enabled: Bool) async throws
    func openSettings()
}

@MainActor
final class MainAppLoginItemService: LoginItemService {
    private let service = SMAppService.mainApp
    var status: LoginItemStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }
    func setEnabled(_ enabled: Bool) async throws {
        if enabled { try service.register() }
        else { try await service.unregister() }
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Only ordinary scene windows register here. The menu popover never counts.
@MainActor
final class WindowPresence {
    static let shared = WindowPresence()
    private let windows = NSHashTable<NSWindow>.weakObjects()
    private var closed: Set<ObjectIdentifier> = []
    private var refreshScheduled = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        for name in [NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    guard let self, self.windows.contains(window) else { return }
                    let id = ObjectIdentifier(window)
                    if name == NSWindow.willCloseNotification { self.closed.insert(id) }
                    if name == NSWindow.didBecomeKeyNotification { self.closed.remove(id) }
                    self.scheduleRefresh()
                }
            })
        }
    }
    func register(_ window: NSWindow) {
        windows.add(window); closed.remove(ObjectIdentifier(window)); scheduleRefresh()
    }
    func prepareToOpen() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // Never change activation policy from a SwiftUI/AppKit layout callback.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            let open = self.windows.allObjects.contains {
                !self.closed.contains(ObjectIdentifier($0)) && ($0.isVisible || $0.isMiniaturized || NSApp.isHidden)
            }
            let policy: NSApplication.ActivationPolicy = open ? .regular : .accessory
            if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
        }
    }
}

/// A zero-sized attachment reports its window without affecting sizing or doing layout work.
struct StandaloneWindowRegistration: NSViewRepresentable {
    let inert: Bool
    func makeNSView(context: Context) -> Attachment { Attachment(inert: inert) }
    func updateNSView(_ view: Attachment, context: Context) {}
    final class Attachment: NSView {
        let inert: Bool
        init(inert: Bool) { self.inert = inert; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if !inert, let window { WindowPresence.shared.register(window) }
        }
    }
}

/// Capture only this popover's host; never guess from NSApp.keyWindow or window order.
@MainActor
final class MenuPopoverWindowReference {
    weak var window: NSWindow?
    func dismiss() { window?.orderOut(nil) }
}

struct MenuPopoverWindowCapture: NSViewRepresentable {
    let reference: MenuPopoverWindowReference
    let inert: Bool
    func makeNSView(context: Context) -> Attachment { Attachment(reference: reference, inert: inert) }
    func updateNSView(_ view: Attachment, context: Context) {}
    final class Attachment: NSView {
        let reference: MenuPopoverWindowReference
        let inert: Bool
        init(reference: MenuPopoverWindowReference, inert: Bool) {
            self.reference = reference; self.inert = inert; super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // A weak reference changes no SwiftUI state and performs no layout or activation.
            if !inert { reference.window = window }
        }
    }
}
