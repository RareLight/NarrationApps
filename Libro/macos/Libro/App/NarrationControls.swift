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

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 16) { speechOptions; formatOption; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 16) { speechOptions; Spacer(minLength: 0) }
                formatOption
            }
        }.disabled(model.isPreparingModel)
    }

    @ViewBuilder private var speechOptions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Model").appFont(.caption).foregroundStyle(.secondary)
            Picker("Model", selection: $model.settings.model) {
                Text("Kokoro").tag(SpeechModel.kokoro)
                Text("Soprano").tag(SpeechModel.soprano)
            }.labelsHidden().frame(width: 120)
        }
        if model.settings.model == .kokoro {
            VStack(alignment: .leading, spacing: 4) {
                Text("Voice").appFont(.caption).foregroundStyle(.secondary)
                Picker("Voice", selection: $model.settings.voice) {
                    let ranked = VoicePresentation.ranked(model.voices)
                    Section("Recommended") {
                        ForEach(ranked.filter { VoicePresentation.isRecommended($0) }, id: \.self) { voice in
                            Label(VoicePresentation.displayName(voice), systemImage: "star.fill").tag(voice)
                        }
                    }
                    Section {
                        ForEach(ranked.filter { !VoicePresentation.isRecommended($0) }, id: \.self) { voice in
                            Text(VoicePresentation.displayName(voice)).tag(voice)
                        }
                    }
                }.labelsHidden().frame(width: 160).help(VoicePresentation.help(model.settings.voice))
            }
            SpeechSpeedControl(speed: Binding(get: { Double(model.settings.speed) }, set: { model.settings.speed = Float($0) }))
                .fixedSize()
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Voice sample").appFont(.caption).foregroundStyle(.secondary)
            VoiceSampleButton(playing: model.voiceSamplePlayer.playingID != nil) { model.playVoiceSample() }
            if let error = model.voiceSamplePlayer.error {
                Text(error).appFont(.caption).foregroundStyle(.red)
            }
        }
    }

    private var formatOption: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Output format").appFont(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Picker("Output format", selection: $model.outputFormat) {
                    ForEach(AudioOutputFormat.allCases, id: \.self) { format in Text(format.label).tag(format) }
                }.labelsHidden().frame(width: 220)
                Button("About audio formats", systemImage: "info.circle") { showingFormatHelp.toggle() }
                    .labelStyle(.iconOnly).buttonStyle(.plain).help("Audio format and fidelity details")
                    .popover(isPresented: $showingFormatHelp) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Audio formats").appFont(.headline)
                            Text("WAV preserves the model's original Float32 samples at its original sample rate. AAC and MP3 are lossy. Libro applies no volume normalization, dynamic range compression or re-leveling.")
                            Text("M4A uses AAC-LC. M4B uses AAC-LC in an audiobook container for Apple Books. MP3 is intended for broad player compatibility.")
                            Text("Choose Cover Art for selected documents when exporting MP3, M4A or M4B. EPUB documents also offer Use Book Cover in their context menu. Covers do not change audio levels. The format is remembered; changes apply to the next batch.").foregroundStyle(.secondary)
                        }.padding().frame(width: 330)
                    }
            }
        }
    }
}

