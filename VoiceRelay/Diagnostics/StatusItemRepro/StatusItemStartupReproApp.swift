import AppKit

// Native startup control: LSUIElement, immediate item creation, no SwiftUI/window.
@main
struct StatusItemStartupReproApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = StatusItemStartupDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class StatusItemStartupDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        mark("BEGIN: native menu-bar-only startup; no ordinary window")
        mark(ProcessInfo.processInfo.operatingSystemVersionString)
        let isAgent = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool ?? false
        mark("LSUIElement = \(isAgent); activation policy = \(NSApp.activationPolicy().rawValue)")

        mark("STEP 1 begin: create variable-width status item at launch")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        mark("STEP 1 returned: runtime class \(NSStringFromClass(type(of: item)))")

        mark("STEP 2 begin: assign waveform label")
        guard let button = item.button,
              let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Native startup diagnostic") else {
            mark("FAILED: status-item button or waveform unavailable")
            NSApp.terminate(nil)
            return
        }
        image.isTemplate = true
        button.image = image
        mark("STEP 2 returned")

        mark("STEP 3 begin: attach native menu")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Native startup diagnostic", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let confirm = NSMenuItem(title: "Confirm menu action", action: #selector(confirmMenuAction), keyEquivalent: "")
        confirm.target = self
        menu.addItem(confirm)
        let quit = NSMenuItem(title: "Quit diagnostic", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        mark("STEP 3 returned: click waveform, choose Confirm menu action, then Quit diagnostic")
    }

    @objc private func confirmMenuAction() {
        mark("ACTION selected: menu content is interactive")
    }

    @objc private func quit() {
        mark("QUIT requested from native menu")
        NSApp.terminate(nil)
    }

    func menuWillOpen(_ menu: NSMenu) { mark("MENU will open") }
    func menuDidClose(_ menu: NSMenu) { mark("MENU did close") }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        mark("TERMINATING: remove owned status item")
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    private func mark(_ message: String) {
        NSLog("[StartupProbe] %@", message)
    }
}
