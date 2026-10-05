import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LibroCore
import Darwin

@main
struct LibroApp: App {
    @NSApplicationDelegateAdaptor(LibroDelegate.self) private var delegate
    @State private var model = IntakeModel.shared

    var body: some Scene {
        Window("Libro", id: "main") {
            IntakeView(model: model)
                .frame(minWidth: 780, minHeight: 500)
                .background(WindowAutosave())
                .onOpenURL { model.add([$0]) }
        }
        .defaultSize(width: 1000, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files and Folders…") { model.openInputs() }.keyboardShortcut("o")
                Button("Add Folder…") { model.openInputs(foldersOnly: true) }
                Divider()
                Button("Remove Selected") { model.removeSelected() }.disabled(model.selection.isEmpty || model.busy)
                Button("Clear Queue") { model.clear() }.disabled(model.documents.isEmpty || model.busy)
            }
        }
    }
}

@MainActor
private final class LibroDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        IntakeModel.shared.add(urls)
        showWindow()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = IntakeModel.shared
        model.cancel()
        guard model.hasOwnedProbe else { return .terminateNow }
        Task {
            await model.stopProbe()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
@Observable
private final class IntakeModel {
    static let shared = IntakeModel()
    var documents: [InputDocument] = []
    var selection = Set<UUID>()
    var names: [UUID: String] = [:]
    var states: [UUID: String] = [:]
    var output: DirectorySelection?
    var workspace: DirectorySelection?
    var status = "Add documents or drop files and folders here."
    var planningError: String?
    var planned: [PlannedDocument] = []
    var scanCount = 0
    var busy = false
    var cancellable: Bool { scanner != nil || reader != nil || hasOwnedProbe }
    var hasOwnedProbe: Bool { probeProcess != nil }
    var activityStatus: String { scanner != nil ? "Scanning inputs… \(scanCount) entries checked." : status }
    var planning: Bool { planner != nil }
    var preview: Preview?
    var issues: [IntakeIssue] = []
    private let preferences = DirectoryPreferences()
    private var roots: [URL] = []
    private var removed = Set<String>()
    private var scopes: [String: DirectoryAccess] = [:]
    private var scanner: Task<IntakeResult, Error>?
    private var reader: Task<String, Error>?
    private var planner: Task<[PlannedDocument], Error>?
    private var planOperation = UUID()
    private var operation = UUID()
    private var probeProcess: Process?
    private var probeCancelled = false

    private init() {
        output = preferences.load(.output)
        workspace = preferences.load(.workspace)
    }

    func openInputs(foldersOnly: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !foldersOnly
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = foldersOnly ? [.folder] : DocumentKind.contentTypes + [.folder]
        panel.prompt = "Add"
        panel.begin { [weak self] result in
            if result == .OK { self?.add(panel.urls) }
        }
    }

    func browse(_ role: DirectoryRole) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = role == .output ? "Choose where Libro saves audio." : "Choose the Libro workspace containing models."
        panel.begin { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            do {
                let selected = try self.preferences.select(url, role: role)
                if role == .output { self.output = selected } else { self.workspace = selected }
                self.replan()
            } catch { self.status = error.localizedDescription }
        }
    }

    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        scanner?.cancel(); reader?.cancel()
        scanner = nil; reader = nil
        for url in urls {
            scopes[url.path] = DirectoryAccess(url)
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            removed = removed.filter { $0 != path && !$0.hasPrefix(path + "/") }
        }
        roots += urls
        let selection = roots
        let excluded = output?.url
        let token = UUID(); operation = token
        busy = true; scanCount = 0; status = "Scanning inputs…"
        let recipient = self
        let task = Task.detached(priority: .userInitiated) {
            try InputCollector.collect(selection, excludingOutput: excluded) { count in
                Task { @MainActor in
                    guard recipient.operation == token else { return }
                    recipient.scanCount = count
                }
            }
        }
        scanner = task
        Task {
            do {
                let result = try await task.value
                guard operation == token else { return }
                let existing = Dictionary(uniqueKeysWithValues: documents.map { ($0.source.path, $0.id) })
                documents = result.documents.filter { !removed.contains($0.source.path) }.map {
                    InputDocument(source: $0.source, kind: $0.kind, relativePath: $0.relativePath,
                                  id: existing[$0.source.path] ?? $0.id)
                }
                issues = result.issues
                let excluded = result.excludedOutput ? " Selected output subtree excluded." : ""
                status = "\(documents.count) documents; \(result.ignoredCount) unsupported or linked items ignored; \(result.issues.count) input errors.\(excluded)"
                replan()
            } catch is CancellationError {
                if operation == token { status = "Input scan cancelled." }
            } catch { if operation == token { status = error.localizedDescription } }
            if operation == token { busy = false; scanner = nil }
        }
    }

    func replan() {
        planner?.cancel()
        let token = UUID(); planOperation = token
        planned = []
        guard let url = output?.url else { planningError = output?.error ?? "Choose an output folder to preview destinations."; return }
        let inputs = documents
        let overrides = names
        planningError = nil
        let task = Task.detached(priority: .userInitiated) {
            try await Task.sleep(for: .milliseconds(150))
            let scope = DirectoryAccess(url)
            defer { withExtendedLifetime(scope) {} }
            return try BatchPlanner.plan(inputs, output: url, names: overrides)
        }
        planner = task
        Task {
            do {
                let result = try await task.value
                if planOperation == token { planned = result; planningError = nil }
            } catch is CancellationError { }
            catch { if planOperation == token { planningError = error.localizedDescription } }
            if planOperation == token { planner = nil }
        }
    }

    func removeSelected() {
        guard !busy else { return }
        for document in documents where selection.contains(document.id) { removed.insert(document.source.path) }
        documents.removeAll { selection.contains($0.id) }
        names = names.filter { !selection.contains($0.key) }
        states = states.filter { !selection.contains($0.key) }
        selection.removeAll(); replan()
    }

    func clear() {
        guard !busy else { return }
        documents = []; roots = []; scopes = [:]; removed = []; names = [:]; states = [:]
        issues = []; selection = []; status = "Add documents or drop files and folders here."; replan()
    }

    func cancel() {
        scanner?.cancel(); reader?.cancel()
        if let process = probeProcess, process.isRunning { probeCancelled = true; process.terminate() }
    }

    func stopProbe() async {
        guard let process = probeProcess else { return }
        probeCancelled = true
        await Task.detached {
            if process.isRunning { process.terminate() }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(1))
            while process.isRunning, clock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }.value
        if probeProcess === process { probeProcess = nil }
    }

    func showPreview(_ document: InputDocument) {
        guard !busy else { return }
        let token = UUID(); operation = token; busy = true
        status = "Reading document text…"
        states[document.id] = "Reading…"
        let task = Task.detached(priority: .userInitiated) { try DocumentReader.read(document) }
        reader = task
        Task {
            do {
                let text = try await task.value
                guard operation == token else { return }
                preview = Preview(id: document.id, title: document.source.lastPathComponent, text: text)
                states[document.id] = "Text ready"
            } catch is CancellationError {
                if operation == token { states[document.id] = "Reading cancelled" }
            } catch {
                if operation == token { states[document.id] = error.localizedDescription }
            }
            if operation == token { busy = false; reader = nil }
        }
    }

    func probe() {
        guard !busy, probeProcess == nil else { return }
        let token = UUID(); operation = token
        busy = true; probeCancelled = false; status = "Checking embedded Metal runtime…"
        do {
            // Spawn on the owning actor before any quit event can arrive.
            let (process, output, ended) = try startProbe()
            probeProcess = process
            Task {
                let result = await Task.detached { finishProbe(process, output: output, ended: ended) }.value
                if probeProcess === process { probeProcess = nil }
                if operation == token { status = probeCancelled ? "Worker probe cancelled." : result; busy = false }
            }
        } catch {
            status = "Unable to launch the embedded worker: \(error.localizedDescription)"; busy = false
        }
    }
}

private struct Preview: Identifiable { let id: UUID; let title: String; let text: String }

private struct IntakeView: View {
    @Bindable var model: IntakeModel
    @State private var dropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            directoryRow("Libro workspace:", selection: model.workspace, role: .workspace)
            directoryRow("Save audio to:", selection: model.output, role: .output)
            if model.documents.isEmpty {
                ContentUnavailableView("Add documents", systemImage: "doc.badge.plus", description: Text("Drop TXT, Markdown, RTF, PDF files, or folders. Subfolders are included."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.documents, selection: $model.selection) {
                    TableColumn("Document") { document in
                        VStack(alignment: .leading) {
                            Text(document.source.lastPathComponent)
                            Text((document.relativePath as NSString).deletingLastPathComponent).font(.caption).foregroundStyle(.secondary)
                        }.help(document.source.path)
                    }
                    TableColumn("Type") { Text($0.kind.rawValue.uppercased()) }.width(70)
                    TableColumn("Output name") { document in
                        TextField("Relative WAV name", text: Binding(get: { model.names[document.id] ?? BatchPlanner.defaultOutput(document) }, set: { model.names[document.id] = $0; model.replan() }))
                            .accessibilityLabel("Output name for \(document.source.lastPathComponent)")
                    }
                    TableColumn("Status") { Text(model.states[$0.id] ?? "Queued") }
                    TableColumn("Preview") { document in
                        Button("Read Text") { model.showPreview(document) }.disabled(model.busy)
                            .accessibilityLabel("Preview text of \(document.source.lastPathComponent)")
                    }.width(90)
                }
            }
            if let error = model.planningError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            if model.planning { ProgressView("Checking output destinations…").controlSize(.small) }
            if model.planned.contains(where: \.replacesExisting) {
                Label("\(model.planned.filter(\.replacesExisting).count) existing WAVs share these destinations. Replacement confirmation will be required before generation.", systemImage: "doc.on.doc")
            }
            if !model.issues.isEmpty {
                DisclosureGroup("Input errors (\(model.issues.count))") {
                    ScrollView { ForEach(Array(model.issues.enumerated()), id: \.offset) { _, issue in
                        Text("\(issue.source.lastPathComponent): \(issue.message)").frame(maxWidth: .infinity, alignment: .leading)
                    } }.frame(maxHeight: 100)
                }
            }
            HStack {
                if model.busy { ProgressView().controlSize(.small).accessibilityLabel(model.activityStatus); Button("Cancel") { model.cancel() }.disabled(!model.cancellable) }
                Text(model.activityStatus).font(.callout).textSelection(.enabled)
                Spacer()
                Button("Verify Embedded Worker") { model.probe() }.disabled(model.busy || model.hasOwnedProbe)
            }
            Text("Review inputs and output names. Speech generation is unavailable in this build.").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 8).stroke(.tint, lineWidth: 3).padding(4).allowsHitTesting(false) } }
        .dropDestination(for: URL.self) { urls, _ in model.add(urls); return !urls.isEmpty } isTargeted: { dropTarget = $0 }
        .toolbar {
            Button("Add Files…", systemImage: "doc.badge.plus") { model.openInputs() }
            Button("Add Folder…", systemImage: "folder.badge.plus") { model.openInputs(foldersOnly: true) }
            Button("Remove Selected", systemImage: "minus") { model.removeSelected() }.disabled(model.selection.isEmpty || model.busy)
            Button("Clear Queue") { model.clear() }.disabled(model.documents.isEmpty || model.busy)
        }
        .sheet(item: $model.preview) { preview in
            VStack(alignment: .leading, spacing: 12) {
                Text(preview.title).font(.headline)
                Text("PDF reading order and repeated headers may need review.").font(.caption).foregroundStyle(.secondary)
                ScrollView { Text(preview.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Button("Done") { model.preview = nil }.keyboardShortcut(.defaultAction)
            }.padding().frame(minWidth: 560, minHeight: 420)
                .onExitCommand { model.preview = nil }
        }
    }

    private func directoryRow(_ label: String, selection: DirectorySelection?, role: DirectoryRole) -> some View {
        HStack(alignment: .top) {
            Text(label).frame(width: 125, alignment: .leading)
            VStack(alignment: .leading) {
                Text(selection?.displayPath ?? "Choose a folder…").textSelection(.enabled)
                    .lineLimit(2).help(selection?.displayPath ?? label)
                    .accessibilityLabel("\(label) \(selection?.displayPath ?? "No folder selected")")
                if let error = selection?.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let url = selection?.url { Button("Reveal") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path) } }
            Button("Browse…") { model.browse(role) }.disabled(model.busy).accessibilityLabel("Browse for \(role.rawValue) folder")
        }
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
                window.setFrameAutosaveName("Libro.main")
            }
        }
    }
}

private func startProbe() throws -> (Process, Pipe, DispatchSemaphore) {
    let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LibroSpeechWorker")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw CocoaError(.executableNotLoadable) }
    let process = Process()
    let output = Pipe()
    process.executableURL = executable; process.arguments = ["--probe"]
    process.standardOutput = output; process.standardError = FileHandle.nullDevice
    let ended = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in ended.signal() }
    try process.run()
    return (process, output, ended)
}

private func finishProbe(_ process: Process, output: Pipe, ended: DispatchSemaphore) -> String {
    // The known probe emits one small control record, with library output
    // redirected to stderr. Bound its lifetime before reading that record.
    if ended.wait(timeout: .now() + 15) == .timedOut {
        if process.isRunning { process.terminate() }
        if ended.wait(timeout: .now() + 1) == .timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        return "Worker probe timed out."
    }
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard data.count <= 65_536 else { return "Worker probe returned an invalid record." }
    guard process.terminationStatus == 0 else { return "Worker probe failed (\(process.terminationStatus))." }
    return "Embedded worker: Metal ready\n" + (String(data: data, encoding: .utf8) ?? "")
}
