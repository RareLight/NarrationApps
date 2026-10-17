import SwiftUI
import AppPresentation
import PronunciationUI
import NarrationUI
import ProcessingPipeline
import AppKit
import UniformTypeIdentifiers
import LibroCore
import NarrationCore
import Darwin
import AVFoundation
import AudioOutput
import OSLog
@preconcurrency import UserNotifications

@main
struct LibroApp: App {
    @NSApplicationDelegateAdaptor(LibroDelegate.self) private var delegate
    @State private var model = IntakeModel.shared
    @AppStorage("LibroTextSizePercent") private var textSizePercent = 100
    private var textSize: Binding<AppTextSize> {
        Binding(get: { AppTextSize(percent: textSizePercent) }, set: { textSizePercent = $0.percent })
    }

    var body: some Scene {
        Window("Libro", id: "main") {
            IntakeView(model: model)
                .appTextSizing(textSize.wrappedValue)
                .frame(minWidth: 780, minHeight: 580)
                .background(WindowAutosave())
                .onOpenURL { model.add([$0]) }
                .background(LibroSpeechSetupLauncher(model: model).frame(width: 0, height: 0))
        }
        .defaultSize(width: 1000, height: 680)
        .commands {
            AppTextSizeCommands(size: textSize)
            CommandGroup(replacing: .newItem) {
                Button("Add Files and Folders…") { model.openInputs() }.keyboardShortcut("o")
                Button("Add Folder…") { model.openInputs(foldersOnly: true) }
                Divider()
                Button("Remove Selected") { model.removeSelected() }.disabled(model.selection.isEmpty || model.busy || model.isGenerating)
                Button("Clear Finished") { model.clearFinished() }.disabled(!model.hasFinished || model.busy || model.isGenerating)
                Button("Clear Queue") { model.clear() }.disabled(model.documents.isEmpty || model.busy || model.isGenerating)
                Divider()
                Button("Preview Selected Document") { model.previewSelected() }.keyboardShortcut("y")
                    .disabled(model.selectedDocument == nil || model.busy)
                Button("Play or Stop Selected Audio") { model.playSelected() }.disabled(!model.hasSelectedAudio)
                Button("Reveal Selected Audio") { model.revealSelected() }.disabled(!model.hasSelectedAudio)
                Button("Queue Selected Document Again") { model.retrySelected() }.disabled(!model.hasSelectedFailure)
                Divider()
                Button("Generate Audio") { model.generate() }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(!model.canGenerate)
                Button("Cancel Processing") { model.cancel() }.keyboardShortcut(".").disabled(!model.cancellable)
            }
        }
        Window("Set Up Libro Speech", id: "speech-setup") {
            LibroSpeechSetupView(model: model).appTextSizing(textSize.wrappedValue)
        }.windowResizability(.contentSize).defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled)
        Settings {

            LibroSettingsView(model: model, textSize: textSize)
                .appTextSizing(textSize.wrappedValue)
        }
    }
}

@MainActor
private final class LibroDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func application(_ application: NSApplication, open urls: [URL]) {
        IntakeModel.shared.add(urls)
        showWindow()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Preserve a visible chooser/preview's key-window focus. Recreate the
        // main window only when every window has been closed.
        if !flag { showWindow() }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = IntakeModel.shared
        if model.isGenerating || model.isPreparingModel {
            let alert = NSAlert()
            alert.messageText = model.isPreparingModel ? "Libro is preparing model assets." : "Libro is processing audio."
            alert.informativeText = model.isPreparingModel ? "Keep preparing, or cancel preparation and quit. Completed asset files can be reused when you prepare again." : "Keep processing, or cancel this batch and quit. Complete audio already saved will be preserved."
            alert.addButton(withTitle: "Keep Processing")
            alert.addButton(withTitle: "Cancel Processing and Quit")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        model.cancel()
        model.stopPlayback()
        guard model.hasCoverWork || model.pronunciationPreview.hasOwnedWork || model.hasOwnedProbe || model.isGenerating || model.isPreparingModel else { return .terminateNow }
        Task {
            await model.stopCoverWork()
            await model.stopGeneration()
            await model.stopPreparation()
            await model.stopProbe()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    private func showWindow() {
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            IntakeModel.shared.reopenWindow?()
        }
        NSApp.activate(ignoringOtherApps: true)
        let visibleKey = NSApp.keyWindow.flatMap { $0.isVisible ? $0 : nil }
        (visibleKey ?? NSApp.windows.first(where: { $0.canBecomeMain }))?.makeKeyAndOrderFront(nil)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        let saved = response.notification.request.content.userInfo["saved"] as? Int
        let failed = response.notification.request.content.userInfo["failed"] as? Int
        Task { @MainActor in
            if let saved, let failed, saved >= 0, failed >= 0 {
                IntakeModel.shared.notificationSummary = "Libro processing complete: \(saved) saved; \(failed) failed."
            }
            self.showWindow()
        }
        completionHandler()
    }
}

private struct WindowAutosave: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { AutosaveView() }
    func updateNSView(_ view: NSView, context: Context) { }
    private final class AutosaveView: NSView {
        private var restored = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, !restored {
                restored = true
                window.setFrameUsingName("Libro.main")
                if let screen = window.screen ?? NSScreen.main {
                    window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: false)
                }
                window.setFrameAutosaveName("Libro.main")
            }
        }
    }
}
