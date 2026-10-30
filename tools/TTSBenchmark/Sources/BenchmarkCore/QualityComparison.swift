import Foundation

/// Product preparation comparisons are paired within a voice, not bracket
/// entrants or cold/warm variants. Names stay in a separately selected file.
public enum QualityComparison {
    public struct Pair: Codable, Sendable {
        public let id: Int
        public let text: String
        public let a: String
        public let b: String
        public init(id: Int, text: String, a: String, b: String) { self.id = id; self.text = text; self.a = a; self.b = b }
    }
    public static let paragraphs = [
        "The field station opened before sunrise. Dr. Elena Morris set a parcel beside the door and waited for Mina. The thermometer read -4 °C; the parcel weighed 2.4 kg. At 9:05 pm the previous evening, the river had covered the lower path. Nobody knew whether the bridge was safe.",
        "“Did you read the notice?” Mina asked. “I read it yesterday,” Elena said, “but I would rather hear what you found.” Mina put down the lead sample. She would lead the next survey, provided the water fell before noon. “Check Package A, not the label on the lid.”",
        "They returned to the map. Its narrow blue line made the river look permanent. In the field it was anything but permanent: every winter, floodwater moved a little soil from one bank to the other. A small change became a bend; the bend became a new channel. Elena marked a possible route around the bridge, then stopped. A safe line on paper was only the beginning.",
        "Mina had brought the old photographs. In one, a child stood beside a pear tree; in another, the same tree shaded a school window. The road had changed, the children had grown, and someone had replaced the gate. “We cannot keep everything,” she said. “We should still notice what we are about to remove.” Elena folded the map. They would walk the longer way, together."
    ]
    public static func page(pairs: [Pair], identity: String) throws -> String {
        guard !pairs.isEmpty, pairs.count <= 20, identity.count == 64 else { throw BenchError("Invalid quality comparison") }
        func escape(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;") }
        var sections = ""
        for pair in pairs {
            for path in [pair.a, pair.b] { guard path.range(of: #"^audio/[a-f0-9-]+\.wav$"#, options: .regularExpression) != nil else { throw BenchError("Nonanonymous audio path") } }
            sections += """
            <section><h2>Comparison \(pair.id)</h2><div class="players"><div><label for="a\(pair.id)">A</label><audio id="a\(pair.id)" controls preload="none" src="\(pair.a)"></audio></div><div><label for="b\(pair.id)">B</label><audio id="b\(pair.id)" controls preload="none" src="\(pair.b)"></audio></div></div>
            <label>Preference <select data-vote="\(pair.id)"><option value="">Choose after listening</option><option>A</option><option>B</option><option>Same</option><option>Neither</option></select></label>
            <label>Listening notes<textarea data-note="\(pair.id)" placeholder="Names, phrasing, pauses, missing words, fatigue…"></textarea></label>
            <details><summary>Read the passage</summary><p>\(escape(pair.text))</p></details></section>
            """
        }
        return """
        <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Narration phrasing comparison</title>
        <style>body{font:17px system-ui;color-scheme:light dark;max-width:960px;margin:32px auto;padding:0 24px;line-height:1.5}section{border:1px solid #8886;border-radius:16px;padding:20px;margin:24px 0}.players{display:grid;grid-template-columns:1fr 1fr;gap:20px}audio{display:block;width:100%;margin:8px 0 16px}label{display:block;margin:8px 0}select,button,textarea{font:inherit;padding:8px}textarea{display:block;box-sizing:border-box;width:100%;min-height:80px}p{white-space:pre-wrap}button{margin:8px 8px 8px 0}@media(max-width:650px){.players{grid-template-columns:1fr}}</style>
        <h1>Listen for natural phrasing</h1><p>Each pair uses the same narrator and passage. Identities and preparation settings stay hidden until you finish and choose to reveal them. No audio level adjustment.</p>
        <button id="save">Save choices</button><button id="import">Import choices</button><button id="reveal">Reveal completed results</button><input id="file" type="file" accept="application/json" hidden><p id="status" role="status"></p>
        \(sections)
        <script>
        const run='\(identity)', status=document.getElementById('status'), votes=[...document.querySelectorAll('[data-vote]')], notes=[...document.querySelectorAll('[data-note]')];
        function snapshot(){return {version:1,run,choices:votes.map((v,i)=>({pair:Number(v.dataset.vote),choice:v.value,note:notes[i].value}))};}
        document.addEventListener('play',e=>{if(e.target.tagName==='AUDIO')for(const a of document.querySelectorAll('audio'))if(a!==e.target)a.pause();},true);
        document.getElementById('save').onclick=()=>{const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([JSON.stringify(snapshot(),null,2)],{type:'application/json'}));a.download='phrasing-choices.json';a.click();setTimeout(()=>URL.revokeObjectURL(a.href),1000);status.textContent='Save the choices file as your portable backup.';};
        let reveal=false;
        document.getElementById('import').onclick=()=>{reveal=false;document.getElementById('file').click();};
        document.getElementById('reveal').onclick=()=>{if(votes.some(v=>!v.value)){status.textContent='Finish all comparisons before revealing identities.';return;}reveal=true;status.textContent='Choose identities.json from this comparison folder.';document.getElementById('file').click();};
        document.getElementById('file').onchange=async e=>{try{const file=e.target.files[0];if(!file)return;const data=JSON.parse(await file.text());if(data.run!==run)throw Error('This file belongs to another comparison.');if(reveal){if(!Array.isArray(data.identities)||data.identities.length!==votes.length)throw Error('Choose identities.json.');status.textContent=data.identities.map(i=>'Comparison '+i.pair+': '+i.a+' / '+i.b).join(' · ');}else{if(!Array.isArray(data.choices)||data.choices.length!==votes.length||data.choices.some((x,i)=>x.pair!==Number(votes[i].dataset.vote)||!['','A','B','Same','Neither'].includes(x.choice)||typeof x.note!=='string'||x.note.length>10000))throw Error('Invalid choices file.');data.choices.forEach((x,i)=>{votes[i].value=x.choice;notes[i].value=x.note;});status.textContent='Choices restored.';}}catch(error){status.textContent=error.message;}finally{e.target.value='';}};
        </script><p>Local files only. Save choices before closing; no server or upload.</p></html>
        """
    }
}
