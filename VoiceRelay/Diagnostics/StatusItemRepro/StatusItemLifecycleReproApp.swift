import AppKit

// User-operated lifecycle probe. No SwiftUI, hosting views, data, or services.
@main
struct StatusItemLifecycleReproApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = StatusItemLifecycleDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class StatusItemLifecycleDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var step = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        mark("BASELINE begin: ordinary AppKit window; no status item")
        mark(ProcessInfo.processInfo.operatingSystemVersionString)

        let appMenu = NSMenu()
        let rootItem = NSMenuItem()
        appMenu.addItem(rootItem)
        let actions = NSMenu()
        actions.addItem(quitMenuItem())
        rootItem.submenu = actions
        NSApp.mainMenu = appMenu

        let controls: [NSView] = [
            NSTextField(labelWithString: "Status item lifecycle diagnostic"),
            NSTextField(wrappingLabelWithString:
                "Watch the unfiltered Xcode console. Choose one creation mode, then follow steps 2–4. Pause between clicks. Restart for the other mode."),
            button("1a. Create square-width item", action: #selector(createSquareItem)),
            button("1b. Create variable-width item", action: #selector(createVariableItem)),
            button("2. Set text label", action: #selector(setTextLabel)),
            button("3. Replace text with waveform", action: #selector(setWaveform)),
            button("4. Attach native menu", action: #selector(attachMenu)),
            button("Quit diagnostic", action: #selector(quit))
        ]
        let stack = NSStackView(views: controls)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 360))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ])
        let window = NSWindow(contentRect: content.frame,
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Status item lifecycle diagnostic"
        window.isReleasedWhenClosed = false
        window.contentView = content
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        mark("BASELINE returned: leave the app idle before step 1")
    }

    @objc private func createSquareItem() {
        createItem(length: NSStatusItem.squareLength, mode: "square")
    }

    @objc private func createVariableItem() {
        createItem(length: NSStatusItem.variableLength, mode: "variable")
    }

    private func createItem(length: CGFloat, mode: String) {
        guard step == 0 else { mark("Ignored: restart the app to change creation mode"); return }
        mark("STEP 1 begin: create \(mode)-width status item, no label or menu")
        let item = NSStatusBar.system.statusItem(withLength: length)
        statusItem = item
        step = 1
        mark("STEP 1 returned: runtime class \(NSStringFromClass(type(of: item)))")
    }

    @objc private func setTextLabel() {
        guard step == 1, let button = statusItem?.button else {
            mark("Ignored: step 2 requires a newly created item with a button"); return
        }
        mark("STEP 2 begin: button.title = VR")
        button.title = "VR"
        step = 2
        mark("STEP 2 returned")
    }

    @objc private func setWaveform() {
        guard step == 2, let button = statusItem?.button else {
            mark("Ignored: complete step 2 first"); return
        }
        mark("STEP 3a begin: load waveform symbol")
        guard let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Lifecycle diagnostic") else {
            mark("STEP 3 failed: system symbol unavailable"); return
        }
        image.isTemplate = true
        mark("STEP 3b begin: clear text label")
        button.title = ""
        mark("STEP 3c begin: set waveform image")
        button.image = image
        step = 3
        mark("STEP 3 returned")
    }

    @objc private func attachMenu() {
        guard step == 3, let statusItem else { mark("Ignored: complete step 3 first"); return }
        mark("STEP 4 begin: attach NSMenu")
        let menu = NSMenu()
        menu.delegate = self
        let title = NSMenuItem(title: "AppKit lifecycle diagnostic", action: nil, keyEquivalent: "")
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(quitMenuItem())
        statusItem.menu = menu
        step = 4
        mark("STEP 4 returned: click the waveform to test menu presentation")
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private func quitMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Quit diagnostic", action: #selector(quit), keyEquivalent: "q")
        item.target = self
        return item
    }

    @objc private func quit() {
        mark("QUIT requested")
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func menuWillOpen(_ menu: NSMenu) { mark("MENU will open") }
    func menuDidClose(_ menu: NSMenu) { mark("MENU did close") }

    func applicationWillTerminate(_ notification: Notification) {
        mark("TERMINATING: remove owned status item")
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    private func mark(_ message: String) {
        NSLog("[LayoutProbe] %@", message)
    }
}
