# Kokoro longform implementation record

Implementation authorized October 15, 2026, after Settings automated validation.
The plan is [KOKORO_LONGFORM_PLAN.md](KOKORO_LONGFORM_IMPLEMENTATION.md). Automated evidence
and operator acceptance are separate. Nothing has been committed, pushed,
published, installed or notarized by this work.

## Activation and ownership

The operator accepted `phoneme-200-pauses-candidate-1` at 1.0× on October 15.
`SpeechPreparationPolicy.current` now selects that exact tested profile; its
versioned identifier and acoustic parameters are unchanged. Heart remains the
default voice. New Libro settings use 1.0×, matching VoiceRelay and voice samples;
stored speeds and admitted job settings retain their values. Soprano retains its
text frontend. Other profiles remain developer comparison/recovery contracts,
without user quality modes. All 29 samples have been regenerated and both final ad-hoc Release archives passed.
The research and concrete next-step design are in
[TEXT_NORMALIZATION_RESEARCH.md](TEXT_NORMALIZATION_RESEARCH.md).

The apps retain their own workflows and settings. Shared contracts/projection
live in NarrationCore, resources in NativeSpeech, native G2P/model execution in
NativeSpeechEngine, process orchestration in ProcessingPipeline, and exact PCM
assembly in AudioOutput. No new package or runtime dependency was introduced.

## LF0: Preserved baseline

Before source changes, recorded source digests for all three dirty repositories,
selected Xcode/Swift/SDK/OS/hardware, actual prepared asset hashes, and preserved
the complete Release Libro bundle and existing native acceptance executable.
These are same-host completed artifacts, not transferred SwiftPM/DerivedData state.

Private ignored evidence: `.build/longform/baseline/`. Isolated prepared assets:
`.build/longform/workspaces/baseline/`. Speech processes deny network access.
The baseline mixed check completed 12 PDF pages plus 600 Markdown words with one
resident worker: coordinator peak 19,055,312 bytes; Kokoro helper 2,079,704,624;
Soprano helper 749,225,208. These are physical-footprint samples, not allocation
caps, GUI measurements or reproduction with the original private files.

`Tests/Fixtures/Longform/corpus.json` is original redistributable synthetic text.
It includes sustained prose/endings, dialogue, structural transitions, numbers,
regional spelling, contextual homographs, Unicode and line wraps. Baseline renders
cover Heart, Michael and Emma, 1.0×/1.1×, two repeats each. Source text, chunk plans,
timing, duration, PCM hashes and separate coordinator/helper peaks are retained.
No seed is claimed: the actual native path exposes no configured random seed.

## LF1/LF2: Native audit and resources

- Three converted voice packs have `[510,1,256]` Float32 storage byte-identical to
  upstream tensors; the native loader squeezes this to `[510,256]`. The explicit
  prepared path uses the reference length-minus-one row. The legacy row remains
  available for matched comparison. No acoustic improvement follows merely from
  proving the tensor convention.
- Native Misaki now exposes actual source-aligned token ranges without interpreting
  Markdown phoneme directives. Unsupported phonemes, empty word pronunciations,
  over-limit words and overlong BART input fail explicitly; no phonemes are cut.
- The audit found a proven decimal omission: the port omitted upstream's letters-only
  condition for dotted acronyms. `12.50` and `2.4` could become empty acronyms.
  The recorded patch restores the condition. It also splits numeric word expansion
  on punctuation, preserving words in hyphenated numbers.
- The old custom cardinal converter mishandled twenties, million-scale numbers and
  negative fractions. Cardinal/decimal spelling now uses Foundation NumberFormatter
  in explicit English locale. The existing ordinal/year presentation is retained.
  Pure native dependency fixtures exercise these cases without MLX/model assets.
- Apple tags decimal amounts as OtherWord on this SDK. Currency handling now reuses
  the lexicon's numeric predicate instead of relying on a spaCy-style Number tag.
  Native regressions verify dollars/cents, pounds/euros, decimals, twenties, scales
  and retained dotted-letter abbreviations in US and British pronunciation.
- British dictionaries and native BART weights/config come from MisakiSwift commit
  `b7477b15fc46cf8e20b32c008126611b38ec6b79`. File sizes/hashes are pinned in
  `Sources/NativeSpeech/BritishG2P.swift`; its Apache 2.0 license ships in notices.
  Native regional lexical and out-of-dictionary fallback checks run offline.
- US inventories/paths remain valid. British assets have their own atomic inventory;
  absent GB files cannot silently use US dictionaries/weights. Select the British
  voice and explicitly Install Speech Model to acquire/update them. Generation and
  checking never download them; failures give a specific install/update action.

Exact pins, provenance and narrow adaptations are in [DEPENDENCIES.md](DEPENDENCIES.md).
Lexical parity does not resolve every homograph, name or unit abbreviation. Those
remain listening cases, with the existing user dictionary available; there is no
new global homograph substitution or LLM fallback.

## LF3: Final preparation and bounded control

`semantic document -> captured spelling overrides -> spoken projection -> bounded
helper G2P -> immutable prepared utterances -> synthesis -> assembly -> encoding`.

The candidate packs actual supported phoneme scalars, targeting 100–200 tokens
with a soft target of 200 and hard ceiling 510. Sentence/clause boundaries take
precedence over words; trailing punctuation/quotes stay with their phrase. Short
compatible sentences and footnote introductions can share context. Headings,
paragraphs and footnote transitions retain explicit boundaries and block indices.
The 1,000-source-scalar window is an IPC/context bound, independent of speed.
Soprano explicitly retains its text planner/frontend.

Original blocks remain unchanged. Prepared values retain spoken ranges, block
references, authored/OCR/generated provenance and captured pronunciation mappings.
Mapping offsets refer to NFC-normalized pre/post-rule spoken projection, not raw
PDF byte offsets. A shared frontend/region/style/model/voice/speed/packing identity
and deterministic utterance fingerprints prevent incompatible reuse.

IPC is version 2; old helpers produce a controlled compatibility result. Its
65,536-byte record limit is unchanged. Preparation payloads use exclusively owned
private files bounded to 8 MiB/1,000 utterances per source window, validated by exact
path, regular-file/link checks, size, SHA-256, count, source coverage and identity,
then removed. No global text cache or document-sized MLX array is added. Rule
mappings are bounded and stay out of control records. Rendering prepared phonemes
does not run G2P again; candidate raw-text bypasses are rejected.

## LF4: Candidate pauses and audio fidelity

Comparison target gaps: continuation 0, sentence 0.12 s, paragraph 0.28 s, heading
0.45 s and footnote transition 0.20 s. These exact values were accepted in the LF6 listening decision.
Only exactly zero edge frames count toward a gap; near-silence is not classified
or trimmed. Existing natural near-silence can therefore lengthen perceived pauses.
Explicit zero gap preferences remain zero. Streaming gap buffers are bounded and
cancellable, with no inserted leading/trailing gap. WAV tests compare speech bit
patterns, including signed zero, subnormals and values beyond full scale.

VoiceRelay's legacy 0.15-second artifact gap remains explicit for legacy jobs.
Candidate artifacts carry one scheduled assembly policy; the encoder does not add
that old gap again. Mixed/unknown policies are rejected. AAC podcast/sample
encoding remains 64 kbps/24 kHz; lossy AAC is not asserted bit-identical to WAV.
Soprano's established frontend and native-rate WAV path remain unchanged. Existing
native-rate Libro export behavior is distinct from the fixed podcast/sample profile.
There is no normalization, leveling, gain, limiter, compression or crossfade.

## LF5: Consumers, recovery and progress

Libro, live pronunciation previews, direct speech and the sample utility use the
common final preparation API. VoiceRelay passes captured voice/speed into semantic
planning, saves the prepared plan before synthesis, and renders each prepared
chunk once. Its queue wrapper forwards preparation and the captured dictionary to
the single reusable helper. App source/automation/publication ownership stays local.

Incomplete incompatible plans are replaced once, with a preview notice, after
successful preparation. Existing chunk files remain until existing scoped cleanup
commits their replacements. Finished/published media is not regenerated. An
integrity-confirmed file already placed before interrupted publication retains its
old semantic plan and audio, even after scratch removal or a policy upgrade.
Damaged/conflicting finished-source metadata fails for inspection instead of
re-rendering over the recording. Old binaries cannot reuse the new prepared
checkpoints; rollback preserves final media but can require explicitly restarting
unfinished work from retained source.

Libro reports pronunciation preparation in measured passages before freezing the
final synthesis total. VoiceRelay distinguishes provisional semantic counts from
final acoustic counts; where future article totals are unknown, its bar/percentage
refers to the prepared current article rather than an invented queue percentage.

The sample tool still accepts exactly one nonempty text argument, works offline
against prepared resources, renders the exact common projection, and exchanges the
source asset folder only after every output validates. Schema-3 manifests record
actual prepared utterances and readable regional/frontend/style/assembly provenance.
Samples were preserved throughout comparison evaluation and replaced only after
the operator accepted the profile and selected the new common phrase.

## LF6 evidence and operator gate

Final verified Release runs completed successfully; results and the neutral
listening handoff are recorded below. Debug/pre-number audit runs are diagnostic only;
they are not the definitive performance or listening set. Per-run diagnostics live
under isolated output roots to avoid rotation confusing memory measurements.

Developer tools extend the existing NarrationNativeCheck executable. Given an
explicit packaged worker and isolated workspace/output, its modes are `longform`,
`frontend`, `catalog`, `mixed`, and `contention`. No models are acquired by them.
The longform mode reads `NARRATION_CHECK_POLICY` solely for controlled evaluation.
No corresponding app setting exists.

The operator has now supplied the LF6 shipping/listening decision. The original
private-document freeze retest, GUI, OCR/caption quality and final app/sample
listening remain operator-owned. LF7 activation and archive evidence are appended
below; the following table preserves the pre-decision comparison evidence.


## Verified results (October 15)

| Gate | Evidence |
| --- | --- |
| Required Libro/shared checks | `bash scripts/check.sh`: AppPresentation, shared suites, native dependency number fixtures, preparation fixtures, LibroCore 16 tests and project/plist checks passed. Two pre-existing real-preview/sample regeneration checks stay opt-in; no production samples were regenerated. |
| VoiceRelay full suites | 296 core tests and 141 app tests passed, with the shared native fixture enabled. Includes two queued articles under both policies, one-helper reuse, dictionary forwarding, completed-media recovery, fixed totals and existing lifecycle/publication fixtures. |
| Native regional frontend | 32 US/GB cases passed offline, including explicit overlong-word rejection. Independent native number spelling fixtures passed. |
| Explicit British installation | Fresh isolated installation from the pinned public resource URLs completed with all hashes/inventory accepted; existing US assets were cloned and preserved. |
| Catalog smoke | All 28 supported Kokoro voices and Soprano passed with the packaged Release helper, offline. Soprano retained legacy text routing and native 32 kHz WAV. |
| Actual PCM fidelity | Six zero-frame assembly regressions passed, including exact speech bit patterns from an isolated native-generated WAV. AVAudioFile's valid partial reads are handled in the fixture. Independent model renders are not assumed bit-identical. |
| Both app bundles | Complete ad-hoc Release build/signature checks passed, with helper, Metal and British notice present, no GUI MLX symbols, and all 29 original bundled sample hashes unchanged in each app. Source team/account settings were preserved. |
| Docs/packaging | Shared and VoiceRelay local-link checks and synthetic packaging failure/atomic replacement fixtures passed. |

The final 12-page PDF + 600-word Markdown candidate run completed with one worker:
coordinator physical-footprint peak **18,678,504 bytes**, Kokoro helper
**2,054,178,376 bytes**, Soprano helper **764,429,536 bytes**. This is the synthetic
coordinator, not the SwiftUI GUI. The original private-file retest remains open.
The two actual packaged helpers completed in foreground-then-background order;
the resident background helper peaked at **1,564,919,248 bytes** while waiting,
and cancellation during admission joined/reaped it without publishing output.

Matched benchmark medians (three voices, two speeds, two repeats per profile):

| Profile | Render real-time factor | Helper peak bytes | Heart utterances at 1.0× |
| --- | ---: | ---: | ---: |
| Preserved baseline | 0.0463 | 2,077,066,704 | 25 |
| Correctness/resources | 0.0488 | 2,100,151,784 | 26 |
| Phoneme packing | 0.0477 | 2,109,949,416 | 20 |
| Packing + pause candidate | 0.0466 | 2,057,455,080 | 20 |

These wall-time figures include admission, bounded IPC and WAV writes; AAC
encoding was measured separately (about 1.1–1.2 s median). Candidate frontend
preparation medians were about 0.50–0.54 s, with preparation/startup/first PCM at
about 1.06–1.12 s. Hardware/toolchain and exact files/settings are in the private
manifests. The comparison tool itself retains manifests and hashes complete WAVs;
its larger footprint is not a GUI/pipeline memory measurement.

Correctness captures retain the legacy source projection but use common strict
prepared packing. Restored numeric expansions can require an extra utterance;
therefore that A/B pair does not isolate audible style-row changes alone. No
subjective benefit is inferred from token counts or timing. Repeat waveform hashes
vary despite equal durations, so repeats remain in the evidence and independent
inferences are not used as a bit-identity test. The same captured native samples,
plus adversarial synthetic values, pass exact assembly bit checks.

The common pause listening captures use no explicit artifact-gap override.
VoiceRelay retains its stored nonzero artifact gap as a minimum target rather
than a second inserted gap; explicit zero disables added gaps. Validate this
app-specific stored-gap behavior after profile selection. No user setting was
silently rewritten.

### Reproducible developer commands

Run from the shared package root, with prepared isolated assets and matching built
helpers. Final copies are `.build/longform/final-apps/Libro.app` and `VoiceRelay.app`.
The exact helper hashes accompany each run. Example executed profile command:

```sh
NARRATION_CHECK_POLICY=phoneme-200-pauses-candidate-1 \
  .build/out/Products/Debug/NarrationNativeCheck \
  .build/longform/final-apps/Libro.app/Contents/Helpers/LibroSpeechWorker \
  .build/longform/workspaces/candidate \
  .build/longform/verified-phoneme-200-pauses-candidate-1 \
  longform Tests/Fixtures/Longform/corpus.json
```

Outputs are deliberately not overwritten; use a new isolated destination to repeat.
The same command shape ran correctness and packing profiles. The `frontend` mode
adds `Tests/Fixtures/Longform/frontend.json`; `catalog` and `mixed` need no extra
argument; `contention` adds the VoiceRelay packaged helper path. Only explicit
installation, separately invoked in a fresh workspace, acquired regional assets.

```sh
swift scripts/make-longform-report.swift "$PWD/.build/longform"
NARRATION_NATIVE_PCM_WAV="$PWD/.build/longform/verified-phoneme-200-candidate-1/af_heart-1.0-1.wav" \
  swift test --disable-sandbox --no-parallel --jobs 4 --filter ZeroFrameAudioAssemblerTests
```

The report contains 12 neutral A/B pairs and a rating sheet under
`.build/longform/listening/`; all 24 AAC copies match the original captured bytes.
It does not play audio automatically or change playback volume. Start with Heart
pairs 1–3; speed is pair 4. Michael occupies pairs 5–8 and Emma pairs 9–12.
The operator returned choices; the accepted activation decision is recorded above.

## LF7: Accepted baseline and final artifacts

The operator chose Heart at 1.0× with `phoneme-200-pauses-candidate-1`, then
selected the common sample text:

> Hello, I can narrate everything from short articles to entire ebooks. Let's get started on a new read together!

The exact tested packing, reference-row, frontend and pause constants are retained;
the internal policy identifier remains unchanged for evidence/recovery continuity.
New SpeechSettings use 1.0×; saved speeds/admitted settings still decode unchanged.
All 29 samples were generated offline using the shared planner/session/engine and
atomically replaced only after AAC validation. The prior complete resource set
is preserved privately at `.build/longform/accepted/previous-voice-samples/`.
Every schema-3 record contains its actual prepared plan/provenance. The utility
still has exactly one text argument; an optional `NARRATION_SAMPLE_WORKSPACE`
environment variable selects an explicitly prepared isolated workspace exclusively.

The duplicate legacy rendering/assembly loop was removed. Soprano and archived
comparison compatibility delegate to the common prepared-plan renderer; production
Kokoro cannot bypass its prepared phoneme contract. Character projection remains
for Soprano, previews and explicit historical comparisons, not as a shipping
Kokoro quality mode. Tests now distinguish those compatibility fixtures from the
accepted default and verify one preparation pass, one worker and no second G2P.
Obsolete Python/FFmpeg/96 kbps instructions were removed from VoiceRelay's
contributor guide. Its manual Info.plist now expands the category already chosen
in Xcode, resolving its Archive category warning without changing that choice.

### Final automated gates

- Required `bash scripts/check.sh` from Libro passed: AppPresentation 2 tests,
  shared suites 162 tests (3 opt-in skips), native number/dependency preparation
  fixtures, LibroCore 16 tests, shell and project/plist checks. The native Float32
  assembly opt-in was separately run against the accepted Heart capture: 6 tests
  passed. Remaining preview/native catalog fixture skips are explicit; all 29 real
  samples were actually regenerated by the developer utility.
- VoiceRelay's complete rerun passed 296 core plus 141 app tests with the shared
  native fixture enabled. The earlier failures were retired chunk-count/default
  assumptions; regressions now assert source coverage, prepared dispatch and
  one-helper reuse under the accepted default. No production replay was added.
- Both final Release archives passed with controlled ad-hoc signing overrides,
  leaving configured personal-team settings intact. Complete app/helper signatures,
  arm64 binaries, macOS 27 minimum, correct category metadata, Metal, British
  notices, source-manifest/sample hashes and GUI/MLX isolation were verified.
  No Python/FFmpeg executables or Python sources ship in either copy.
- Both actual packaged workers separately completed the synthetic 12-page PDF plus
  600-word Markdown workload with one resident helper and OS-denied networking:

| Packaged worker | Coordinator peak bytes | Kokoro helper peak bytes | Soprano helper peak bytes |
| --- | ---: | ---: | ---: |
| Libro | 21,430,992 | 2,062,992,944 | 765,756,664 |
| VoiceRelay | 19,382,968 | 2,117,748,200 | 762,955,024 |

- Actual packaged-helper arbitration completed foreground Libro before background
  VoiceRelay. Resident waiting background peak was 1,592,952,272 bytes; waiting
  cancellation reaped the helper without publishing output. These are controlled
  helper/coordinator measurements, not GUI/private-document acceptance or hard caps.
- Shared/VoiceRelay document links, fake packaging failure/replacement fixtures and
  Git whitespace checks passed. Two nonblocking Xcode/tooling diagnostics remain:
  App Intents extraction skips an absent AppIntents dependency, and SwiftPM reports
  a missing creator for its generated MLX resource bundle's MacOS node. Metal and
  complete signatures/resources were independently verified; no library or build
  warning was suppressed to obtain these results.

Final private outputs under `.build/longform/accepted/`:

- `Libro.xcarchive`, `VoiceRelay-arm64.xcarchive` and directly usable
  `apps/Libro.app`, `apps/VoiceRelay.app`.
- `artifacts.json` with full verification flags and helper/source sample hashes;
  `Libro-mixed/mixed-results.json`, `VoiceRelay-mixed/mixed-results.json`,
  `contention/contention.json` and the bounded normalization diagnostics.
- Final shared/Libro and native PCM logs, selected-profile/ratings/source manifests,
  the preserved prior sample set and local archive/VoiceRelay test logs.

The first successful VoiceRelay archive remains `VoiceRelay.xcarchive` as historical
evidence. Its app/helper were already arm64, but package dependencies also compiled
Intel objects; the final invocation explicitly sets ARCHS/ONLY_ACTIVE_ARCH and
includes the category metadata fix.

```sh
# From Libro:
LIBRO_CONFIGURATION=Release bash macos/scripts/build.sh \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  CODE_SIGN_ENTITLEMENTS= PROVISIONING_PROFILE_SPECIFIER= \
  -archivePath ../swift-packages/.build/longform/accepted/Libro.xcarchive archive

# From VoiceRelay:
xcodebuild -project VoiceRelay.xcodeproj -scheme VoiceRelay \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/DerivedData" -disableAutomaticPackageResolution \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS= PROVISIONING_PROFILE_SPECIFIER= \
  -archivePath ../swift-packages/.build/longform/accepted/VoiceRelay-arm64.xcarchive archive
```

LF7 automated integration is complete. Final app/sample listening, the original
private PDF/Markdown freeze retest, GUI/OCR/caption quality and normal team-signed
Keychain/live publishing acceptance remain operator-owned. Existing recordings
were not regenerated. The accepted profile does not cure every frontend error:
actual offline diagnostics reproduce unit/temperature and contextual homograph
failures. [The researched next normalization increment](TEXT_NORMALIZATION_RESEARCH.md)
records primary sources, native API probes, precise failures and a source-preserving
implementation design. It is not silently included in this accepted acoustic baseline.
