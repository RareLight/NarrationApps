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

struct NarrationControls: View {
    @Bindable var model: IntakeModel
    @State private var showingFormatHelp = false
    @Environment(\.appTextSize) private var textSize
    @Environment(\.dynamicTypeSize) private var dynamicType
    private var scale: CGFloat { max(1, AppTypography.scale(size: textSize, dynamic: dynamicType)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) { speechOptions; formatOption; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal) { HStack(alignment: .top, spacing: 8) { speechOptions; Spacer(minLength: 0) } }
                formatOption
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
            .disabled(model.isPreparingModel || model.modelStorage.isBusy)
        if model.isPreparingModel {
            HStack { PreparationProgressView(model: model); Button("Cancel", action: model.cancel) }
        }
        }
    }

    private var speechOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
        SpeechModelControls(settings: $model.settings, storageRoot: model.workspace?.url,
            storageRevision: model.modelStorageRevision, maintenance: model.modelStorage,
            downloading: model.isPreparingModel && !model.preparationIsCheck,
            canDownload: model.canManageSpeechSetup, download: model.installSpeechRuntime,
            samplePlaying: model.voiceSamplePlayer.playingID != nil || model.pronunciationPreview.hasOwnedWork,
            playSample: model.playVoiceSample)
            if let error = model.voiceSamplePlayer.error {
                Text(error).appFont(.caption).foregroundStyle(.red)
            }
            if let error = model.pronunciationPreview.error {
                Text(error).appFont(.caption).foregroundStyle(.red)
            }
        }.frame(width: 296 * scale, alignment: .leading)
    }

    private var formatOption: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Output format").appFont(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Picker("Output format", selection: $model.outputFormat) {
                    ForEach(AudioOutputFormat.allCases, id: \.self) { format in Text(format.label).tag(format) }
                }.labelsHidden().frame(width: 220 * scale, alignment: .leading)
                Button("About audio formats", systemImage: "info.circle") { showingFormatHelp.toggle() }
                    .labelStyle(.iconOnly).buttonStyle(.plain).help("About audio formats")
                    .popover(isPresented: $showingFormatHelp) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Audio formats").appFont(.headline)
                            Text("WAV preserves the original audio. M4A and M4B use AAC; MP3 offers broad player compatibility.")
                            Text("Choose M4B for Apple Books. Cover art works with M4A, M4B and MP3. Changes apply to the next batch.").foregroundStyle(.secondary)
                        }.padding().frame(width: 330)
                    }
            }
        }
    }
}

