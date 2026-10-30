# Long-form narration quality

Updated October 30, 2026 after operator comparison. Kokoro always uses semantic
phrasing; the other models retain an optional experiment. Existing source documents
and recordings are retained.
The [implementation plan](LONGFORM_QUALITY_IMPLEMENTATION_PLAN.md) records scope;
B09 in the [operator checklist](OPERATOR_VALIDATION.md) owns listening acceptance.

## Try different phrasing

Kokoro uses semantic phrasing automatically, including with older saved settings.
It has no phrasing switch. In Libro's main-window voice controls, or VoiceRelay's
**Voice Model** Settings, other models offer **Try semantic phrasing** for new narration.
This experimental policy
prefers complete sentences and clauses rather than a numerical chunk size alone.
Controls, shared preparation and captured settings are the same in both apps.
For those models, turning it off selects their accepted policy again; it does not alter recordings.

Kokoro retains its 200-phone soft target and 510-phone hard ceiling. Semantic packing
can grow toward 300 phones to finish a phrase, keeps closing punctuation attached,
and penalizes weak grammatical boundaries and splits within recognized names.
Letter-to-letter hyphens inside compounds such as “behind-the-scenes” become
word separators in the phonemes rather than dash pauses, and the compound stays
within one utterance. Ordinary dashes and numeric expressions retain their existing
handling. The source text and mappings keep the original hyphens. An indivisible
compound exceeding the hard limit fails explicitly instead of being cut or truncated.
Actual word/phone alignment and vocabulary checks remain mandatory. Candidate
native-text models plan using the loaded checkpoint tokenizer: Qwen/Orpheus target
96 input tokens, Chatterbox 80, with a 512-token ceiling. These are experimental
engineering targets, not universal quality optima. Soprano's public interface does
not expose token counts; its candidate uses a disclosed 180-scalar target and
480-scalar ceiling. Independent 1,000-scalar source windows keep IPC bounded.

Preparation can load a large helper to measure its real tokenizer. Each helper is
still reaped before releasing admission; no extra resident engine, hidden download,
parallel speech, translated text or previous-sentence speech prefix is introduced.
The additional loading may cost time; compare total runtime as well as phrasing.
Native testing also exposed Qwen's SDK text-length heuristic ending a valid
passage before EOS, below the product's declared output budget. The product now
honors its explicit 4,096-token ceiling, with a new generation identity. The same
fixed-seed passage then completed under both preparation policies. This does not
relax clean-EOS, memory, timeout or two-minute-per-chunk output guards.

The model details ⓘ also offers **Expand explicit quantities and times** for
non-Kokoro English narration. It uses the existing mapped/protected quantity,
temperature, time and letter-label rules. It is off by default: another model may
already handle the original forms better. Non-English narration never receives
these English expansions. Kokoro retains its accepted spoken forms.

Qwen's optional **Delivery presets** fill its existing instruction field. Model
default clears the instruction; custom instructions remain supported. No preset
is applied automatically, and no emotion or nonverbal sounds are inferred from prose.

## Pronunciation and context

The shared **Pronunciation** Settings pane retains simple English spelling rules.
Select a row and expand **Advanced pronunciation** to restrict it by language tag,
exact document title (case-insensitive) or model. The title is the document title
shown in the narration preview, not an assumed file path or source identifier.
A document rule outranks a global rule; a model restriction and then an exact
regional language tag further specialize it. A language such as `en` includes
`en-US`/`en-GB`; English rules do not apply to French, Japanese or other languages.
Duplicate keys are allowed only in distinct scopes. Limit: 500 entries total.

Legacy files still load. Advanced rules use dictionary schema 2; run updated
versions of both apps when editing these rules. The store preserves compare-and-swap
conflict protection. Settings changes affect new preparation, never audio in flight.

For Kokoro only, an advanced rule can supply its exact supported phonemes. Leave
spelling blank to retain the written word. The helper validates the checkpoint's
actual vocabulary and exact aligned word/phrase range; an unsupported sequence,
partial override or over-limit word fails explicitly without truncation. Phone
strings are never inserted into ordinary prose, interpreted from document markup,
or forwarded as IPA/ARPAbet to a grapheme-based model.

Expand **Preview a sentence or review names** and enter a sentence/passage. Row
Play uses that context and the row's document scope, with the app's selected model,
voice and language. **Find repeated names** proposes repeated entities recognized
by Apple's language tools in this bounded passage. Adding a suggestion creates a
draft; supply/approve its pronunciation. Detection is imperfect and does not guess
how a name should sound or resolve every homograph. The limit is 64 KB per passage.

## Retain, check and repair passages

In model details, enable **Keep chunks for narration review** before generating.
This is optional and off by default. It stores private text, prepared phones,
settings and lossless native Float32 audio separately from models and published
media under the user's Application Support folder:

```
SwiftNarration/Narration Reviews/
```

Plans are immutable; bounded per-chunk journals avoid rewriting a whole book after
each chunk. Limits are 10,000 passages, 16 MB plan and 4 GiB audio per take; each
passage is bounded to two minutes. Retention is best effort and cannot change a
successful audio render. Missing/failed retained chunks leave an incomplete take;
previously checkpointed VoiceRelay chunks are not implicitly copied into it.
A failed retention can therefore leave a recording unavailable for complete export.

In Pronunciation Settings, expand **Review retained narration** and load the list.
Choose a recording/passage to play it or inspect basic duration, silence and exact
repetition flags. These read-only screens never trim, normalize, crossfade or apply
gain. A flag asks for listening; an unflagged passage is not proof of correct speech.

**Check words locally** uses Apple's SpeechAnalyzer only when compatible recognition
assets are already installed. It never requests installation or uses an online
fallback. Unsupported/missing assets give an explicit result. Recognition is bounded
and cancellable behind the shared inference lease. Word differences can reflect ASR
errors, number formatting, accents or names; this is not a pronunciation score.
ASR never replaces article text or supplies podcast word timings.

**Regenerate passage** creates a new private take using the captured model/voice,
reusing verified PCM for all other passages. Optional controls replan phrase
boundaries or explicitly apply current pronunciation rules. Captured aliases are
undone only when their entire verified range belongs to the selected passage;
partial aliases fail rather than inventing text. The previous take remains intact.
A pronunciation edit retains the previous take's source evidence; edited ranges do
not claim inferred original-coordinate mappings. Generating an older Kokoro passage
reprepares that passage with current semantic packing; unchanged PCM is reused.
No automatic retry loop exists.

**Export new WAV…** reassembles a complete take with measured frame intervals and
the versioned structural gaps, refusing to overwrite an existing destination.
It does not replace Libro exports, podcast episodes, RSS entries or transcript
sidecars. A separately exported review is not automatically published. Trash
removes retained review material only. Model storage and finished recordings remain
independent. Review/recognition share the existing joined preview ownership: starting
normal work, changing settings, leaving the pane or quitting cancels owned review.
An incomplete take also offers **Generate missing passages**, an explicit single
attempt for each absent passage. Verified existing PCM is reused in a new take;
the original incomplete take remains intact. It is never retried automatically.

## Compare the actual product pipeline

The Swift developer command **tts-narration-quality** renders the accepted and
candidate preparation for the same voice/document through NarrationPlanner,
NativeSpeechSession, the complete private helper and structural assembly. It
compares the four experimental engines, uses an original multi-paragraph corpus and
installed assets only, and saves prepared plans/hashes/timing receipts privately.
Kokoro is excluded from new A/B phrasing runs because it has one preparation path.
Existing Kokoro comparison pages and choices remain readable. See
[benchmark commands](../tools/TTSBenchmark/README.md#product-phrasing-comparisons).

Open the generated `comparison.html` directly. Each numbered pair uses the same
voice and passage with randomized A/B preparation order. Names/settings are absent
from page data and audio filenames. Save/import a portable choices file; finish
all pairs before explicitly selecting `identities.json` to reveal results. No
server, upload, external JavaScript, automatic identity loading or audio-level
adjustment is used. Avoid the private evidence and identity file while listening.
The existing model/voice bracket and its cold/warm performance records are separate.

Seeds, when explicitly provided by developer tooling, are captured with the plan
and applied before each chunk. They do not guarantee bit-identical output between
hardware or dependency versions. Fixed voice/reference/instruction and resource
identities are retained; no new default seed or sampling policy is applied in apps.

The local recognizer uses the installed-asset checks in Apple's
[AssetInventory](https://developer.apple.com/documentation/speech/assetinventory)
and file-based [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
APIs. No call to asset installation or a server recognizer is made.
