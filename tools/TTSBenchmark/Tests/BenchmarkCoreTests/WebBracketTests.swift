import XCTest
import Foundation
import JavaScriptCore
@testable import BenchmarkCore

final class WebBracketTests: XCTestCase {
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tts-bracket-web-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func fixture(_ root: URL) throws -> (Bracket, Matrix) {
        let passages = Array(Catalog.passages.prefix(2))
        let samples: [Float] = (0..<9600).map { sin(Float($0) * 0.05) * 0.05 }
        let file = root.appendingPathComponent("private-source.wav")
        _ = try Wave.write(samples, rate: 24000, to: file)
        let hash = try Files.hash(file)
        let entrants = (0..<4).map { index in Entrant(id: "private-model-\(index)", label: "Hidden Narrator \(index)", identity: "secret-checkpoint-\(index)",
            clips: Dictionary(uniqueKeysWithValues: passages.map { ($0.id, "private-source.wav") }),
            hashes: Dictionary(uniqueKeysWithValues: passages.map { ($0.id, hash) })) }
        let bracket = try Bracket(entrants: entrants, seed: 42)
        let matrix = Matrix(profiles: [Catalog.matrix().profiles[0]], passages: passages)
        try Files.write(bracket, root.appendingPathComponent("bracket.json"))
        try Files.write(matrix, root.appendingPathComponent("matrix.json"))
        return (bracket, matrix)
    }
    func context() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(try WebBracket.resource("engine", extension: "js"))
        XCTAssertNil(context.exception); return context
    }
    func put<T: Encodable>(_ value: T, name: String, context: JSContext) throws {
        context.setObject(try JSONSerialization.jsonObject(with: Files.encoder.encode(value)), forKeyedSubscript: name as NSString)
    }
    func seed(_ root: URL) throws -> WebBracket.Seed {
        let html = try String(contentsOf: root.appendingPathComponent("bracket.html"), encoding: .utf8)
        for placeholder in ["/*__STYLE__*/", "/*__ENGINE__*/", "/*__APP__*/", "__SEED_JSON__"] {
            XCTAssertFalse(html.contains(placeholder), "Generated page still contains a source-template placeholder")
        }
        XCTAssertTrue(try WebBracket.resource("bracket-template", extension: "html").contains("cannot run on its own"))
        let start = try XCTUnwrap(html.range(of: "<script id=\"bracket-seed\" type=\"application/json\">"))
        let end = try XCTUnwrap(html.range(of: "</script>", range: start.upperBound..<html.endIndex))
        return try JSONDecoder().decode(WebBracket.Seed.self, from: Data(html[start.upperBound..<end.lowerBound].utf8))
    }
    func testPageIsBlindAndExportsAnonymousAudio() throws {
        let root = try temporary(); let (bracket, matrix) = try fixture(root)
        try Reports.bracketPage(bracket, matrix: matrix, root: root)
        let html = try String(contentsOf: root.appendingPathComponent("bracket.html"), encoding: .utf8)
        for value in ["Hidden Narrator", "private-model", "secret-checkpoint", "private-source.wav", "fetch(", "http://", "https://"] { XCTAssertFalse(html.contains(value), value) }
        let seed = try seed(root)
        XCTAssertEqual(seed.participants.count, 4); XCTAssertTrue(seed.progress.history.isEmpty)
        for participant in seed.participants {
            XCTAssertTrue(participant.id.hasPrefix("voice-"))
            for clip in participant.clips.values { XCTAssertTrue(clip.hasPrefix("bracket-audio/")); XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(clip).path)) }
        }
        let identities = try Files.read(WebBracket.Identities.self, root.appendingPathComponent("bracket-identities.json"))
        XCTAssertEqual(identities.runID, seed.runID); XCTAssertEqual(identities.names.count, 4)
        // Explicit opt-in exports this synthetic fixture for browser interaction tests.
        if let path = ProcessInfo.processInfo.environment["TTS_BENCH_WEB_UI_FIXTURE"] {
            let target = URL(fileURLWithPath: path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            try FileManager.default.copyItem(at: root, to: target)
        }
    }
    func testPageEscapesNotesAndPassagesOutsideScript() throws {
        let root = try temporary(); var (bracket, matrix) = try fixture(root)
        try bracket.answer(match: bracket.view().pending!.id, choice: "defer", note: "</script><img src=x onerror=alert(1)>")
        try Files.write(bracket, root.appendingPathComponent("bracket.json"))
        matrix.passages = [Passage(id: matrix.passages[0].id, role: "calibration", text: "</script><script>danger</script>")]
        try Reports.bracketPage(bracket, matrix: matrix, root: root)
        let html = try String(contentsOf: root.appendingPathComponent("bracket.html"), encoding: .utf8)
        XCTAssertFalse(html.contains("<img src=x")); XCTAssertFalse(html.contains("<script>danger"))
        XCTAssertTrue(try seed(root).progress.history[0].note.contains("</script>"))
    }
    func testJavaScriptMatchesSwiftForAdvancementResetsTiesRejectsAndRevisions() throws {
        for count in 2...17 { for pattern in 0...2 {
            let entries = (0..<count).map { Entrant(id: "p\($0)", label: "Participant", identity: "i\($0)", clips: [:], hashes: [:]) }
            var swift = try Bracket(entrants: entries, seed: UInt64(count))
            let context = try context()
            try put(swift.entrants, name: "participants", context: context)
            let progress = BracketProgress(runID: String(repeating: "a", count: 64), sourceRevision: String(repeating: "b", count: 64), decisions: [], history: [], retained: [])
            try put(progress, name: "state", context: context)
            var turns = 0, revised = false
            while true {
                let view = try swift.view()
                let json = try XCTUnwrap(context.evaluateScript("JSON.stringify(BracketEngine.view(participants, state.decisions))")?.toString())
                let javascript = try JSONDecoder().decode(BracketView.self, from: Data(json.utf8))
                XCTAssertEqual(try Files.encoder.encode(view), try Files.encoder.encode(javascript), "n=\(count), pattern=\(pattern), turn=\(turns)")
                guard let pending = view.pending else { break }
                var match = pending.id, choice = turns == 0 ? "tie" : turns == 1 ? "defer" : pattern == 2 && turns % 3 == 0 ? "neither" : pattern == 1 ? "b" : "a"
                var revise = false
                if turns > 4, !revised, let previous = view.matches.first(where: { $0.id != pending.id }) {
                    match = previous.id; choice = "b"; revise = true; revised = true
                }
                try swift.answer(match: match, choice: choice, note: "fixture", revise: revise)
                let action = ["match": match, "choice": choice, "note": "fixture"]
                try put(action, name: "action", context: context)
                context.setObject(revise, forKeyedSubscript: "revising" as NSString)
                context.evaluateScript("state = BracketEngine.answer(participants,state,action.match,action.choice,action.note,revising)")
                XCTAssertNil(context.exception)
                turns += 1; XCTAssertLessThan(turns, 100)
            }
            let result = try XCTUnwrap(context.evaluateScript("JSON.stringify(BracketEngine.shortlist(participants,state))")?.toString())
            XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(result.utf8)), try swift.shortlist())
        } }
    }
    func testBrowserProgressRoundtripIdempotenceAndStaleCanonicalProtection() throws {
        let root = try temporary(); let (bracket, matrix) = try fixture(root)
        try Reports.bracketPage(bracket, matrix: matrix, root: root)
        let seed = try seed(root), context = try context()
        let originalHash = try Files.hash(root.appendingPathComponent("bracket.json"))
        try put(seed, name: "seed", context: context); try put(seed.progress, name: "state", context: context)
        context.evaluateScript("state=BracketEngine.answer(seed.participants,state,'match-001','tie','a note'); state=BracketEngine.answer(seed.participants,state,'match-001','a','preferred'); state=BracketEngine.answer(seed.participants,state,'match-002','b','another'); state=BracketEngine.answer(seed.participants,state,'match-001','b','changed my mind',true); state=BracketEngine.validate(seed,state)")
        XCTAssertNil(context.exception)
        func data() throws -> Data { Data(try XCTUnwrap(context.evaluateScript("JSON.stringify(state)")?.toString()).utf8) }
        let first = try WebBracket.importProgress(data(), root: root, matrix: matrix, bracket: bracket)
        XCTAssertEqual(try Files.hash(root.appendingPathComponent("bracket-import-history/\(originalHash).json")), originalHash)
        XCTAssertEqual(first.history.count, 5); XCTAssertEqual(first.decisions.count, 1)
        XCTAssertEqual(first.decisions[0].choice, "b"); XCTAssertEqual(first.history.last?.note, "changed my mind")
        let second = try WebBracket.importProgress(data(), root: root, matrix: matrix, bracket: first)
        XCTAssertEqual(try Files.encoder.encode(first), try Files.encoder.encode(second))
        context.evaluateScript("state=BracketEngine.answer(seed.participants,state,'match-002','a','next pair')")
        let third = try WebBracket.importProgress(data(), root: root, matrix: matrix, bracket: second)
        XCTAssertEqual(third.decisions.count, 2)
        var external = third
        try external.answer(match: external.view().pending!.id, choice: "a", note: "external edit")
        try Files.write(external, root.appendingPathComponent("bracket.json"))
        let original = try Files.hash(root.appendingPathComponent("bracket.json"))
        context.evaluateScript("state=BracketEngine.answer(seed.participants,state,'match-003','b','different browser edit')")
        XCTAssertThrowsError(try WebBracket.importProgress(data(), root: root, matrix: matrix, bracket: external))
        XCTAssertEqual(try Files.hash(root.appendingPathComponent("bracket.json")), original)
    }
    func testInvalidOrForeignBrowserProgressDoesNotChangeCanonicalState() throws {
        let root = try temporary(); let (bracket, matrix) = try fixture(root)
        try Reports.bracketPage(bracket, matrix: matrix, root: root)
        let seed = try seed(root), original = try Files.hash(root.appendingPathComponent("bracket.json"))
        var bad = seed.progress; bad.runID = "foreign"
        XCTAssertThrowsError(try WebBracket.importProgress(Files.encoder.encode(bad), root: root, matrix: matrix, bracket: bracket))
        bad = seed.progress; bad.decisions = [Vote(match: "match-001", choice: "a")]
        XCTAssertThrowsError(try WebBracket.importProgress(Files.encoder.encode(bad), root: root, matrix: matrix, bracket: bracket))
        bad = seed.progress; bad.retained = ["private-model-0"]
        XCTAssertThrowsError(try WebBracket.importProgress(Files.encoder.encode(bad), root: root, matrix: matrix, bracket: bracket))
        XCTAssertEqual(try Files.hash(root.appendingPathComponent("bracket.json")), original)
        var rejected = bracket; rejected.retained = [bracket.entrants[0].id]
        try rejected.answer(match: rejected.view().pending!.id, choice: "neither")
        try Files.write(rejected, root.appendingPathComponent("bracket.json"))
        try Reports.bracketPage(rejected, matrix: matrix, root: root)
        let updated = try self.seed(root)
        XCTAssertTrue(updated.progress.retained.isEmpty)
        let javascript = try context()
        try put(seed, name: "seed", context: javascript)
        javascript.evaluateScript("var state=seed.progress;state.retained=[seed.participants[0].id];state=BracketEngine.answer(seed.participants,state,'match-001','neither');state=BracketEngine.validate(seed,state)")
        XCTAssertNil(javascript.exception)
        XCTAssertEqual(javascript.evaluateScript("state.retained.length")?.toInt32(), 0)
    }
    func testClientPersistenceBlindingTabConflictsAndBackupFallbacks() throws {
        let root = try temporary(); let (bracket, matrix) = try fixture(root)
        try Reports.bracketPage(bracket, matrix: matrix, root: root)
        let seed = try seed(root)
        // A model-free DOM adapter tests event/state effects, not browser layout,
        // media playback or actual download/clipboard permissions.
        func client(saved: [String: String] = [:], denied: Bool = false) throws -> JSContext {
            let context = try self.context()
            try put(seed, name: "inputSeed", context: context)
            try put(saved, name: "saved", context: context)
            context.setObject(denied, forKeyedSubscript: "denied" as NSString)
            context.setObject(try WebBracket.resource("bracket-template", extension: "html"), forKeyedSubscript: "template" as NSString)
            context.evaluateScript(#"""
            class Element {
              constructor(tag) { this.tagName=tag.toUpperCase();this.textContent='';this.value='';this.hidden=false;this.disabled=false;this.children=[];this.events={};this.dataset={};this.clicks=0; }
              addEventListener(name, fn) { this.events[name]=fn; }
              setAttribute(name, value) { this[name]=value; }
              append(...children) { this.children.push(...children); }
              replaceChildren(...children) { this.children=children; }
              click() { this.clicks++; if(!this.disabled)this.events.click?.({target:this}); }
              pause() {} focus() {} select() {} remove() {}
            }
            var elements=Object.fromEntries(Array.from(template.matchAll(/id="([^"]+)"/g)).map(m=>[m[1],new Element('div')]));
            var buttons=Array.from(template.matchAll(/data-choice="([^"]+)"/g)).map(m=>{let b=new Element('button');b.dataset.choice=m[1];return b;});
            elements['bracket-seed'].textContent=JSON.stringify(inputSeed);
            var document={body:new Element('body'),getElementById:id=>elements[id],querySelectorAll:()=>buttons,createElement:tag=>new Element(tag),addEventListener:()=>{}};
            var window=globalThis;window.confirm=()=>true;window.addEventListener=()=>{};
            var localStorage={getItem:k=>{if(denied)throw Error('blocked');return saved[k]??null;},setItem:(k,v)=>{if(denied)throw Error('blocked');saved[k]=v;},removeItem:k=>delete saved[k]};
            var navigator={},lastDownload=null;
            class Blob { constructor(parts){lastDownload=parts.join('');} }
            var URL={createObjectURL:()=> 'blob:fixture',revokeObjectURL:()=>{}},setTimeout=()=>{};
            """#)
            context.evaluateScript(try WebBracket.resource("app", extension: "js"))
            XCTAssertNil(context.exception); return context
        }
        let context = try client(), key = "tts-bracket-v1:" + seed.runID
        XCTAssertTrue(context.evaluateScript("elements.app.hidden === false && elements['startup-status'].hidden === true")!.toBool())
        context.evaluateScript("elements['reveal'].click()")
        XCTAssertEqual(context.evaluateScript("elements['identity-file'].clicks")?.toInt32(), 0)
        context.evaluateScript("buttons[0].click();elements.notes.value='A saved note';elements.submit.click()")
        XCTAssertNil(context.exception)
        let saved = try XCTUnwrap(context.objectForKeyedSubscript("saved")?.toDictionary() as? [String: String])
        let progress = try JSONDecoder().decode(BracketProgress.self, from: Data(try XCTUnwrap(saved[key]).utf8))
        XCTAssertEqual(progress.decisions.count, 1); XCTAssertEqual(progress.decisions[0].note, "A saved note")
        let reloaded = try client(saved: saved)
        XCTAssertEqual(reloaded.evaluateScript("elements['match-title'].textContent")?.toString(), "Pair 2")
        reloaded.evaluateScript("saved['" + key + "']='external change';buttons[0].click();elements.submit.click()")
        XCTAssertTrue(reloaded.evaluateScript("elements.submit.disabled")!.toBool())
        XCTAssertTrue(reloaded.evaluateScript("elements.notice.textContent.includes('Another tab')")!.toBool())
        context.evaluateScript("for(let i=0;i<20&&!elements.comparison.hidden;i++){buttons[0].click();elements.submit.click();}elements.reveal.click()")
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("elements['identity-file'].clicks")?.toInt32(), 1)
        XCTAssertFalse(context.evaluateScript("elements.shortlist.children.map(x=>x.textContent).join(' ').includes('Hidden Narrator')")!.toBool())
        let rejectedFinal = try client()
        rejectedFinal.evaluateScript("for(let i=0;i<20&&!elements.comparison.hidden;i++){(elements.round.textContent==='FINAL PAIR'?buttons[3]:buttons[0]).click();elements.submit.click();}")
        XCTAssertNil(rejectedFinal.exception)
        XCTAssertFalse(rejectedFinal.evaluateScript("elements.shortlist.children.map(x=>x.textContent).join(' ').includes('top choice')")!.toBool())
        XCTAssertFalse(rejectedFinal.evaluateScript("elements.shortlist.children.map(x=>x.textContent).join(' ').includes('runner-up')")!.toBool())
        let unavailable = try client(denied: true)
        unavailable.evaluateScript("buttons[0].click();elements.submit.click();elements.backup.click();elements.copy.click()")
        XCTAssertNil(unavailable.exception)
        let backup = try XCTUnwrap(unavailable.evaluateScript("lastDownload")?.toString())
        XCTAssertEqual(try JSONDecoder().decode(BracketProgress.self, from: Data(backup.utf8)).decisions.count, 1)
        XCTAssertTrue(unavailable.evaluateScript("elements['save-status'].textContent.includes('unavailable')")!.toBool())
        XCTAssertTrue(unavailable.evaluateScript("elements['progress-text'].value.includes('decisions')")!.toBool())
    }
}
