import Foundation

#if canImport(FoundationXML)
import FoundationXML
#endif

/// Only this namespace's source hash is an original Reading List identity; titles
/// and canonical links are not interchangeable with it.
enum ServerRecoveryIdentity {
    static let namespace = "urn:voicerelay:recovery:1"
    static func validSource(_ value: String) -> Bool {
        value.hasPrefix("reviewed-url-v1-") && validHash(String(value.dropFirst(16)))
    }
    static func validHash(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct ServerRecoveryReport: Sendable {
    let verifiedCopies: Int
    let publishedCopies: Int
    let recoveredEpisodes: Int
    let unmatchedEpisodes: Int
    let missingCopies: Int
    let inspectedAt = Date()
    let checkedAt: Date
    let destination: DeliverySettings
    let feed: Data?
    let updates: [RecoveryUpdate]
    let publishedHashes: [String: String]
    var issues: [String] = []
    var blockedIDs: Set<String> = []
    var proofs: [String: ServerAudioProof] = [:]
    var preservedItems: [String] = []
    var feedETag: String?
    var expectedRecords: [String: String] = [:]
    var rawItems: [String: [String]] = [:]
}

struct RecoveryUpdate: Sendable {
    let previousID: String?
    let sourceKey: String
    let episode: Episode
}

struct ServerFeedItem: Sendable {
    let id: String
    let title: String
    let source: URL?
    let date: Date
    let length: Int64
    let enclosureURL: URL
    let duration: Double
    let originalIdentity: String?
    let audioHash: String?
    let savedAt: Date?
    let publishedAt: Date?
    let origin: String?
    let author: String?
    let artwork: URL?
    let voice: String?
    let speed: Double?
    var transcripts: [PodcastTranscriptReference] = []
}

/// Bounded, namespace-aware RSS parser. No external entities, DTDs, title matching,
/// arbitrary enclosure downloads, or server-supplied local paths.
final class ServerFeedParser: NSObject, XMLParserDelegate {
    private var path: [String] = []
    private var text = ""
    private var fields: [String: String] = [:]
    private var enclosure: [String: String] = [:]
    private var identity: [String: String] = [:]
    private var artwork: String?
    private var transcripts: [PodcastTranscriptReference] = []
    private var channelCount = 0
    private var items: [ServerFeedItem] = []
    private var invalid = false
    static func parse(_ data: Data) throws -> [ServerFeedItem] {
        guard data.count <= 4 * 1024 * 1024, let xml = String(data: data, encoding: .utf8),
              !xml.uppercased().contains("<!DOCTYPE"), !xml.uppercased().contains("<!ENTITY") else { throw failure }
        let delegate = ServerFeedParser(), parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, delegate.channelCount == 1, delegate.path.isEmpty,
              Set(delegate.items.map(\.id)).count == delegate.items.count else { throw failure }
        return delegate.items
    }
    static var failure: DeliveryError { .fatal("The server feed cannot be safely reconciled. Its files and the local library are unchanged.") }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        path.append(elementName); text = ""
        if path == ["rss", "channel", "item"] { fields = [:]; enclosure = [:]; identity = [:]; artwork = nil; transcripts = [] }
        if path == ["rss", "channel", "item", "transcript"], namespaceURI == PodcastTranscriptReference.namespace {
            if let raw = attributes["url"], let url = URL(string: raw), let type = attributes["type"] {
                let reference = PodcastTranscriptReference(url: url, type: type, language: attributes["language"], rel: attributes["rel"])
                if (try? reference.validate()) == nil || transcripts.count >= 8 { invalid = true }
                else { transcripts.append(reference) }
            } else { invalid = true }
        }
        if path == ["rss", "channel", "item", "enclosure"] {
            if !enclosure.isEmpty { invalid = true }; enclosure = attributes
        }
        if path == ["rss", "channel", "item", "identity"], namespaceURI == ServerRecoveryIdentity.namespace {
            if !identity.isEmpty { invalid = true }; identity = attributes
        }
        if path == ["rss", "channel"] { channelCount += 1 }
        if path == ["rss", "channel", "item", "image"], namespaceURI == "http://www.itunes.com/dtds/podcast-1.0.dtd" {
            if artwork != nil { invalid = true }; artwork = attributes["href"]
        }
        if path.count == 1 && (elementName != "rss" || attributes["version"] != "2.0") { invalid = true }
        if path.count == 2 && elementName != "channel" { invalid = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if path.count == 4, path.prefix(3) == ["rss", "channel", "item"],
           ["guid", "title", "link", "pubDate", "duration", "creator"].contains(elementName) {
            if fields[elementName] != nil { invalid = true }
            fields[elementName] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if path == ["rss", "channel", "item"] {
            do { items.append(try item()); if items.count > 10_000 { invalid = true } }
            catch { invalid = true }
        }
        path.removeLast(); text = ""
    }
    private func item() throws -> ServerFeedItem {
        guard let id = fields["guid"], UUID(uuidString: id) != nil, id == id.lowercased(),
              let title = fields["title"], !title.isEmpty, title.count <= 4096,
              let raw = enclosure["url"], let url = URL(string: raw),
              url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.lastPathComponent == id + ".m4a", enclosure["type"] == "audio/mp4",
              let rawLength = enclosure["length"], let length = DeliveryResponse.byteCount(rawLength),
              length > 0, length <= 512 * 1024 * 1024,
              let rawDate = fields["pubDate"] else { throw Self.failure }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        guard let date = formatter.date(from: rawDate) else { throw Self.failure }
        let source = fields["link"].flatMap(URL.init(string:))
        if fields["link"] != nil { guard let source, (try? ArticleURL.validate(source)) != nil else { throw Self.failure } }
        let duration = fields["duration"].flatMap(Double.init) ?? 0
        guard duration.isFinite, duration >= 0 else { throw Self.failure }
        let key = identity["source"], hash = identity["sha256"]
        if !identity.isEmpty {
            guard let hash, ServerRecoveryIdentity.validHash(hash),
                  key == nil || ServerRecoveryIdentity.validSource(key!) else { throw Self.failure }
        }
        let saved = identity["savedAt"].flatMap { ISO8601DateFormatter().date(from: $0) }
        if identity["savedAt"] != nil && saved == nil { throw Self.failure }
        let published = identity["publishedAt"].flatMap { ISO8601DateFormatter().date(from: $0) }
        if identity["publishedAt"] != nil && published == nil { throw Self.failure }
        let speed = identity["speed"].flatMap(Double.init)
        if identity["speed"] != nil { guard let speed, speed.isFinite, (0.25...4).contains(speed) else { throw Self.failure } }
        let art = artwork.flatMap(URL.init(string:))
        if let art { guard art.scheme == "https", (try? ArticleURL.validate(art)) != nil else { throw Self.failure } }
        if artwork != nil && art == nil { throw Self.failure }
        return ServerFeedItem(id: id, title: title, source: source, date: date, length: length, enclosureURL: url,
            duration: duration, originalIdentity: key, audioHash: hash, savedAt: saved, publishedAt: published, origin: identity["origin"], author: fields["creator"], artwork: art,
            voice: identity["voice"], speed: speed, transcripts: transcripts)
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName: String, value: String?) { invalid = true; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName: String, publicID: String?, systemID: String?) { invalid = true; parser.abortParsing() }
}

/// Invalid individual items survive feed updates; malformed XML/DTDs still stop
/// feed mutation, without stopping unrelated media work.
struct ServerFeedSnapshot {
    var channelArtworkURL: URL?
    var items: [ServerFeedItem] = []
    var rawItems: [String: [String]] = [:]
    var invalidItems: [String] = []
    var invalidIDs = Set<String>()
    init() {}
    private static func cover(in channel: XMLElement) throws -> URL? {
        let covers = channel.children?.compactMap { $0 as? XMLElement }.filter {
            $0.localName == "image" && $0.uri == "http://www.itunes.com/dtds/podcast-1.0.dtd"
        } ?? []
        guard covers.count <= 1 else { throw ServerFeedParser.failure }
        guard let raw = covers.first?.attribute(forName: "href")?.stringValue else { return nil }
        guard let url = URL(string: raw), (try? ArticleURL.validate(url)) != nil, url.scheme == "https" else { throw ServerFeedParser.failure }
        return url
    }
    /// Metadata-only lookup avoids revalidating every episode while rendering a feed.
    static func channelArtwork(in data: Data) throws -> URL? {
        guard data.count <= 4 * 1024 * 1024, let text = String(data: data, encoding: .utf8),
              !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else { throw ServerFeedParser.failure }
        let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        guard let root = document.rootElement(), root.name == "rss", root.elements(forName: "channel").count == 1 else { throw ServerFeedParser.failure }
        return try cover(in: root.elements(forName: "channel")[0])
    }
    init(_ data: Data) throws {
        guard data.count <= 4 * 1024 * 1024, let text = String(data: data, encoding: .utf8),
              !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else { throw ServerFeedParser.failure }
        let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        guard let root = document.rootElement(), root.name == "rss", root.attribute(forName: "version")?.stringValue == "2.0",
              root.elements(forName: "channel").count == 1 else { throw ServerFeedParser.failure }
        let channel = root.elements(forName: "channel")[0]
        channelArtworkURL = try Self.cover(in: channel)
        let nodes = channel.elements(forName: "item")
        guard nodes.count <= 10_000 else { throw ServerFeedParser.failure }
        var candidates: [(ServerFeedItem?, String, String?)] = []
        for node in nodes {
            let copy = node.copy() as! XMLElement
            for namespace in (root.namespaces ?? []) + (channel.namespaces ?? []) { copy.addNamespace(namespace.copy() as! XMLNode) }
            let raw = copy.xmlString
            let id = node.elements(forName: "guid").first?.stringValue
            let wrapped = Data(("<rss version=\"2.0\"><channel>" + raw + "</channel></rss>").utf8)
            let parsed = try? ServerFeedParser.parse(wrapped).first
            candidates.append((parsed, raw, id))
            if let id { rawItems[id, default: []].append(raw) }
        }
        for (item, raw, id) in candidates {
            if let item, rawItems[item.id]?.count == 1 { items.append(item) }
            else { invalidItems.append(raw); if let id, UUID(uuidString: id) != nil { invalidIDs.insert(id) } }
        }
    }
}

extension FixtureCoordinator {
    /// Cheap cadence/backoff gate precedes Keychain and network access. Reentrant
    /// delivery during inference uses recorded proofs and defers metadata rekeying.
    func reconcileServerAutomatically(storage: ManagedSpeechStorage, settings: DeliverySettings,
        credential: any DeliveryCredentialStore, transport: any DeliveryTransport,
        force: Bool, reconcileNow: Bool = false, now: Date, debugLog: DeliveryDebugLog?) async throws {
        let root = storage.stateRoot.resolvingSymlinksInPath().standardizedFileURL.path
        guard !activeDrainRoots.contains(root), !activeDeliveryRoots.contains(root) else {
            debugLog?.record(.reconciliation(.deferred)); return
        }
        var ledger = try DeliveryLedger.load(stateRoot: storage.stateRoot)
        let queueIDs: [String]
        if FileManager.default.fileExists(atPath: storage.profile.database.path) {
            queueIDs = try NativeStore(url: storage.profile.database, readOnly: true).queue().map { $0.id + ":" + $0.state.rawValue }.sorted()
        } else { queueIDs = [] }
        let due = ledger.destinationURL != settings.feedFolderURL || ledger.reconciliationAttemptAt == nil
            || now.timeIntervalSince(ledger.reconciliationAttemptAt!) >= 300
            || (ledger.reconciledAt != nil && ledger.reconciledQueueIDs != queueIDs)
        // Launch checks the current feed even after a recent session, while retaining
        // media proofs and ordinary upload retry deadlines. Force also rechecks bytes.
        guard force || reconcileNow || due else { debugLog?.record(.reconciliation(.unchanged)); return }
        // Establish library ownership before the first ledger write makes its root
        // nonempty. A fresh installation must remain a valid managed library.
        _ = try ManagedSpeechStorage.prepareLibrary(stateRoot: storage.stateRoot)
        ledger.reconciliationAttemptAt = now
        try ledger.save(stateRoot: storage.stateRoot)
        debugLog?.record(.reconciliation(.started))
        do {
            let report = try await inspectServerAudio(storage: storage, settings: settings, credential: credential,
                transport: transport, now: now, force: force, debugLog: debugLog)
            try applyServerAudioRecovery(report, storage: storage, settings: settings, debugLog: debugLog)
            debugLog?.record(.reconciliation(.finished))
        } catch is CancellationError { throw CancellationError() }
        catch {
            debugLog?.recordFailure(error)
            ledger = try DeliveryLedger.load(stateRoot: storage.stateRoot)
            ledger.reconciliationError = "Server reconciliation could not finish; other processing continues and the check will retry automatically."
            if let failure = error as? DeliveryError {
                switch failure {
                case .authFailed: ledger.reconciliationError = DeliveryError.authNotice
                case .credentialUnavailable: ledger.reconciliationError = DeliveryError.credentialNotice
                case .permissionDenied: ledger.reconciliationError = DeliveryError.permissionNotice
                default: break
                }
            }
            // Preserve the unreadable/concurrently changing feed, but independent
            // complete media can still upload to confirmed-missing opaque paths.
            ledger.serverFeedUnsafe = true
            try ledger.save(stateRoot: storage.stateRoot)
        }
    }

    /// Scanning and applying are separate internal phases so a changing local library
    /// never receives a stale plan. The app invokes both automatically, not as UI actions.
    func inspectServerAudio(storage: ManagedSpeechStorage, settings: DeliverySettings,
        credential: any DeliveryCredentialStore, transport: any DeliveryTransport,
        now: Date = Date(), force: Bool = false, debugLog: DeliveryDebugLog? = nil) async throws -> ServerRecoveryReport {
        try requireIdleLibrary(storage); try storage.validate()
        let root = storage.stateRoot.resolvingSymlinksInPath().standardizedFileURL.path
        guard activeDeliveryRoots.insert(root).inserted else { throw RelayError.writerBusy }
        defer { activeDeliveryRoots.remove(root) }
        let exists = FileManager.default.fileExists(atPath: storage.profile.database.path)
        let lease = exists ? try PipelineLease(database: storage.profile.database) : nil
        defer { lease?.release() }
        let settings = try settings.normalized(); try settings.validate()
        let (episodes, keys, catalog, expectedRecords) = try recoveryLibrary(storage)
        var issues: [String] = [], blocked = Set<String>()
        let legacyKeys = try recoveryLegacyKeys(storage: storage, episodes: episodes, keys: keys, catalog: catalog)
        let oldLedger = try DeliveryLedger.load(stateRoot: storage.stateRoot, preserveCorrupt: false)
        let sameDestination = oldLedger.destinationURL == settings.feedFolderURL
        let client = try WebDAVClient(transport: transport, settings: settings, credential: credential, debugLog: debugLog)
        let response = try await client.readFeed(ifNoneMatch: sameDestination ? oldLedger.reconciledFeedETag : nil)
        let feed: Data?
        if response.status == 304 {
            guard let cached = oldLedger.reconciledFeed else { throw ServerFeedParser.failure }
            feed = cached
        } else { feed = response.status == 404 ? nil : response.body }
        let snapshot = try feed.map(ServerFeedSnapshot.init) ?? ServerFeedSnapshot()
        var proofs = sameDestination ? oldLedger.serverAudioProofs ?? [:] : [:]
        let sameFeed = !force && sameDestination && feed == oldLedger.reconciledFeed
        let byID = Dictionary(uniqueKeysWithValues: episodes.map { ($0.id, $0) })
        let byKey = Dictionary(episodes.compactMap { e in keys[e.id].map { ($0, e) } }, uniquingKeysWith: { first, _ in first })
        let entries = Dictionary(catalog.entries.map { (Self.recoveryKey($0.url), $0) }, uniquingKeysWith: { first, _ in first })
        var updates: [RecoveryUpdate] = [], publishedHashes: [String: String] = [:]
        var claimedKeys = Set<String>(), missing = 0, unmatched = 0, recovered = 0
        var winners: [String: (proof: ServerAudioProof, voice: String?, speed: Double?)] = [:]
        var preserved = snapshot.invalidItems
        issues += snapshot.invalidItems.map { _ in "One server feed entry is invalid; its membership was preserved." }
        blocked.formUnion(snapshot.invalidIDs)
        var encountered = Set<String>()
        let orderedItems = snapshot.items.sorted {
            let left = byID[$0.id]?.delivery?.status == .uploaded
            let right = byID[$1.id]?.delivery?.status == .uploaded
            return left != right ? left : $0.id < $1.id
        }
        for item in orderedItems {
            try Task.checkCancellation(); encountered.insert(item.id)
            let sameID = byID[item.id]
            var key = item.originalIdentity
            var local: Episode? = sameID
            do {
                if key == nil, let source = item.source {
                    let candidates = legacyKeys[source.absoluteString] ?? []
                    guard candidates.count <= 1 else {
                        for candidate in candidates { if let e = byKey[candidate] { blocked.insert(e.id) } }
                        throw Self.recoveryConflict
                    }
                    key = candidates.first ?? Self.recoveryKey(source)
                }
                if let sameID {
                    if let suppliedKey = key, suppliedKey != keys[sameID.id] {
                        if keys[sameID.id] == "superseded-episode-v1-" + sameID.id,
                           sameID.originalSourceIdentity == suppliedKey {
                            // Intentional generations share original identity, never the
                            // unique database slot or the successor's captured settings.
                        } else {
                            guard keys[sameID.id]?.hasPrefix("remote-episode-v1-") == true,
                                  entries[suppliedKey]?.url == item.source else { throw Self.recoveryConflict }
                        }
                        key = keys[sameID.id]
                    } else { key = keys[sameID.id] }
                }
                let originalIdentity = key.flatMap { ServerRecoveryIdentity.validSource($0) ? $0 : nil }
                local = sameID ?? key.flatMap { byKey[$0] }
                let intentionalPredecessor = sameID == nil && local?.replacesDuplicateAudio == true
                if intentionalPredecessor {
                    // A fresh explicit generation must not be replaced by a different
                    // older server GUID, even when their original URL is identical.
                    key = "superseded-episode-v1-" + item.id
                    local = nil
                }
                if let local, local.stage == .expired || local.manualAudioDeletionRequested == true {
                    continue // Explicit retirement always wins over rediscovery.
                }
                if item.originalIdentity == nil, sameID == nil, local == nil, !intentionalPredecessor, key.flatMap({ entries[$0] }) == nil {
                    key = "remote-episode-v1-" + item.id; unmatched += 1
                }
                let sourceKey = key ?? "remote-episode-v1-" + item.id
                claimedKeys.insert(sourceKey)
                let proof: ServerAudioProof?
                do {
                    proof = try await verifiedServerCopy(id: item.id, hint: item, cached: proofs[item.id],
                        sameFeed: sameFeed, allowFreshProof: !force, client: client, profile: storage.profile, now: now)
                } catch is InvalidServerAudio {
                    guard let local, let valid = try await validatedLocalCopy(local, storage: storage) else { throw InvalidServerAudio() }
                    let winner = try Self.pendingReplacement(local, info: valid, conflictingID: item.id, settings: settings)
                    updates.append(RecoveryUpdate(previousID: local.id, sourceKey: sourceKey, episode: winner))
                    proofs.removeValue(forKey: item.id)
                    debugLog?.record(.reconciliation(.localPreferred)); continue
                }
                guard let proof else {
                    missing += 1; proofs.removeValue(forKey: item.id)
                    if var local, local.audioHash != nil, local.info != nil {
                        local.delivery = DeliveryState(status: .pending, remotePath: settings.remoteMediaPath(local.id))
                        local.delivery?.destinationURL = settings.feedFolderURL
                        updates.append(RecoveryUpdate(previousID: local.id, sourceKey: sourceKey, episode: local))
                    } else { throw DeliveryError.retryable("A listed server copy is missing and no complete local copy is available.") }
                    continue
                }
                proofs[item.id] = proof
                if let winner = winners[sourceKey],
                   winner.voice != item.voice || winner.speed != item.speed || winner.proof.info.duration >= proof.info.duration - 0.5 { continue }
                if winners[sourceKey] != nil {
                    for old in updates.filter({ $0.sourceKey == sourceKey }) { publishedHashes.removeValue(forKey: old.episode.id) }
                    updates.removeAll { $0.sourceKey == sourceKey }
                }
                winners[sourceKey] = (proof, item.voice, item.speed)
                if proof.hash != item.audioHash && item.audioHash != nil || proof.info.byteLength != item.length {
                    debugLog?.record(.reconciliation(.metadataRepaired))
                }
                if let local, local.audioHash != proof.hash,
                   (item.voice == nil || item.voice == local.settings.voice),
                   (item.speed == nil || abs(item.speed! - (local.settings.backendSettings["speed"]?.numericValue ?? 1)) < 0.001),
                   let info = try await validatedLocalCopy(local, storage: storage),
                   info.duration > proof.info.duration + max(0.5, proof.info.duration * 0.001) {
                    let winner = try Self.pendingReplacement(local, info: info, conflictingID: item.id, settings: settings)
                    updates.append(RecoveryUpdate(previousID: local.id, sourceKey: sourceKey, episode: winner))
                    debugLog?.record(.reconciliation(.localPreferred)); continue
                }
                let entry = entries[sourceKey]
                if local == nil { recovered += 1 }
                var profile = storage.profile; profile.backendSelector = "reviewed-article-speech"
                var episode = try local.map { try Self.reidentified($0, id: item.id) }
                    ?? Episode(id: item.id, title: item.title, stage: .published, settings: profile)
                episode.stage = .published; episode.title = item.title
                episode.publicationDate = episode.publicationDate ?? item.publishedAt ?? item.date
                episode.readingListSavedAt = episode.readingListSavedAt ?? item.savedAt ?? entry?.addedAt
                episode.sourceURL = item.source; episode.sourceHost = item.source?.host
                episode.author = episode.author ?? item.author; episode.artworkURL = episode.artworkURL ?? item.artwork
                episode.originalSourceHost = episode.originalSourceHost ?? entry?.url.host ?? item.origin ?? item.source?.host
                episode.originalSourceIdentity = episode.originalSourceIdentity
                    ?? (ServerRecoveryIdentity.validSource(sourceKey) ? sourceKey : (intentionalPredecessor ? originalIdentity : nil))
                if episode.audioHash != proof.hash { episode.transcript = nil; episode.transcriptReferences = nil }
                var references = item.transcripts
                for reference in episode.transcriptReferences ?? [] where !references.contains(reference) { references.append(reference) }
                episode.transcriptReferences = references
                episode.audioHash = proof.hash; episode.encodedHash = proof.hash; episode.info = proof.info
                episode.localAudioReleased = local?.audioHash != proof.hash || !FileManager.default.fileExists(atPath: episode.settings.audio.appendingPathComponent(episode.id + ".m4a").path)
                episode.audioFinalizationComplete = true
                if let voice = item.voice, SpeechVoice(rawValue: voice) != nil { episode.settings.voice = voice }
                if let speed = item.speed { episode.settings.backendSettings["speed"] = .number(speed) }
                episode.delivery = Self.recoveredDelivery(episode, settings: settings)
                updates.append(RecoveryUpdate(previousID: local?.id, sourceKey: sourceKey, episode: episode))
                if item.enclosureURL == settings.publicAudioBaseURL?.appendingPathComponent(item.id + ".m4a") { publishedHashes[item.id] = proof.hash }
                debugLog?.record(.reconciliation(.serverPreferred))
            } catch is CancellationError { throw CancellationError() }
            catch {
                debugLog?.recordFailure(error); debugLog?.record(.reconciliation(.itemFailed))
                issues.append("One article could not be reconciled; its existing server membership was preserved.")
                blocked.insert(item.id); if let local { blocked.insert(local.id) }
                if let raw = snapshot.rawItems[item.id] { preserved += raw }
            }
        }
        // Uploads interrupted before feed publication still have a provable local identity.
        let replacedIDs = Set(updates.compactMap { $0.previousID != $0.episode.id ? $0.previousID : nil })
        for var episode in episodes where !encountered.contains(episode.id) && !replacedIDs.contains(episode.id)
            && episode.stage != .expired && episode.audioHash != nil && episode.info != nil {
            try Task.checkCancellation()
            do {
                guard let key = keys[episode.id], !claimedKeys.contains(key) else { continue }
                let proof: ServerAudioProof?
                do { proof = try await verifiedServerCopy(id: episode.id, hint: nil, cached: proofs[episode.id],
                    sameFeed: sameFeed, allowFreshProof: !force, client: client, profile: episode.settings, now: now) }
                catch is InvalidServerAudio {
                    guard let info = try await validatedLocalCopy(episode, storage: storage) else { throw InvalidServerAudio() }
                    let replacement = try Self.pendingReplacement(episode, info: info, conflictingID: episode.id, settings: settings)
                    updates.append(RecoveryUpdate(previousID: episode.id, sourceKey: key, episode: replacement))
                    proofs.removeValue(forKey: episode.id); continue
                }
                guard let proof else {
                    proofs.removeValue(forKey: episode.id)
                    if episode.delivery?.status == .uploaded && episode.delivery?.destinationURL == settings.feedFolderURL {
                        episode.delivery?.status = .pending
                        episode.delivery?.uploadedByteLength = nil
                        updates.append(RecoveryUpdate(previousID: episode.id, sourceKey: key, episode: episode))
                    }
                    continue
                }
                if proof.hash != episode.audioHash,
                   let info = try await validatedLocalCopy(episode, storage: storage),
                   info.duration > proof.info.duration + max(0.5, proof.info.duration * 0.001) {
                    let replacement = try Self.pendingReplacement(episode, info: info, conflictingID: episode.id, settings: settings)
                    updates.append(RecoveryUpdate(previousID: episode.id, sourceKey: key, episode: replacement)); continue
                }
                if episode.audioHash != proof.hash { episode.transcript = nil; episode.transcriptReferences = nil }
                episode.audioHash = proof.hash; episode.encodedHash = proof.hash; episode.info = proof.info
                proofs[episode.id] = proof; claimedKeys.insert(key)
                episode.stage = .published; episode.publicationDate = episode.publicationDate ?? now
                episode.audioFinalizationComplete = true; episode.delivery = Self.recoveredDelivery(episode, settings: settings)
                if !FileManager.default.fileExists(atPath: episode.settings.audio.appendingPathComponent(episode.id + ".m4a").path) { episode.localAudioReleased = true }
                updates.append(RecoveryUpdate(previousID: episode.id, sourceKey: key, episode: episode))
            } catch is CancellationError { throw CancellationError() }
            catch { debugLog?.recordFailure(error); issues.append("One unlisted media copy could not be reconciled; other items continued."); blocked.insert(episode.id) }
        }
        var report = ServerRecoveryReport(verifiedCopies: updates.filter { $0.episode.delivery?.status == .uploaded }.count,
            publishedCopies: publishedHashes.count, recoveredEpisodes: recovered, unmatchedEpisodes: unmatched,
            missingCopies: missing, checkedAt: now, destination: settings,
            feed: feed, updates: updates, publishedHashes: publishedHashes)
        let relevantProofIDs = encountered.union(episodes.map(\.id))
        report.issues = issues; report.blockedIDs = blocked; report.proofs = proofs.filter { relevantProofIDs.contains($0.key) }; report.preservedItems = preserved
        report.feedETag = response.header("etag") ?? (response.status == 304 ? oldLedger.reconciledFeedETag : nil)
        report.expectedRecords = expectedRecords; report.rawItems = snapshot.rawItems
        return report
    }
    private static func reidentified(_ episode: Episode, id: String) throws -> Episode {
        guard var record = try JSONSerialization.jsonObject(with: Files.json(episode)) as? [String: Any] else { throw Self.recoveryConflict }
        record["id"] = id
        if episode.id != id {
            record.removeValue(forKey: "transcriptReferences")
            if var transcript = record["transcript"] as? [String: Any] {
                transcript.removeValue(forKey: "delivery"); record["transcript"] = transcript
            }
        }
        return try JSONDecoder().decode(Episode.self, from: JSONSerialization.data(withJSONObject: record))
    }
    private func validatedLocalCopy(_ episode: Episode, storage: ManagedSpeechStorage) async throws -> AudioInfo? {
        guard episode.localAudioDiscarded != true else { return nil }
        guard episode.stage == .published, audioAvailability(episode) == .available,
              let hash = episode.audioHash, let info = episode.info else { return nil }
        let file = episode.settings.audio.appendingPathComponent(episode.id + ".m4a")
        guard (try? Files.hash(file)) == hash else { return nil }
        if episode.audioFinalizationComplete == true { return info }
        let root = storage.temporaryRoot.appendingPathComponent("LocalVerification/" + UUID().uuidString)
        try Files.directory(root); defer { try? FileManager.default.removeItem(at: root) }
        let task = Task.detached {
            let audio = AudioProcessor(settings: episode.settings, toolDirectory: root)
            let inspected = try audio.probe(file, final: true); try audio.decode(file)
            return inspected
        }
        do {
            let inspected = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation(); return inspected
        } catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation(); return nil }
    }
    private static func pendingReplacement(_ local: Episode, info: AudioInfo, conflictingID: String, settings: DeliverySettings) throws -> Episode {
        var winner = local
        if local.id == conflictingID {
            let replacementID = UUID().uuidString.lowercased()
            let source = local.settings.audio.appendingPathComponent(local.id + ".m4a")
            try FileManager.default.copyItem(at: source, to: local.settings.audio.appendingPathComponent(replacementID + ".m4a"))
            winner = try reidentified(local, id: replacementID)
        }
        winner.info = info; winner.audioFinalizationComplete = true
        winner.delivery = DeliveryState(status: .pending, remotePath: settings.remoteMediaPath(winner.id))
        winner.delivery?.destinationURL = settings.feedFolderURL
        winner.localAudioReleased = false
        return winner
    }
    private func verifiedServerCopy(id: String, hint: ServerFeedItem?, cached: ServerAudioProof?, sameFeed: Bool, allowFreshProof: Bool,
        client: WebDAVClient, profile: PrototypeProfile, now: Date) async throws -> ServerAudioProof? {
        if let cached, allowFreshProof,
           (sameFeed || hint?.audioHash == cached.hash),
           (hint == nil || hint?.length == cached.info.byteLength),
           (hint?.audioHash == nil || hint?.audioHash == cached.hash),
           now.timeIntervalSince(cached.checkedAt) < 86_400 { return cached }
        let head = try await client.audioMetadata(id: id)
        if head.status == 404 { return nil }
        if let cached, let etag = head.header("etag"), Self.strongETag(etag), cached.etag == etag,
           head.contentLength == cached.info.byteLength {
            return ServerAudioProof(hash: cached.hash, info: cached.info, etag: etag, checkedAt: now)
        }
        guard let audio = try await client.verifyAudio(id: id, settings: profile) else { return nil }
        guard let info = audio.info,
              info.duration.isFinite, info.duration > 0, info.byteLength == audio.digest.byteLength else { throw InvalidServerAudio() }
        return ServerAudioProof(hash: audio.digest.sha256, info: info, etag: audio.digest.etag, checkedAt: now)
    }
    static func strongETag(_ value: String) -> Bool {
        value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"")
            && value.dropFirst().dropLast().utf8.allSatisfy { $0 >= 0x21 && $0 != 0x22 && $0 != 0x7f }
    }
    static func representationHash(_ value: String?) -> String? {
        let values = value?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("sha-256=:") && $0.hasSuffix(":") } ?? []
        guard values.count == 1, let bytes = Data(base64Encoded: String(values[0].dropFirst(9).dropLast())), bytes.count == 32 else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    /// Applies verified copies independently; changed rows are retained for retry.
    /// Transactions preserve source snapshots when adopting a server media identity.
    func applyServerAudioRecovery(_ report: ServerRecoveryReport, storage: ManagedSpeechStorage,
                                        settings: DeliverySettings, debugLog: DeliveryDebugLog? = nil) throws {
        try Task.checkCancellation(); try requireIdleLibrary(storage)
        guard Date().timeIntervalSince(report.inspectedAt) < 300,
              try settings.normalized() == report.destination else {
            throw RelayError.setup("Server reconciliation changed while running; it will retry automatically.")
        }
        let database = try ManagedSpeechStorage.prepareLibrary(stateRoot: storage.stateRoot)
        let lease = try PipelineLease(database: database); defer { lease.release() }
        let store = try NativeStore(url: database)
        var applyIssues = report.issues
        var blocked = report.blockedIDs
        var preserved = report.preservedItems
        var changedRecords = false
        let queuedIDs = Set(try store.queue().map(\.id))
        try store.execute("BEGIN IMMEDIATE")
        do {
            try store.execute("PRAGMA defer_foreign_keys=ON")
            for update in report.updates {
                try Task.checkCancellation()
                try store.execute("SAVEPOINT server_item")
                do {
                let episode = update.episode
                let existing = try store.query("SELECT id,record FROM episodes WHERE source_key=?", [update.sourceKey]).first
                if let raw = existing?.last, let current = try? JSONDecoder().decode(Episode.self, from: Data(raw.utf8)),
                   current.stage == .expired || current.manualAudioDeletionRequested == true {
                    try store.execute("RELEASE server_item"); continue
                }
                if let old = update.previousID, let expected = report.expectedRecords[old] {
                    guard existing?.first == old, existing?.last.map({ Files.hash(Data($0.utf8)) }) == expected else {
                        throw RelayError.storage("An article changed during reconciliation; it will be checked again.")
                    }
                }
                if let old = update.previousID ?? existing?.first {
                    if old != episode.id {
                        try store.execute("UPDATE episodes SET id=? WHERE id=?", [episode.id, old])
                        try store.execute("UPDATE snapshots SET article_id=? WHERE article_id=?", [episode.id, old])
                        try store.execute("UPDATE chunks SET article_id=? WHERE article_id=?", [episode.id, old])
                        try store.execute("DELETE FROM speech_queue WHERE article_id=?", [old])
                    }
                    let record = String(decoding: try Files.json(episode), as: UTF8.self)
                    if old != episode.id || existing?.last != record {
                        try store.execute("UPDATE episodes SET record=?,source_key=? WHERE id=?", [record, update.sourceKey, episode.id])
                        changedRecords = true
                    }
                } else {
                    try store.execute("INSERT INTO episodes VALUES(?,?,?)", [episode.id, update.sourceKey, String(decoding: try Files.json(episode), as: UTF8.self)])
                    changedRecords = true
                }
                if episode.delivery?.status == .uploaded && queuedIDs.contains(episode.id) { try store.execute("DELETE FROM speech_queue WHERE article_id=?", [episode.id]) }
                try store.execute("RELEASE server_item")
                } catch {
                    debugLog?.recordFailure(error); debugLog?.record(.reconciliation(.itemFailed))
                    try store.execute("ROLLBACK TO server_item"); try store.execute("RELEASE server_item")
                    blocked.insert(update.episode.id)
                    if let old = update.previousID { blocked.insert(old) }
                    preserved += report.rawItems[update.episode.id] ?? []
                    applyIssues.append("One local reconciliation record failed; other items were retained.")
                }
            }
            for var item in try store.queue() where blocked.contains(item.id) {
                item.state = .failed
                item.lastError = "Server audio for this article could not be verified. Retry checks it again; other articles continue."
                try store.saveQueueItem(item)
            }
            for var episode in try store.episodes() where blocked.contains(episode.id) && episode.stage == .published {
                episode.delivery = episode.delivery ?? DeliveryState(status: .failed, remotePath: settings.remoteMediaPath(episode.id))
                episode.delivery?.status = .failed
                episode.delivery?.lastError = "Server audio could not be verified; other articles continue."
                episode.delivery?.verificationFailed = true
                try store.execute("UPDATE episodes SET record=? WHERE id=?", [String(decoding: try Files.json(episode), as: UTF8.self), episode.id])
            }
            if changedRecords { try store.execute("UPDATE feed_status SET pending=1 WHERE singleton=1") }
            try store.execute("COMMIT")
        } catch { try? store.execute("ROLLBACK"); throw error }
        var ledger = try DeliveryLedger.load(stateRoot: storage.stateRoot)
        if ledger.destinationURL != report.destination.feedFolderURL { ledger.pendingRemoteDeletes = [] }
        ledger.destinationURL = report.destination.feedFolderURL
        ledger.settingsHash = try report.destination.settingsHash()
        ledger.lastUploadedFeedHash = report.feed.map(Files.hash)
        let retired = Set(try store.episodes().filter { $0.stage == .expired || $0.manualAudioDeletionRequested == true }.map(\.id))
        let retiredItems = Set(retired.flatMap { report.rawItems[$0] ?? [] })
        preserved.removeAll { retiredItems.contains($0) }
        ledger.lastPublishedAudioHashes = report.publishedHashes.filter { !blocked.contains($0.key) && !retired.contains($0.key) }
        ledger.lastPublishedSettingsHash = try report.destination.publicationHash()
        if ledger.lastError == ledger.reconciliationError { ledger.lastError = nil }
        ledger.reconciliationError = applyIssues.isEmpty ? nil : "Server reconciliation: \(applyIssues.count) items need attention; other items continued."
        ledger.serverFeedUnsafe = false
        ledger.serverAudioProofs = report.proofs
        preserved = Array(Set(preserved)).sorted()
        ledger.preservedServerItems = preserved
        ledger.blockedServerIDs = blocked.sorted()
        ledger.reconciledFeed = report.feed
        ledger.reconciledFeedETag = report.feedETag
        ledger.reconciledAt = report.checkedAt
        ledger.reconciledQueueIDs = try store.queue().map { $0.id + ":" + $0.state.rawValue }.sorted()
        let candidate = try RSS.renderReconciledRemote(store.published(), channel: RemoteChannel(settings: report.destination, previousFeed: report.feed), preserved: preserved)
        ledger.remoteFeedPending = ledger.lastUploadedFeedHash != Files.hash(candidate)
        try ledger.save(stateRoot: storage.stateRoot)
    }
    private static var recoveryConflict: DeliveryError {
        .fatal("Server audio conflicts with the recorded article or audio fingerprint. This item was left unchanged; other items can continue.")
    }
    private static func recoveryKey(_ url: URL) -> String { "reviewed-url-v1-" + Files.hash(Data(url.absoluteString.utf8)) }
    private static func recoveredDelivery(_ episode: Episode, settings: DeliverySettings) -> DeliveryState {
        var copy = DeliveryState(status: .uploaded, remotePath: settings.remoteMediaPath(episode.id), uploadedByteLength: episode.info?.byteLength)
        copy.destinationURL = settings.feedFolderURL
        return copy
    }
    private func recoveryLegacyKeys(storage: ManagedSpeechStorage, episodes: [Episode], keys: [String: String],
                                    catalog: ReadingListCatalog) throws -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for entry in catalog.entries { result[entry.url.absoluteString, default: []].insert(Self.recoveryKey(entry.url)) }
        guard FileManager.default.fileExists(atPath: storage.profile.database.path) else { return result }
        let store = try NativeStore(url: storage.profile.database, readOnly: true)
        for episode in episodes {
            guard let key = keys[episode.id] else { continue }
            if let source = episode.sourceURL, ServerRecoveryIdentity.validSource(key) { result[source.absoluteString, default: []].insert(key) }
            if let bytes = try? store.snapshot(articleID: episode.id) {
                guard let review = try? JSONDecoder().decode(StoredExtraction.self, from: bytes).review(),
                      Self.recoveryKey(review.page.originalURL) == key else { continue }
                for url in [review.page.originalURL, review.document?.article.canonicalURL ?? review.page.finalURL] {
                    result[url.absoluteString, default: []].insert(key)
                }
            }
        }
        return result
    }
    private func recoveryLibrary(_ storage: ManagedSpeechStorage) throws -> ([Episode], [String: String], ReadingListCatalog, [String: String]) {
        let database = storage.profile.database
        guard FileManager.default.fileExists(atPath: database.path) else { return ([], [:], ReadingListCatalog(), [:]) }
        try storage.validateState()
        let store = try NativeStore(url: database, readOnly: true)
        let rows = try store.query("SELECT id,source_key,record FROM episodes ORDER BY id")
        return (try store.episodes(), Dictionary(uniqueKeysWithValues: rows.map { ($0[0], $0[1]) }),
            try store.catalog(), Dictionary(uniqueKeysWithValues: rows.map { ($0[0], Files.hash(Data($0[2].utf8))) }))
    }
}
