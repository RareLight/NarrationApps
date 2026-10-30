import Foundation
import NarrationCore
import NativeSpeech
import Pronunciation

public enum NarrationReviewRepair {
    /// Explicit continuation of an incomplete retained take. Each missing chunk
    /// is attempted once; verified existing PCM and the original take survive.
    public static func fillMissing(store: NarrationReviewStore, id: UUID, configuration: WorkerConfiguration, workspace: URL) async throws -> UUID {
        let original = try store.load(id)
        guard !original.complete else { throw SpeechFailure(.invalidInput) }
        var settings = original.plan.settings; settings.retainReview = nil
        let session = try NativeSpeechSession(configuration: configuration, workspace: workspace, settings: settings,
            leaseFile: configuration.inferenceLeaseFile, policy: original.plan.policy)
        var take: UUID?
        do {
            try await session.prepare()
            var utterances: [PreparedUtterance] = [], reused: [Int?] = []
            let currentIdentity = SpeechAcousticIdentity.make(settings: settings, policy: .selected(settings: settings, requested: original.plan.policy))
            for (index, passage) in original.plan.utterances.enumerated() {
                if original.artifacts[index] != nil {
                    utterances.append(passage); reused.append(index)
                } else if settings.model == .kokoro && passage.acousticIdentity != currentIdentity {
                    let replacements = try await reprepare(passage, session: session)
                    utterances += replacements; reused += Array(repeating: nil, count: replacements.count)
                } else { utterances.append(passage); reused.append(nil) }
            }
            let plan = PreparedSpeechPlan(policy: original.plan.policy, settings: original.plan.settings,
                semanticVersion: original.plan.semanticVersion, acousticIdentity: original.plan.acousticIdentity,
                utterances: utterances, notices: original.plan.notices + ["Explicitly generated missing passages with current preparation; verified existing PCM reused. Per-passage acoustic identities are retained."],
                provenance: original.plan.provenance, documentTitle: original.plan.documentTitle)
            let created = try store.begin(plan: plan); take = created
            var bytes: Int64 = 0
            for index in plan.utterances.indices {
                try Task.checkCancellation()
                let samples: [Float]
                if let source = reused[index] { samples = try store.samples(id, index: source, record: original) }
                else { samples = try await session.renderReviewChunk(plan.utterances[index]) }
                try store.record(created, index: index, samples: samples, plan: plan, existingBytes: bytes)
                bytes += Int64(samples.count) * 4
            }
            await session.close(); try Task.checkCancellation(); return created
        } catch { await session.close(); if let take { try? store.remove(take) }; throw error }
    }
    /// New private take, reusing verified PCM for every unselected chunk. The old
    /// take and any published audio remain untouched, even on cancellation/failure.
    public static func regenerate(store: NarrationReviewStore, id: UUID, index: Int, configuration: WorkerConfiguration,
                                  workspace: URL, splitAtSentences: Bool = false, pronunciations: PronunciationDictionary? = nil) async throws -> UUID {
        let original = try store.load(id)
        guard original.complete, original.plan.utterances.indices.contains(index) else { throw SpeechFailure(.invalidInput) }
        var settings = original.plan.settings; settings.retainReview = nil
        if splitAtSentences { settings.planning = .semanticCandidate }
        let policy = SpeechPreparationPolicy.selected(settings: settings, requested: original.plan.policy)
        let session = try NativeSpeechSession(configuration: configuration, workspace: workspace, settings: settings,
            leaseFile: configuration.inferenceLeaseFile, policy: policy)
        let selected = original.plan.utterances[index]
        do {
            try await session.prepare()
            let replacements: [PreparedUtterance]
            if let pronunciations {
                // Undo captured aliases only where the complete range belongs to
                // this passage. Never reconstruct a partial word by guessing.
                var text = selected.text
                for application in (selected.source.pronunciationApplications ?? []).reversed() {
                    let offset = application.spokenLocation - selected.source.location
                    guard offset >= 0, offset + application.spokenLength <= text.utf16.count,
                          let range = Range(NSRange(location: offset, length: application.spokenLength), in: text),
                          String(text[range]) == application.spelling else { throw SpeechFailure(.textPreparation) }
                    text.replaceSubrange(range, with: application.word)
                }
                let document = SemanticDocument(title: original.plan.documentTitle,
                    blocks: [.init(kind: .paragraph, text: text, origin: selected.source.origin)], extractorVersion: "explicit-pronunciation-repair-1")
                let projected = try NarrationPlanner.prepareForSpeech(document, settings: settings, pronunciations: pronunciations, policy: policy)
                let replacementPlan = try await session.prepareSpeech(projected)
                replacements = replacementPlan.utterances.enumerated().map { index, value in
                    PreparedUtterance(text: value.text, phonemes: value.phonemes, tokenCount: value.tokenCount,
                        source: .init(blockIndices: selected.source.blockIndices, location: value.source.location,
                            length: value.source.length, origin: selected.source.origin, pronunciationApplications: value.source.pronunciationApplications),
                        boundaryAfter: index == replacementPlan.utterances.count - 1 ? selected.boundaryAfter : value.boundaryAfter,
                        acousticIdentity: value.acousticIdentity)
                }
            } else if splitAtSentences || (settings.model == .kokoro && selected.acousticIdentity != SpeechAcousticIdentity.make(settings: settings, policy: policy)) {
                replacements = try await reprepare(selected, session: session)
            } else { replacements = [selected] }
            try Task.checkCancellation()
            let utterances = Array(original.plan.utterances[..<index]) + replacements + Array(original.plan.utterances[(index + 1)...])
            let plan = PreparedSpeechPlan(policy: original.plan.policy, settings: original.plan.settings,
                semanticVersion: original.plan.semanticVersion + "/explicit-repair-1", acousticIdentity: original.plan.acousticIdentity,
                utterances: utterances, notices: original.plan.notices + ["Explicitly regenerated passage \(index + 1); unchanged PCM reused. Per-passage acoustic identities are retained." + (pronunciations == nil ? "" : " Current pronunciation rules were explicitly applied; this edited passage has no inferred original-coordinate map.")], provenance: original.plan.provenance, documentTitle: original.plan.documentTitle)
            let take = try store.begin(plan: plan)
            do {
                var bytes: Int64 = 0
                for position in utterances.indices {
                    try Task.checkCancellation()
                    let samples: [Float]
                    if position < index { samples = try store.samples(id, index: position, record: original) }
                    else if position < index + replacements.count { samples = try await session.renderReviewChunk(replacements[position - index]) }
                    else { samples = try store.samples(id, index: position - replacements.count + 1, record: original) }
                    try store.record(take, index: position, samples: samples, plan: plan, existingBytes: bytes)
                    bytes += Int64(samples.count) * 4
                }
                await session.close(); try Task.checkCancellation()
                return take
            } catch { try? store.remove(take); throw error }
        } catch { await session.close(); throw error }
    }

    /// Reuse captured spoken text/rules, but apply the current mandatory packing
    /// when generating a historical Kokoro passage. Unchanged PCM stays historical.
    private static func reprepare(_ passage: PreparedUtterance, session: NativeSpeechSession) async throws -> [PreparedUtterance] {
        let offset = passage.source.location
        let projection = NarrationPlan(version: "explicit-repair-1/spoken-projection-1", chunks: [
            .init(index: 0, text: passage.text, blockIndices: passage.source.blockIndices, boundaryAfter: passage.boundaryAfter,
                origin: passage.source.origin,
                pronunciationApplications: passage.source.pronunciationApplications?.map { $0.shiftedSpoken(by: -offset) },
                sourceMappings: passage.source.sourceMappings?.map { $0.shiftedSpoken(by: -offset) })
        ], notices: [])
        return try await session.prepareSpeech(projection).utterances.map { value in
            .init(text: value.text, phonemes: value.phonemes, tokenCount: value.tokenCount,
                source: .init(blockIndices: value.source.blockIndices, location: value.source.location + offset,
                    length: value.source.length, origin: value.source.origin,
                    pronunciationApplications: value.source.pronunciationApplications?.map { $0.shiftedSpoken(by: offset) },
                    sourceMappings: value.source.sourceMappings?.map { $0.shiftedSpoken(by: offset) }),
                boundaryAfter: value.boundaryAfter, acousticIdentity: value.acousticIdentity)
        }
    }
}
