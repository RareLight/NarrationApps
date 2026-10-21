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
    @Environment(\.appTextSize) private var textSize
    @Environment(\.dynamicTypeSize) private var dynamicType
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Set up local speech", systemImage: "waveform.circle").appFont(.headline)
            Text("Libro needs a speech model before it can generate audio. Download the selected model and pronunciation assets, or choose a folder with models you have already prepared. Speech runs locally on your Mac.")
                .fixedSize(horizontal: false, vertical: true)
            Text(model.workspace?.displayPath ?? "New models will be stored in Libro’s Application Support folder.")
                .appFont(.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.isPreparingModel || model.checkingAssets {
                HStack { ProgressView().controlSize(.small); Text(model.isPreparingModel ? model.preparationStatus : model.readiness) }
            } else if !model.preparationStatus.isEmpty {
                Text(model.preparationStatus).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.isPreparingModel {
                    Button(model.preparationIsCheck ? "Cancel Check" : "Cancel Installation") { Task { await model.stopPreparation() } }
                } else {
                    Button("Choose Existing Models…") { model.browse(.workspace) }
                        .disabled(model.checkingAssets)
                    Spacer()
                    Button("Not Now") { dismissWindow() }.keyboardShortcut(.cancelAction)
                    Button("Install Speech Model") { model.installSpeechRuntime() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(model.checkingAssets || model.busy || model.isGenerating || model.hasOwnedProbe)
                }
            }
        }.padding(24).frame(width: 620 * max(1, AppTypography.scale(size: textSize, dynamic: dynamicType)))
            .onChange(of: model.assetsReady) { _, ready in if ready && !model.setupVerificationFailed { dismissWindow() } }
    }
}
