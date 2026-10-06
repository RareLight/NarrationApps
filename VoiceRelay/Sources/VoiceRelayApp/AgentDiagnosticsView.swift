import SwiftUI
import Observation
import VoiceRelayCore

@MainActor @Observable
final class AgentDiagnosticsModel {
    var checking = false
    var snapshot: AgentSnapshot?
    var error: String?
    @ObservationIgnored let inert: Bool
    @ObservationIgnored private let client: AgentClient
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(inert: Bool = false, client: AgentClient? = nil) {
        self.inert = inert
        self.client = client ?? AgentClient()
    }
    func check() {
        guard !inert, !checking else { return }
        let token = UUID(); generation = token
        checking = true; snapshot = nil; error = nil
        task = Task {
            defer { if generation == token { checking = false; task = nil } }
            do {
                let result = try await client.snapshot(timeout: .seconds(5))
                guard generation == token else { return }
                snapshot = result
            } catch is CancellationError {
            } catch let failure as AgentClientFailure {
                guard generation == token else { return }
                self.error = failure.message
            } catch let failure as AgentFailure {
                guard generation == token else { return }
                self.error = failure.message
            } catch {
                guard generation == token else { return }
                self.error = "The agent check failed."
            }
        }
    }
    func cancel() {
        generation = UUID()
        task?.cancel(); task = nil
        client.cancel()
        checking = false; snapshot = nil; error = nil
    }
    func waitForCheck() async { if let task { await task.value } }
}

struct AgentDiagnosticsView: View {
    @State private var model: AgentDiagnosticsModel
    init(inert: Bool) { _model = State(initialValue: AgentDiagnosticsModel(inert: inert)) }
    init(model: AgentDiagnosticsModel) { _model = State(initialValue: model) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent connection").font(.headline)
            HStack {
                Button("Check agent connection") { model.check() }.disabled(model.checking)
                if model.checking {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancel() }
                }
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
            }
            if let snapshot = model.snapshot {
                Text("Last read-only snapshot").font(.subheadline)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow { Text("Saved articles"); Text("\(snapshot.articles)") }
                    GridRow { Text("Queue waiting"); Text("\(snapshot.waiting)") }
                    GridRow { Text("Queue processing"); Text("\(snapshot.processing)") }
                    GridRow { Text("Queue paused"); Text("\(snapshot.paused)") }
                    GridRow { Text("Queue failed"); Text("\(snapshot.failed)") }
                    GridRow { Text("Queue completed"); Text("\(snapshot.completed)") }
                }.font(.callout)
            }
            Text("The app still owns speech and audio cleanup; no settings are transferred and no service is enrolled. An explicit check may wake an already enrolled read-only listener, and repeating it makes an explicit fresh connection. Persisted processing counts are not evidence of an active worker.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(EdgeInsets(top: 16, leading: 20, bottom: 0, trailing: 20))
            .frame(maxWidth: .infinity, alignment: .leading)
            .onDisappear { model.cancel() }
    }
}

#if DEBUG
#Preview("Agent diagnostics — inert unchecked") { AgentDiagnosticsView(inert: true) }
#Preview("Agent diagnostics — synthetic unavailable") {
    let model = AgentDiagnosticsModel(inert: true)
    model.error = AgentClientFailure.unavailable.message
    return AgentDiagnosticsView(model: model)
}
#endif
