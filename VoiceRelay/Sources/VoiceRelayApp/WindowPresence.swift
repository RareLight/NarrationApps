import AppKit
import SwiftUI

/// Only ordinary scene windows register here. MenuBarExtra's framework windows never count.
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
