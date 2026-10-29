import SwiftUI
import AppKit
import AppPresentation
import Testing
import NarrationCore
import NativeSpeech
import Foundation
@testable import NarrationUI

@Test @MainActor func narrationSettingsComposeWithMissingBusyFailureAndReadyStatesWithoutOperations() {
    var calls = 0
    let statuses: [SpeechSetupStatus] = [.notInstalled, .notChecked, .ready, .cancelled, .failure("Synthetic failure")]
    for status in statuses {
        let activities: [SpeechSetupActivity?] = [nil, .installing, .checking]
        for activity in activities {
            _ = SpeechSetupControls(activity: activity, status: status, canManage: activity == nil,
                installMessage: "Synthetic model download", install: { calls += 1 }, check: { calls += 1 }, cancel: { calls += 1 }).body
        }
        _ = SpeechSetupStatusView(status: status).body
    }
    _ = ImageDescriptionSettingsSection(enabled: .constant(true), additionalHelp: "Future work only.").body
    _ = SpeechSpeedControl(speed: .constant(1.25)).body
    _ = VoiceSampleButton(playing: false) { calls += 1 }.body
    _ = NarrationOptionsControls(options: .constant(.init())).body
    _ = NarrationOptionsControls(options: .constant(.init(experimentalPDFWordJoining: true))).body
    for placement in NarrationOptions.NotePlacement.allCases {
        for enabled in [false, true] {
            _ = NarrationOptionsControls(options: .constant(.init(notes: placement,
                includeAuxiliary: enabled, experimentalPDFWordJoining: enabled,
                stripInlineCitations: enabled, stripEndnoteCitations: enabled)), showsExamples: true).body
        }
    }
    _ = ImageDescriptionSettingsSection(enabled: .constant(true), additionalHelp: "Future work only.", showsExample: true).body
    _ = ImageDescriptionSettingsSection(enabled: .constant(false), additionalHelp: "Future work only.", showsExample: true).body
    _ = DocumentTextExample(source: "Synthetic input", narration: "Synthetic narration").body
    _ = DocumentTextExample(source: "Synthetic input", narration: "Synthetic narration", detail: "Synthetic explanation.").body
    #expect(calls == 0)
}

@Test @MainActor func modelControlsComposeForEveryVariantWithoutStartingWork() {
    for model in SpeechModel.allCases {
        let settings = SpeechSettings(model: model, voice: model.defaultVoice)
        var calls = 0
        for downloading in [false, true] {
            _ = SpeechModelControls(settings: .constant(settings),
                storageRoot: URL(fileURLWithPath: "/synthetic/model-cache"), maintenance: ModelStorageMaintenance(),
                downloading: downloading,
                canDownload: false, download: { calls += 1 }, playSample: { calls += 1 }).body
        }
        _ = SpeechModelControls(settings: .constant(settings), storageRoot: nil,
            maintenance: ModelStorageMaintenance(), canDownload: false).body
        #expect(calls == 0)
    }
}

@Test @MainActor func sharedOnboardingComposesWithoutInstallingCancellingOrDismissing() {
    var calls = 0
    let activities: [SpeechSetupActivity?] = [nil, .installing, .checking]
    let statuses: [SpeechSetupStatus] = [.notInstalled, .notChecked, .ready, .cancelled, .failure("Synthetic failure")]
    for activity in activities {
        for canInstall in [false, true] {
            for status in statuses {
                _ = SpeechSetupOnboardingView(status: status,
                    activity: activity, canInstall: canInstall,
                    install: { calls += 1 }, check: { calls += 1 }, chooseFolder: { calls += 1 },
                    cancel: { calls += 1 }, notNow: { calls += 1 }).body
            }
        }
    }
    #expect(calls == 0)
}

@Test @MainActor func sharedOnboardingFitsACompactWindowAndExpandsForErrorsAndTextSize() {
    _ = NSApplication.shared
    var calls = 0
    var standard: CGSize?
    for percent in [80, 100, 200] {
        let size = AppTextSize(percent: percent)
        func measure(_ status: SpeechSetupStatus) -> CGSize {
            NSHostingView(rootView: SpeechSetupOnboardingView(status: status,
                activity: nil, canInstall: true,
                install: { calls += 1 }, check: { calls += 1 }, chooseFolder: { calls += 1 },
                cancel: { calls += 1 }, notNow: { calls += 1 })
                .appTextSizing(size).dynamicTypeSize(.large)).fittingSize
        }
        let compact = measure(.notInstalled)
        let failure = measure(.failure(String(repeating: "Synthetic installation failure. ", count: 20)))
        #expect(compact.width.isFinite && compact.height > 0)
        #expect(compact.height < 240 * max(1, AppTypography.scale(size: size, dynamic: .large)))
        #expect(failure.height > compact.height)
        if percent == 100 { standard = compact }
        if percent == 200, let standard { #expect(compact.width > standard.width * 1.5 && compact.height > standard.height) }
    }
    #expect(calls == 0)
}

@Test @MainActor func modelStorageSettingsComposeWithoutReadingOrDeletingFiles() {
    let maintenance = ModelStorageMaintenance()
    var calls = 0
    _ = ModelStorageSettings(root: URL(fileURLWithPath: "/synthetic/model-cache"), canManage: false,
        choose: { calls += 1 }, useDefault: { calls += 1 }, changed: {}, maintenance: maintenance).body
    #expect(calls == 0)
    #expect(!maintenance.isBusy)
}

private actor StorageScanGate {
    typealias Selection = SelectedModelStorage.Selection
    private var pending: [Selection: CheckedContinuation<StoredSpeechModel?, Error>] = [:]
    private var started: [Selection: CheckedContinuation<Void, Never>] = [:]
    func scan(_ selection: Selection) async throws -> StoredSpeechModel? {
        try await withCheckedThrowingContinuation { continuation in
            pending[selection] = continuation
            started.removeValue(forKey: selection)?.resume()
        }
    }
    func waitForStart(_ selection: Selection) async {
        if pending[selection] != nil { return }
        await withCheckedContinuation { started[selection] = $0 }
    }
    func finish(_ selection: Selection, with result: Result<StoredSpeechModel?, Error>) {
        pending.removeValue(forKey: selection)?.resume(with: result)
    }
}

private func syntheticModelCache() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-controls-\(UUID())")
    try NativeModelStorage.prepareRoot(root)
    return root
}

private func seedSelectedModel(_ model: SpeechModel, root: URL) throws -> URL {
    let directory = try NativeWorkspace(root: root).nativeRoot.appendingPathComponent("primary/\(model.rawValue)/synthetic")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 8192).write(to: directory.appendingPathComponent("synthetic-weight"))
    return directory
}

@Test @MainActor func selectedModelStorageUpdatesAfterLocalInstallationAndConfirmedDeletion() async throws {
    let root = try syntheticModelCache(); defer { try? FileManager.default.removeItem(at: root) }
    let selection = SelectedModelStorage.Selection(root: root, model: .kokoro)
    let state = SelectedModelStorage()
    #expect(state.action(for: selection) == .checking)
    #expect(state.action(for: nil) == .unavailable)
    await state.load(selection)
    #expect(state.action(for: selection) == .download && state.entry == nil)
    let primary = try seedSelectedModel(.kokoro, root: root)
    let unrelated = root.appendingPathComponent("recording.wav")
    try Data("Keep this recording".utf8).write(to: unrelated)
    await state.load(selection)
    #expect(state.action(for: selection) == .cached && (state.entry?.bytes ?? 0) > 0)
    let maintenance = ModelStorageMaintenance()
    var callbacks = 0
    maintenance.remove(.kokoro, at: root) { callbacks += 1 }
    #expect(maintenance.isBusy)
    await maintenance.waitForIdle()
    #expect(!maintenance.isBusy && maintenance.error == nil && callbacks == 1 && maintenance.revision == 1)
    await state.load(selection)
    #expect(state.action(for: selection) == .download && state.entry == nil)
    #expect(!FileManager.default.fileExists(atPath: primary.path))
    #expect(try Data(contentsOf: unrelated) == Data("Keep this recording".utf8))
}

@Test @MainActor func failedInUseDeletionRetainsTheSelectedCachedModel() async throws {
    let root = try syntheticModelCache(); defer { try? FileManager.default.removeItem(at: root) }
    let primary = try seedSelectedModel(.qwen3, root: root)
    var lease: ModelStorageLease? = try ModelStorageLease(workspace: NativeWorkspace(root: root))
    let selection = SelectedModelStorage.Selection(root: root, model: .qwen3)
    let state = SelectedModelStorage(), maintenance = ModelStorageMaintenance()
    maintenance.remove(.qwen3, at: root) {}
    await maintenance.waitForIdle()
    #expect(maintenance.error != nil && !maintenance.isBusy)
    await state.load(selection)
    #expect(state.action(for: selection) == .cached && FileManager.default.fileExists(atPath: primary.path))
    withExtendedLifetime(lease) {}; lease = nil
    maintenance.remove(.qwen3, at: root) {}
    await maintenance.waitForIdle()
    await state.load(selection)
    #expect(maintenance.error == nil && state.action(for: selection) == .download)
}

@Test @MainActor func importedModelsRemainReadOnlyAndMissingFoldersAreNotCreated() async throws {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("model-missing-\(UUID())")
    let state = SelectedModelStorage()
    await state.load(.init(root: missing, model: .kokoro))
    #expect(state.action(for: .init(root: missing, model: .kokoro)) == .download)
    #expect(!FileManager.default.fileExists(atPath: missing.path))
    let root = try syntheticModelCache(); defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent(SpeechModel.kokoro.primaryRelativePath)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 8192).write(to: directory.appendingPathComponent("synthetic-weight"))
    let selection = SelectedModelStorage.Selection(root: root, model: .kokoro)
    await state.load(selection)
    #expect(state.action(for: selection) == .imported && state.entry?.imported == true)
}

@Test @MainActor func selectedModelStorageRejectsLateResultsAfterModelAndFolderChanges() async {
    let old = SelectedModelStorage.Selection(root: URL(fileURLWithPath: "/synthetic/old"), model: .kokoro)
    let current = SelectedModelStorage.Selection(root: URL(fileURLWithPath: "/synthetic/current"), model: .qwen3)
    for lateFailure in [false, true] {
        let gate = StorageScanGate(), state = SelectedModelStorage(scan: { try await gate.scan($0) })
        let oldTask = Task { await state.load(old) }
        await gate.waitForStart(old)
        #expect(state.loading && state.action(for: old) == .checking)
        #expect(state.action(for: current) == .checking)
        let currentTask = Task { await state.load(current) }
        await gate.waitForStart(current)
        await gate.finish(current, with: .success(.init(model: .qwen3, bytes: 12345)))
        await currentTask.value
        await gate.finish(old, with: lateFailure ? .failure(CocoaError(.fileReadNoPermission)) : .success(nil))
        await oldTask.value
        #expect(state.action(for: current) == .cached && state.entry?.model == .qwen3)
        #expect(state.entry?.bytes == 12345 && state.error == nil && !state.loading)
        #expect(state.action(for: old) == .checking)
    }
}

@Test @MainActor func interruptedOrFailedStorageScansNeverEnableDownloadForAnUnknownCache() async {
    let selection = SelectedModelStorage.Selection(root: URL(fileURLWithPath: "/synthetic/cache"), model: .orpheus)
    let failed = SelectedModelStorage(scan: { _ in throw CocoaError(.fileReadNoPermission) })
    await failed.load(selection)
    #expect(failed.action(for: selection) == .unavailable && failed.error != nil)
    for completion: Result<StoredSpeechModel?, Error> in [.success(nil), .failure(CocoaError(.fileReadNoPermission))] {
        let gate = StorageScanGate(), state = SelectedModelStorage(scan: { try await gate.scan($0) })
        let task = Task { await state.load(selection) }
        await gate.waitForStart(selection)
        task.cancel()
        await gate.finish(selection, with: completion)
        await task.value
        #expect(state.action(for: selection) == .checking && state.entry == nil && !state.loading)
    }
}


/// Measure inert views offscreen: no window, app launch, model cache or profiles.
/// Width stays fixed while each model uses only the height its controls need.
@Test @MainActor func modelSwitchesFitVisibleControlsAtEveryTextSize() throws {
    _ = NSApplication.shared
    let sizes: [(AppTextSize, DynamicTypeSize)] = [
        (.init(percent: 80), .large), (.init(percent: 100), .large),
        (.init(percent: 200), .large), (.init(percent: 100), .accessibility1)
    ]
    var measured: [Int: [SpeechModel: CGSize]] = [:]
    var actionCalls = 0
    for (textSize, dynamicType) in sizes {
        // The recommendation must fit the existing menu column, leaving room for
        // native menu chrome instead of widening the shared control grid.
        let scale = max(1, AppTypography.scale(size: textSize, dynamic: dynamicType))
        let recommendation = NSHostingView(rootView: Text(ModelGuidance.selectionLabel(for: .kokoro))
            .appTextSizing(textSize).dynamicTypeSize(dynamicType)).fittingSize
        #expect(recommendation.width <= (180 - 24) * scale)
        let longestLabel = NSHostingView(rootView: Text("Language")
            .appTextSizing(textSize).dynamicTypeSize(dynamicType)).fittingSize
        #expect(longestLabel.width <= 60 * scale)
        var commonWidth: CGFloat?
        var modelSizes: [SpeechModel: CGSize] = [:]
        for model in SpeechModel.allCases {
            var reference: CGSize?
            for (controlsEnabled, playing) in [(true, false), (true, true), (false, true)] {
                let settings = SpeechSettings(model: model, voice: model.defaultVoice)
                let view = SpeechModelControls(settings: .constant(settings), storageRoot: nil,
                    maintenance: ModelStorageMaintenance(),
                    canDownload: false, controlsEnabled: controlsEnabled, download: { actionCalls += 1 },
                    samplePlaying: playing, playSample: { actionCalls += 1 }, loadReferenceProfiles: { [] })
                    .appTextSizing(textSize).dynamicTypeSize(dynamicType)
                let host = NSHostingView(rootView: view)
                let fitted = host.fittingSize
                #expect(fitted.width.isFinite && fitted.height.isFinite && fitted.width > 0 && fitted.height > 0)
                if let commonWidth {
                    #expect(abs(fitted.width - commonWidth) < 0.5, "Model width shifted for \(model.rawValue)")
                } else { commonWidth = fitted.width }
                if let reference {
                    #expect(abs(fitted.height - reference.height) < 0.5, "Playback/busy state shifted height for \(model.rawValue)")
                } else { reference = fitted }
            }
            modelSizes[model] = try #require(reference)
        }
        let shortest = try #require(modelSizes[.soprano])
        #expect(abs(shortest.height - (try #require(modelSizes[.orpheus])).height) < 0.5)
        for model in [SpeechModel.kokoro, .chatterbox] {
            let middle = try #require(modelSizes[model])
            #expect(middle.height > shortest.height, "Unused model options left blank space")
            #expect((try #require(modelSizes[.qwen3])).height > middle.height, "Qwen options should expand the section")
        }
        if dynamicType == .large { measured[textSize.percent] = modelSizes }
    }
    for model in SpeechModel.allCases {
        let standard = try #require(measured[100]?[model]), enlarged = try #require(measured[200]?[model])
        #expect(enlarged.width > standard.width * 1.5 && enlarged.height > standard.height)
    }
    #expect(actionCalls == 0)
}


@Test @MainActor func compactSpeedKeepsItsValueAndStepperTogetherAtEveryTextSize() {
    _ = NSApplication.shared
    for percent in [80, 100, 200] {
        let size = AppTextSize(percent: percent)
        let compact = NSHostingView(rootView: SpeechSpeedControl(speed: .constant(1), showsLabel: false)
            .appTextSizing(size).dynamicTypeSize(.large)).fittingSize
        let labelled = NSHostingView(rootView: SpeechSpeedControl(speed: .constant(1))
            .appTextSizing(size).dynamicTypeSize(.large)).fittingSize
        let scale = max(1, AppTypography.scale(size: size, dynamic: .large))
        #expect(compact.width.isFinite && compact.width > 0 && compact.height > 0)
        #expect(compact.width < 180 * scale && compact.width < labelled.width)
    }
}

@Test @MainActor func downloadedModelColumnsStayCompactForDifferentNamesSizesAndImportedRows() {
    _ = NSApplication.shared
    let entries: [StoredSpeechModel] = [
        .init(model: .kokoro, bytes: 341_800_000), .init(model: .qwen3, bytes: 3_080_000_000),
        .init(model: .chatterbox, bytes: 3_480_000_000, imported: true),
        .init(model: .orpheus, bytes: .max), .init(model: .soprano, bytes: 1)
    ]
    var calls = 0
    for (textSize, dynamicType) in [(AppTextSize(percent: 80), DynamicTypeSize.large),
        (.init(percent: 100), .large), (.init(percent: 200), .large), (.init(percent: 100), .accessibility1)] {
        let scale = max(1, AppTypography.scale(size: textSize, dynamic: dynamicType))
        var width: CGFloat?
        for rows in entries.map({ [$0] }) + [entries] {
            for canManage in [false, true] {
                let table = ModelStorageInventory(entries: rows, canManage: canManage) { _ in calls += 1 }
                    .appTextSizing(textSize).dynamicTypeSize(dynamicType)
                let fitted = NSHostingView(rootView: table).fittingSize
                #expect(fitted.width.isFinite && fitted.width > 0 && fitted.height > 0)
                #expect(fitted.width < 300 * scale)
                if let width { #expect(abs(fitted.width - width) < 0.5) } else { width = fitted.width }
                let scrollHeight = NSHostingView(rootView: ScrollView(.horizontal) { table }
                    .fixedSize(horizontal: false, vertical: true)).fittingSize.height
                #expect(scrollHeight >= fitted.height, "Inventory scroller must not clip model rows")
            }
        }
    }
    #expect(calls == 0)
}
