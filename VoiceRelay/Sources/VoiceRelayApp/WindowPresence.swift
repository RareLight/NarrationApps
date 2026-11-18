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
        // Keep the transient panel on the active Space so activation prefers it
        // over an ordinary window that lives on another Space.
        if let host = popover.contentViewController?.view.window {
            var behavior = host.collectionBehavior
            behavior.insert(.moveToActiveSpace); behavior.insert(.transient)
            // .transient is mutually exclusive with .managed/.stationary.
            behavior.remove(.canJoinAllSpaces); behavior.remove(.managed); behavior.remove(.stationary)
            host.collectionBehavior = behavior
            host.makeKeyAndOrderFront(nil)
        }
        // Status-item clicks do not activate an accessory app; the panel cannot
        // become key until the app is active.
        NSApp.activate(ignoringOtherApps: true)
    }
    func dismiss() { popover.performClose(nil) }
    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        // Activation belongs to the transient panel: release it unless a scene
        // window took over. open(_:) bumps openRequests before any Space routing,
        // so a menu action that opens a window keeps its activation either way.
        let opens = WindowPresence.shared.openRequests
        DispatchQueue.main.async {
            guard WindowPresence.shared.openRequests == opens,
                  !NSApp.windows.contains(where: { $0.isVisible }) else { return }
            NSApp.deactivate()
        }
    }
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

/// Stable identity for each ordinary scene window; the menu popover never has one.
enum SceneWindowKind: Hashable {
    case workspace, settings, speechSetup
    case article(URL)
    case help(AppHelpTopic)
}

/// The routing surface a scene window needs; NSWindow conforms natively.
@MainActor
protocol ScenePresentationWindow: AnyObject {
    var isVisible: Bool { get }
    var isMiniaturized: Bool { get }
    var isOnActiveSpace: Bool { get }
    var collectionBehavior: NSWindow.CollectionBehavior { get set }
    func makeKeyAndOrderFront(_ sender: Any?)
    func deminiaturize(_ sender: Any?)
}
extension NSWindow: ScenePresentationWindow {}

/// Only ordinary scene windows register here. The menu popover never counts.
/// Open requests route through one existing window's Space: a request made from
/// another Space first fronts that anchor so the target opens where the app
/// already lives, and never drags an open window across Spaces.
@MainActor
final class WindowPresence {
    static let shared = WindowPresence()

    /// Application effects, injectable so routing stays testable without windows.
    struct Environment {
        var isHidden: @MainActor () -> Bool
        var activationPolicy: @MainActor () -> NSApplication.ActivationPolicy
        var setActivationPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void
        var activate: @MainActor () -> Void
        static var live: Self {
            .init(isHidden: { NSApp.isHidden },
                  activationPolicy: { NSApp.activationPolicy() },
                  setActivationPolicy: { NSApp.setActivationPolicy($0) },
                  activate: { NSApp.activate(ignoringOtherApps: true) })
        }
    }

    private final class Record {
        weak var window: (any ScenePresentationWindow)?
        var kind: SceneWindowKind
        let insertion: Int
        var focusSerial = 0
        init(window: any ScenePresentationWindow, kind: SceneWindowKind, insertion: Int) {
            self.window = window; self.kind = kind; self.insertion = insertion
        }
    }
    private struct PendingOpen {
        let kind: SceneWindowKind
        let action: @MainActor () -> Void
        var anchorID: ObjectIdentifier?
        var awaitingSpace = false
    }

    private let environment: Environment
    private var records: [ObjectIdentifier: Record] = [:]
    private var order: [ObjectIdentifier] = []
    private var insertionCounter = 0
    private var focusCounter = 0
    private var closed: Set<ObjectIdentifier> = []
    private var pending: PendingOpen?
    /// The requested role still awaiting its window's first ordering.
    private var pendingTarget: SceneWindowKind?
    /// Original Space collection bits for each temporarily moved window,
    /// restored on supersession, close, or key + active-Space arrival.
    private var spaceRestore: [ObjectIdentifier: NSWindow.CollectionBehavior] = [:]
    /// The last window reported key, so a later Space change can finish its restore.
    private var lastKeyID: ObjectIdentifier?
    private var refreshScheduled = false
    private var observers: [NSObjectProtocol] = []
    /// Serial of scene-window open requests; the menu host compares it when the
    /// popover closes so its activation release never steals a window's focus.
    private(set) var openRequests = 0

    init(environment: Environment = .live, observesNotifications: Bool = true) {
        self.environment = environment
        guard observesNotifications else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSWindow.willCloseNotification { self.windowWillClose(window) }
                    else if name == NSWindow.didBecomeKeyNotification { self.windowDidBecomeKey(window) }
                    else { self.windowStateChanged(window) }
                }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeSpaceDidChange() }
        })
    }
    func register(_ window: any ScenePresentationWindow, kind: SceneWindowKind) {
        let id = ObjectIdentifier(window)
        let isNew: Bool
        if let record = records[id] {
            // SwiftUI re-attachment keeps window identity and focus history.
            record.window = window; record.kind = kind
            isNew = false
        } else {
            insertionCounter += 1
            order.append(id)
            records[id] = Record(window: window, kind: kind, insertion: insertionCounter)
            isNew = true
        }
        let wasClosed = closed.remove(id) != nil
        // Only a not-yet-presented request may join this Space, and only a new
        // or closed-cached target — never an already-open window re-attaching.
        // Fronting waits for the next main turn: this runs inside SwiftUI's
        // viewDidMoveToWindow, too early to order or activate safely.
        if pending == nil, pendingTarget == kind, isNew || wasClosed {
            joinActiveSpaceTemporarily(window, id: id)
            let serial = openRequests
            DispatchQueue.main.async { [weak self, window] in
                MainActor.assumeIsolated {
                    guard let self, self.openRequests == serial,
                          self.pendingTarget == kind, self.pending == nil,
                          let record = self.records[id], record.window != nil,
                          !self.closed.contains(id) else { return }
                    window.makeKeyAndOrderFront(nil)
                    self.environment.activate()
                }
            }
        }
        scheduleRefresh()
    }
    /// Begin opening a scene window. Increments the request serial immediately
    /// (the popover's deferred deactivation guard compares it), supersedes any
    /// earlier pending request, and activates only once a window exists.
    func open(_ kind: SceneWindowKind, action: @escaping @MainActor () -> Void) {
        openRequests += 1
        let superseding = pending != nil || pendingTarget != nil
        pending = nil
        pendingTarget = kind
        // Undo the superseded request's temporary Space joins before anchoring.
        if superseding { restoreAllPendingMoves() }
        environment.setActivationPolicy(.regular)
        if let anchor = anchor(for: kind), !anchor.window.isOnActiveSpace {
            // Front the app's Space first; the action runs only after arrival.
            pending = PendingOpen(kind: kind, action: action, anchorID: anchor.id, awaitingSpace: true)
            frontAnchor(anchor.window)
        } else {
            present(PendingOpen(kind: kind, action: action))
        }
    }
    private func frontAnchor(_ window: any ScenePresentationWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        environment.activate()
    }
    /// Run the open action on the active Space. A cached closed target window
    /// joins this Space only for this open; its original bits restore when it
    /// becomes key. A not-yet-created target is handled in register instead.
    private func present(_ request: PendingOpen) {
        pending = nil
        let known = registeredWindow(for: request.kind)
        if let known, closed.contains(known.id) {
            joinActiveSpaceTemporarily(known.window, id: known.id)
        }
        request.action()
        // A cached target that openWindow/openSettings reuses is fronted here;
        // a newly created one queues its fronting during register(_:kind:).
        if let known, records[known.id]?.window != nil {
            known.window.makeKeyAndOrderFront(nil)
            environment.activate()
        }
    }
    func activeSpaceDidChange() {
        // A window that became key while still off-Space finishes restoring here.
        if let id = lastKeyID, let record = records[id], let window = record.window {
            finishPresentationIfArrived(window, id: id, record: record)
        }
        checkPendingArrival()
    }
    func windowDidBecomeKey(_ window: any ScenePresentationWindow) {
        let id = ObjectIdentifier(window)
        guard let record = records[id] else { return }
        lastKeyID = id
        closed.remove(id)
        focusCounter += 1; record.focusSerial = focusCounter
        finishPresentationIfArrived(window, id: id, record: record)
        checkPendingArrival()
        scheduleRefresh()
    }
    /// A moved target keeps its temporary Space bits until it is key AND has
    /// arrived on the active Space; key can precede the Space switch.
    private func finishPresentationIfArrived(_ window: any ScenePresentationWindow,
                                             id: ObjectIdentifier, record: Record) {
        guard window.isOnActiveSpace else { return }
        restoreSpaceBits(window, id: id)
        if record.kind == pendingTarget { pendingTarget = nil }
    }
    func windowWillClose(_ window: any ScenePresentationWindow) {
        let id = ObjectIdentifier(window)
        guard let record = records[id] else { return }
        restoreSpaceBits(window, id: id)
        closed.insert(id)
        // A target that closes before its key+Space arrival is no longer
        // presenting; without it nothing keeps .regular alive.
        if pending == nil, record.kind == pendingTarget { pendingTarget = nil }
        if pending?.awaitingSpace == true, pending?.anchorID == id { replanCurrentPending() }
        scheduleRefresh()
    }
    func windowStateChanged(_ window: any ScenePresentationWindow) {
        guard records[ObjectIdentifier(window)] != nil else { return }
        checkPendingArrival()
        scheduleRefresh()
    }
    private func isOpen(_ window: any ScenePresentationWindow, id: ObjectIdentifier) -> Bool {
        !closed.contains(id) && (window.isVisible || window.isMiniaturized || environment.isHidden())
    }
    private func pruneDeadRecords() {
        let dead = order.filter { self.records[$0]?.window == nil }
        for id in dead {
            records.removeValue(forKey: id); closed.remove(id)
            spaceRestore.removeValue(forKey: id)
        }
        if !dead.isEmpty { order.removeAll { dead.contains($0) } }
    }
    /// The newest live window registered for a kind — a closed-but-retained
    /// cached window counts so it can be re-presented on this Space.
    private func registeredWindow(for kind: SceneWindowKind) -> (window: any ScenePresentationWindow, id: ObjectIdentifier)? {
        order.lazy.compactMap { id -> (any ScenePresentationWindow, ObjectIdentifier)? in
            guard let record = self.records[id], record.kind == kind, let window = record.window else { return nil }
            return (window, id)
        }.last
    }
    private func anchor(for kind: SceneWindowKind) -> (window: any ScenePresentationWindow, id: ObjectIdentifier)? {
        pruneDeadRecords()
        var candidates: [(id: ObjectIdentifier, record: Record, window: any ScenePresentationWindow)] = []
        for id in order {
            guard let record = records[id], let window = record.window, isOpen(window, id: id) else { continue }
            candidates.append((id, record, window))
        }
        // An already-open target simply fronts on its own Space.
        if let target = candidates.first(where: { $0.record.kind == kind }) {
            return (target.window, target.id)
        }
        // Otherwise prefer the most recently focused window on this Space,
        // then the most recently focused window anywhere, then the first.
        if let onSpace = candidates.filter({ $0.window.isOnActiveSpace })
            .max(by: { $0.record.focusSerial < $1.record.focusSerial }) {
            return (onSpace.window, onSpace.id)
        }
        if let focused = candidates.max(by: { $0.record.focusSerial < $1.record.focusSerial }) {
            return (focused.window, focused.id)
        }
        return candidates.first.map { ($0.window, $0.id) }
    }
    private func joinActiveSpaceTemporarily(_ window: any ScenePresentationWindow, id: ObjectIdentifier) {
        // Save the original bits once — a repeated join must not capture the
        // already-inserted move flag as the window's baseline.
        if spaceRestore[id] == nil { spaceRestore[id] = window.collectionBehavior }
        var behavior = window.collectionBehavior
        behavior.insert(.moveToActiveSpace)
        behavior.remove(.canJoinAllSpaces)
        window.collectionBehavior = behavior
    }
    /// Restore only the two Space bits this coordinator manages; every other
    /// flag AppKit or SwiftUI changed in the meantime is left untouched.
    private func applySpaceBits(_ original: NSWindow.CollectionBehavior,
                                to window: any ScenePresentationWindow) {
        var behavior = window.collectionBehavior
        if original.contains(.canJoinAllSpaces) { behavior.insert(.canJoinAllSpaces) }
        else { behavior.remove(.canJoinAllSpaces) }
        if original.contains(.moveToActiveSpace) { behavior.insert(.moveToActiveSpace) }
        else { behavior.remove(.moveToActiveSpace) }
        window.collectionBehavior = behavior
    }
    private func restoreSpaceBits(_ window: any ScenePresentationWindow, id: ObjectIdentifier) {
        guard let original = spaceRestore.removeValue(forKey: id) else { return }
        applySpaceBits(original, to: window)
    }
    private func restoreAllPendingMoves() {
        let saved = spaceRestore
        spaceRestore.removeAll()
        for (id, original) in saved {
            if let window = records[id]?.window { applySpaceBits(original, to: window) }
        }
    }
    private func checkPendingArrival() {
        guard let request = pending, request.awaitingSpace else { return }
        guard let anchorID = request.anchorID,
              let anchor = records[anchorID]?.window, isOpen(anchor, id: anchorID) else {
            replanCurrentPending()
            return
        }
        if anchor.isOnActiveSpace {
            pending = nil
            present(PendingOpen(kind: request.kind, action: request.action))
        }
    }
    /// The anchor closed or deallocated while waiting: choose another live
    /// window, or present on the current Space when none remain.
    private func replanCurrentPending() {
        guard let request = pending else { return }
        pending = nil
        if let anchor = anchor(for: request.kind), !anchor.window.isOnActiveSpace {
            pending = PendingOpen(kind: request.kind, action: request.action,
                                  anchorID: anchor.id, awaitingSpace: true)
            frontAnchor(anchor.window)
        } else {
            present(PendingOpen(kind: request.kind, action: request.action))
        }
    }
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // Never change activation policy from a SwiftUI/AppKit layout callback.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            // A pending open keeps .regular so nothing flips accessory mid-open.
            let open = self.pending != nil || self.pendingTarget != nil || self.order.contains { id in
                guard let record = self.records[id], let window = record.window else { return false }
                return !self.closed.contains(id)
                    && (window.isVisible || window.isMiniaturized || self.environment.isHidden())
            }
            let policy: NSApplication.ActivationPolicy = open ? .regular : .accessory
            if self.environment.activationPolicy() != policy { self.environment.setActivationPolicy(policy) }
        }
    }
}

/// A zero-sized attachment reports its window without affecting sizing or doing layout work.
struct StandaloneWindowRegistration: NSViewRepresentable {
    let inert: Bool
    let kind: SceneWindowKind
    func makeNSView(context: Context) -> Attachment { Attachment(inert: inert, kind: kind) }
    func updateNSView(_ view: Attachment, context: Context) {}
    final class Attachment: NSView {
        let inert: Bool
        let kind: SceneWindowKind
        init(inert: Bool, kind: SceneWindowKind) { self.inert = inert; self.kind = kind; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if !inert, let window { WindowPresence.shared.register(window, kind: kind) }
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
