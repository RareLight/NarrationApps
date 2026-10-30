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
        VStack(alignment: .leading, spacing: 6 * scale) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 4 * scale) {
                    speechOptions
                    formatOption
                }.fixedSize(horizontal: true, vertical: true)
                VStack(alignment: .leading, spacing: 6 * scale) {
                    ScrollView(.horizontal) { speechOptions }
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView(.horizontal) { formatOption }
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .disabled(model.isPreparingModel || model.modelStorage.isBusy)
            if model.isPreparingModel {
                HStack { PreparationProgressView(model: model); Button("Cancel", action: model.cancel) }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    private var speechOptions: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
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
        HStack(spacing: 4 * scale) {
            Text("Format").frame(minHeight: 28 * scale).accessibilityHidden(true)
            Picker("Output format", selection: $model.outputFormat) {
                ForEach(AudioOutputFormat.allCases, id: \.self) { format in Text(format.label).tag(format) }
            }.labelsHidden().frame(width: 220 * scale, alignment: .leading)
                .frame(minHeight: 28 * scale)
            Button("About audio formats", systemImage: "info.circle") { showingFormatHelp.toggle() }
                .labelStyle(.iconOnly).buttonStyle(.plain).frame(width: 22 * scale, height: 28 * scale)
                .help("About audio formats")
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
