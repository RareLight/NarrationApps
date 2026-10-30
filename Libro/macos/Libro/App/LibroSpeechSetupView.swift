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

struct LibroSpeechSetupLauncher: View {
    @Bindable var model: IntakeModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.onChange(of: model.needsSpeechSetup, initial: true) { _, _ in
            if model.claimSpeechSetup() { openWindow(id: "speech-setup") }
        }
    }
}

struct LibroSpeechSetupView: View {
    @Bindable var model: IntakeModel
    @Environment(\.dismissWindow) private var dismissWindow
    private var activity: SpeechSetupActivity? {
        if model.isPreparingModel { return model.preparationIsCheck ? .checking : .installing }
        if model.checkingAssets { return .checking }
        return nil
    }
    var body: some View {
        SpeechSetupOnboardingView(status: model.speechSetupStatus,
            activity: activity,
            canInstall: model.canManageSpeechSetup,
            install: model.installSpeechRuntime, repair: model.installSpeechRuntime,
            chooseFolder: { model.browse(.workspace) }, cancel: model.cancel,
            notNow: { dismissWindow() })
    }
}
