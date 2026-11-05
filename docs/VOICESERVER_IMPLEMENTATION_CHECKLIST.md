# VoiceServer implementation checklist

Current implementation, November 4, 2026: production factories now share the
coordinator, including cold frontend promotion, metadata CPU reads and Libro's
explicit recovery/access/Resume/retention UI. VoiceServer now has bounded HTTP
routes, bearer credentials, streaming/complete audio, Settings, private listener
selection and self-only Tailscale CLI discovery. It defaults off. New API fixtures
and shared recovery/ownership cases pass; final integration evidence is recorded in
[current status](IMPLEMENTATION_STATUS.md). Native listening, signed GUI/Keychain,
client streaming and live-network/sleep acceptance remain operator-owned.

The full gate `full-89690433-8A7A-4A1E-ABAE-6C62550ECFFD` passes, including 383
VoiceRelay core and 185 app cases; the 13 API fixtures include slow-write cleanup
and exact bounded PCM conversion without gain. Debug/Release builds and four
bundle audits pass in `release-39234881-C4E3-483F-ABF1-CA62A4BFB95A`. The evidence
index is `.local/validation/voiceserver-api-20261104/gate-result.json`. These checks
did not bind live sockets, run actual models or exercise GUI/signed Keychain.

Historical stage status (November 1–3): the user authorized the bounded VS00 proof on November 1, 2026. The
synthetic proof is implemented in the existing fixture executable and tests.
The November 2 continuation resolves the VoiceRelay assertion failures, proves
loaded-initialization cleanup and corrected Qwen numerical parity, and begins
shared production admission/checkpoint primitives. An opt-in app-owned coordinator,
shared render adapter and private PCM recovery journal now pass synthetic integration.
Opt-in VoiceRelay checkpoint-store and Libro batch recovery adapters are now
implemented. Both apps now have opt-in lifecycle/setup/preview bindings and ranked
host inference admission. Opt-in maintenance, admitted CPU units, notification
wakeups/waiting status and non-seeking streaming codecs are implemented next.
Default activation, recovery UI/retention, complete preparation/review coverage,
HTTP and Settings remain pending and authorized next. The operator accepted the
offline bounded-unit response-codec clips on November 3; raw incremental Qwen and
live-client streaming acceptance remain open.
The user authorized the next native feasibility gate on the same date; its
opt-in helper/native-check seam is implemented. Normal app scheduling, serving
IPC and HTTP remain unchanged. Bounded native reuse/first-unit evidence is recorded
below; production streaming and listening acceptance remain open. The pre-feature source
baseline is `e81a994`. Checked boxes describe only their stated fixture scope.
Current test commands live in [Development](DEVELOPMENT.md); manual
acceptance is recorded only in [Operator validation](OPERATOR_VALIDATION.md).

## Agreed contract

- Native Swift HTTP service and existing private Swift MLX helper only. No Python,
  MLX command-line server, duplicate resident model weights, overlapping inference
  or alternate synthesis backend. Reuse compatible loaded weights within their
  owning helper. Cross-app handoff has a separate residency policy below.
- VoiceServer is its own Settings pane, styled after Publishing. Model, voice,
  language, speed, delivery and pronunciation come from existing infrastructure.
- The per-user processing order is TTS API > Libro > VoiceRelay podcasts.
  Both API response modes outrank both apps' lower-priority work. Streaming cancels
  unfinished lower-priority inference and rolls it back to the last verified
  checkpoint; complete-file requests use cooperative safe-boundary yield.
  Libro-over-podcast handoff retains cooperative safe-boundary yielding.
- Keep live API requests FIFO; do not truncate another active API response.
  Streaming preempts Libro/podcast work, not another accepted API response.
  Continuous API demand may delay Libro indefinitely; Libro demand may delay
  podcasts. No aging exception weakens this order.
- Both apps use shared scheduling, suspension and checkpoint primitives. Each
  app controls only its own helper; VoiceRelay never signals Libro's process.
  Automatic suspension preserves work and resumes in priority order.
- API keys authenticate requests; Tailscale or the user's VPN supplies private
  transport. No TLS, certificate, firewall, VPN or embedded-tailnet management.
- Preserve source text, settings, completed PCM, transcripts, recordings, episode
  IDs and published media. No normalization, gain, limiting or volume leveling.
- Initial Orpheus API support is complete-file only, pending new native streaming
  evidence. MP3/PCM streaming defaults remain unchanged: an unsupported selected
  model returns an actionable unavailable response before priority admission;
  never silently buffer, switch models or alter the existing GUI selection.
- Initial Qwen streaming uses complete bounded semantic units. Its raw incremental
  callback remains probe-only until continuity/listening acceptance passes;
  corrected decoder-boundary numerical parity passes in the November 2 gate.
  successful cancellation, exact sample counts and fast first audio are insufficient.

## Verified starting points

The normal `--serve` worker reads its control loop serially around awaited generation.
A cancel record alone cannot interrupt that operation. Host request cancellation
currently marks the worker terminal; session close then stops/reaps the helper.
Those paths must be separated from recoverable job cancellation. A reaped process
cannot retain live MLX arrays; OS file caching is not resident-model reuse.

The pinned adapters contain cancellation checks, but their responsiveness and
post-cancellation state reuse differ and require per-adapter validation. Preserving
weights does not mean preserving an interrupted job's KV cache or decoder state.
The current engine retains model references across generation calls; clearing free
allocator buffers is distinct from releasing those referenced weights.

Podcast execution has integrity-checked per-chunk checkpoints and can overlap one
validation/commit with subsequent synthesis. Explicit Stop discards interrupted
scratch; ordinary cancellation leaves a paused row. Neither is automatic priority
suspension. The helper currently returns whole generated utterances, not a
sequence of audio frames. Large-model sessions also currently reap at utterance
boundaries; an active-demand handoff reuse policy needs a narrow explicit update,
not a global removal of memory safeguards. These are gaps, not existing guarantees.

The shared InferenceLease currently has only interactive/background admission.
It does not notify an active lower-priority owner to yield. Libro's
BatchQueueControl.checkpoint is a cooperative pause barrier, not a durable chunk
commit: NativeSpeechSession renders through an AtomicAudioWriter whose abort path
discards its temporary output. Three-class admission and reusable Libro recovery
checkpoints are new work; neither is established by the existing pause UI.

Source inspection of the pinned adapters also distinguishes token events from
playable audio:

| Selected model | Existing Swift audio stream behavior | Initial implementation route |
| --- | --- | --- |
| Kokoro | generateStream yields audio after generate finishes; the prepared-phoneme path returns a complete utterance | Bounded first semantic unit, then normal units, preserving prepared phonemes |
| Qwen3-TTS CustomVoice | Owned callback and opt-in overlap-bias correction now pass numerical parity/reset | Bounded first semantic unit initially; raw callback awaits continuity/listening acceptance |
| Chatterbox Turbo | generateStream wraps complete generation before yielding audio | Bounded semantic units; cancellation checks must reach its inner generation stages |
| Orpheus | Streams tokens, then decodes/yields final audio | Bounded semantic units; token events are not first audio |
| Soprano | Public incremental stream owns a hidden producer task | Bounded semantic units for the probe; producer ownership/join remains required for incremental use |

These are source observations, not measured latency or listening acceptance.
At the design baseline VoiceRelay did not embed Libro's native LAME library;
the November 2 codec slice adds explicit embedding/signing and bundle checks.

## Design review decisions

Keep the native helper and shared model controls. Prove cancellation, safe model
reuse and first playable audio before undertaking the wider scheduler integration.
Do not build a general job engine, durable codec-state system or second model host.

Separate ownership domains: shared per-user coordination ranks both apps' demand;
each app owns its jobs and helper lifecycle; a helper owns its loaded model and
generation operation. The podcast pipeline keeps its database and publishing,
and Libro keeps batch/destination decisions. API requests need no article,
Reading List access, WebDAV or healthy podcast store. Reuse checkpoint mechanics
through narrow persistence adapters rather than sharing application databases.

The HTTP contract needs a correction: OpenAI speech clients can read a streaming
response without sending a JSON `stream` flag. The official
[speech SDK interface](https://github.com/openai/openai-python/blob/main/src/openai/resources/audio/speech.py)
and [speech guide](https://developers.openai.com/api/docs/guides/text-to-speech)
demonstrate this. Default MP3/PCM delivery should therefore stream; clients saving
a file can consume the same response. `stream: false` is an optional VoiceServer/MLX
extension for a fully buffered file. `stream_format: "audio"` describes binary
output, not an instruction to buffer. WAV remains complete-file output initially.

Prefer the installed, signed Tailscale CLI as the macOS integration boundary.
Its [documented CLI mode](https://tailscale.com/docs/reference/tailscale-cli?tab=macos)
handles the client's platform-specific access. Direct LocalAPI discovery is
optional later: macOS variants differ in socket/credential access, and private
XPC or credential-discovery mechanisms are not a stable third-party SDK.
All VoiceRelay integration code remains Swift; no extra runtime is bundled.

Accepted API requests remain FIFO, so an active complete-file request can delay
a subsequent stream; use a short bounded
live queue and deadline rather than promising immediate multi-client service.
The user has superseded the previous Libro-first policy: API demand preempts
Libro as well as podcasts. This covers cooperating NarrationApps processes,
not unrelated applications or forcible interruption of executing GPU kernels.

Shared code does not share live MLX allocations across helper processes. For the
bounded first proof, retain app-owned helpers and warm reuse within the owning app.
On a cross-app ownership change, the losing app releases its model before the
winner loads, avoiding duplicate resident weights. This entails a cold reload even
for the same model. Coordinated residency must include idle loaded helpers, not
just the current GPU owner. If native evidence shows that reload dominates the
latency goal, revisit a single cross-app model host before full integration.
Such a host adds authenticated IPC, version/lifecycle and app-exit ownership work;
it is not silently included in the first proof, nor is cross-process warm reuse promised.

## VS00 - Feasibility and contract gate

- [x] Obtain final user confirmation of the bounded proof described below before
  implementing it. Approval of the design discussion alone does not start code work.
- [x] Before broad refactoring, extend the existing isolated worker/native-check
  seams to exercise cancel -> quiescent -> reset -> next generation on the same
  loaded model. Fixtures establish state-machine behavior; native evidence is separate.
- [ ] With explicit operator authorization and installed assets only, validate
  cancellation responsiveness, safe reuse, incremental audio and output continuity
  for each supported adapter. Do not infer these guarantees from Swift Task APIs.
- [x] Produce one minimal native request-to-first-playable-audio path before
  integrating the full podcast scheduler or Settings. No Python/server prototype.
- [ ] Set bounded cancellation, queue, output and write-deadline policies from
  evidence; define unsupported/slow-model behavior before enabling the feature.
- [ ] Lock the wire contract below using ordinary configurable OpenAI clients.
  Avoid adding SSE, WebSockets, batching or arbitrary per-request model selection.
- [ ] Reuse pinned dependency/patch preparation and existing test targets. Keep
  unfinished feature work disabled; this checklist does not authorize implementation.

### First bounded proof — authorized November 1, 2026

- [x] Extend the existing Swift fixture tools to run two isolated client processes
  representing Libro and VoiceRelay. VoiceRelay submits API and podcast demand;
  all locks, tickets, workers and checkpoints use temporary synthetic storage.
  No actual app launch, model download, live HTTP listener or Tailscale access.
- [x] Implement the smallest shared three-rank admission/preemption protocol and
  typed suspension path, with cancellable fake workers and verified chunk fixtures.
  Do not implement Settings, a general scheduler service or production database
  migrations in this slice.
- [x] Prove: podcast waits for Libro; Libro chunk 1 commits and chunk 2 begins;
  accepted streaming API demand revokes chunk 2; Libro quiesces and preserves
  chunk 1; API A/B finish; Libro regenerates chunk 2 and finishes; podcasts resume.
- [x] Also prove direct API-over-podcast preemption, full-file safe-boundary yield,
  manual pause/Stop while automatically suspended, requester disappearance,
  delayed cancellation and host crash without overlapping inference/residency.
- [x] Count model initialization and residency in the fixture trace. Same-app
  compatible handoff reuses its model; cross-app handoff releases before loading.
  Fixture timing is not evidence of actual MLX or model-load performance.
- [x] Report the diff, deterministic trace, focused tests and remaining native
  questions for review before broader integration. A real-model cancellation/
  first-audio probe remains a separately authorized operator-owned step.

### VS00 proof results and design refinements — November 1, 2026

Implementation is confined to `NarrationFixtureWorker --priority-proof` and
`NarrationCoreTests/VoiceServerProofTests`. Both simulated app clients use the
same fixture admission protocol; each owns a separate model-free helper process.
The protocol is fixture-only, with an explicit private temporary root and no
production lock default. No manifest, dependency, GUI, native adapter, HTTP,
Tailscale or production database changes are included.

The driver advances explicit observation and generation/drain barriers. Clients
choose priority suspension and resumption on each observation; this does not yet
implement app wakeup delivery, production polling or a background scheduler.
The fake producer is a cancellable Swift task, followed by a controlled drain.
Load/reset events are state-machine evidence, not allocated MLX weights,
playable audio or cancellation performance. Synthetic PCM descriptors are
persisted atomically and SHA-256 verified; late commits are fenced by job/epoch
and one-commit-per-attempt state.

Ten focused cases cover nested ordering/FIFO, direct same-app streaming
preemption, complete-file safe-boundary yield, manual pause/Stop while suspended,
queued/active requester disconnect, delayed cancellation, host death with an orphan helper,
crashed waiting tickets, idle resident handoff and checkpoint reopening. The
independent trace auditor rejects overlapping loads/generation, release before
quiescence and generation before reset. Same-app podcast → A → B → podcast
retains the helper PID with one initialization. Cross-app changes unload before
loading, including idle helpers. Libro's committed PCM hash survives suspension
and reopening unchanged.

The deterministic nested order is:

```text
Libro load #1; chunk 1 commit; chunk 2 start
API A accepted; API B accepted; podcast remains waiting
Libro revoke chunk 2; cancel; quiescent; reset; unload
VoiceRelay load #1; API A finish; API B finish; unload
Libro load #2; regenerate/commit chunk 2; commit chunk 3; unload
VoiceRelay load #2; podcast resumes; finish; unload
```

Focused logs and full synthetic traces are retained locally under
`.local/validation/voiceserver-vs00-20261101/`. Reproduce from the repo root with
`bash scripts/check.sh --tier quick --scope shared --filter VoiceServerProofTests`;
the existing full fixture gate also discovers the suite. Fixture-only work
requires no new app artifacts or marketing-version milestone.

All ten focused tests pass, and all ten pass again inside the full fixture run
`.local/validation/full-D0553F57-D1C9-416D-A7CE-424E8E9A266E/`. That **full gate
fails overall** on three assertions in unchanged VoiceRelayCoreTests:
`completeFixtureUsesCustomizedAudioAndIsIdempotent` and
`reviewedSpeechPublishesMultipleArticlesAndResumesOffline` reject fixture source
URLs in feed XML; `xcodeProjectLoadsOptionalPrivateSigningForBothConfigurations`
expects include lines without the existing `Version.xcconfig` include. Shared and
Libro suites pass, as do 183 VoiceRelay app tests. No VoiceRelay product/test/config
files were edited to suppress those failures. Packaging after the failed test
command did not run. An earlier attempt failed before tests because the outer
sandbox denied the harness's nested `sandbox-exec`; the expanded-access rerun
above reached the actual suites. This is not a green full-gate or native receipt.

The proof supports the proposed ownership policy, with these integration
requirements made explicit:

1. **Protect the helper lifetime, including idle residency.** A dead host's
   unlocked ticket cannot authorize new weights/compute while its helper drains.
   The fixture helper owns residency exclusion from load through quiescence and
   unload; parent EOF cancels and joins its producer before releasing protection.
   Production must preserve current and legacy kernel exclusion locks for this
   lifetime too. A new residency lock alone cannot protect against an older app
   that ignores it. Establish a helper-owned compatibility-lock handshake before
   model load; avoid independently acquiring the same exclusive lock in host and
   helper. Older-app preemption remains unsupported.
2. **Fence by job identity and epoch together.** Different jobs can both have
   epoch 1. The proof rejects an old A cancellation while B runs at that epoch,
   as well as results from Libro's discarded attempt. Native IPC must also
   correlate the worker instance and quiescent/reset acknowledgements.
3. **Use one gate for registration and the final launch check.** A host's rank
   decision is provisional. The helper rechecks the highest live ticket while
   acquiring residency under the registration gate. Carry that fence through
   initialization and every generation unit; observe demand while idle too.
4. **Keep native feasibility ahead of integration.** The proof does not settle
   adapter responsiveness, GPU synchronization, reset safety, cancellation/reap
   deadlines, first playable audio or reload cost. The next gate is an explicitly
   authorized installed-assets-only native probe with both apps idle. Implement
   responsive control reading, owned producer joins and the compatible lock
   handshake before broad VS01–VS03 integration. Do not infer a universal timeout
   or promote the fixture protocol directly into production.

The user subsequently authorized the native gate below. Synthetic ordering alone
does not complete VS00 or authorize direct Settings/HTTP/full scheduler integration.

### Native feasibility gate — authorized November 1, 2026

The existing helper and NarrationNativeCheck now have explicit opt-in
`--handoff-probe` / `handoff` modes. The default `--serve` path and its existing
terminal cancellation behavior are unchanged. No app launches, listeners,
settings changes, model acquisition or new dependencies are included. Reproduction
and prerequisites live in [Development](DEVELOPMENT.md#additional-model-checks).

The shared `SpeechProbeServer` owns a single cancellable producer and joins it
before the backend drains GPU work and acknowledges ready. Commands/events are
bounded and versioned independently of normal serving, with session, worker
instance and full job/attempt identity. There is one outstanding PCM frame;
revocation wakes a stalled producer, and even the final frame acknowledgement
must settle before completion/ready. Reset failure makes the probe unusable.

The native backend acquires the existing current/legacy inference locks itself
before loading, with no competing host-owned lock. It retains those locks and
ModelStorageLease through loaded idle periods, cancellation, reset and EOF.
Shutdown drops model references, drains streams/allocator buffers and then releases
protection. The host retains the existing per-model sampled footprint budget and
bounded owned-process termination/reap fallback. Diagnostics go to `/dev/null`;
controlled receipts contain no request text or raw stderr.

Each installed-model run captures that model's default voice, speed 1× and seed
42. It generates a multi-unit control passage, injects cancellation 50 ms after
the first inference-start event, then generates the control passage again in the
same loaded helper. Prepared phonemes remain mandatory for Kokoro. All paths use
direct, owned generation calls and the existing semantic units; model math and
audio levels are unchanged. Soprano's direct API internally uses a token stream;
the recorded `soprano-owned-producer.patch` exposes that internal task to both
consumers and joins it before decode/cancellation returns. Cancellation alone,
including a fast observed acknowledgement, cannot establish this guarantee.
Public incremental streams without owned producer handles remain unused.

The host checks owned PCM paths, sequence, size, rate/channels and finite samples;
publishes independent lossless WAV units and compares every decoded Float32 sample
with the supplied PCM. First playable unit precedes whole-request completion.
Receipts separate initialization, warm request-to-first-WAV, cancel-to-quiescent/
ready and peak sampled footprint. These are local probe metrics, not server TTFA,
network playback or listening acceptance. Control/resumed hash equality is
informational and does not impose identical stochastic regeneration.

Six isolated control-path regressions, alongside the ten first-proof tests, pass:
same-worker reuse after cancellation and completion; stalled consumers; stale
cancel/ack records; reset barriers retaining exclusion; EOF/hung-reset fallback;
bounded control records and sanitized initialization failure. Native attempts are
retained under `.local/validation/voiceserver-native-20261101/`, including the
initial harness failures. AVAudioFile short reads must be accumulated; one read
is not necessarily the full WAV. Native probing also exposed the final-frame
acknowledgement race, now covered by back-to-back request regression.

The final packaged Release helpers pass all five shared-adapter probes after the
Soprano producer-join patch. Every receipt's worker SHA-256 matches its Release
bundle audit; Soprano uses Libro's helper and the four VoiceRelay adapters use
VoiceRelay's helper. Soprano remains Libro-only in the GUI/API selection contract.
Each run records one initialization, the same worker PID/instance after cancellation, valid finite PCM
and exact lossless WAV transfer. First and resumed unit times below both start
with the model loaded; the first request includes first-use preparation/kernel
costs. Initialization is separate. One early cancellation is injected per adapter;
these observations do not establish worst-case cancellation deadlines.

| Model / voice | Init (s) | First / resumed first WAV (s) | Cancel to ready (ms) | Resumed pipeline RTF | Peak footprint (GiB) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Kokoro / Heart | 0.40 | 4.02 / 0.48 | 33.0 | 0.037 | 1.55 |
| Soprano / soprano | 0.32 | 3.34 / 0.70 | 2.2 | 0.069 | 0.43 |
| Qwen3 / Ryan | 2.74 | 6.44 / 3.90 | 6.1 | 0.306 | 6.72 |
| Chatterbox / default | 2.46 | 3.04 / 2.11 | 7.1 | 0.211 | 3.69 |
| Orpheus / leah | 5.80 | 27.63 / 25.08 | 55.6 | 2.051 | 8.68 |

Pipeline RTF is resumed request time divided by generated audio duration,
including preparation, validation, unit WAV publication and reset. Orpheus took
79.47 seconds for 38.74 seconds of audio: early cancellation/reuse passes, but the
tested path is slower than playback. It therefore does **not** pass streaming
latency/continuity feasibility. A shorter first unit alone cannot fix sustained
RTF above one. Keep Orpheus unavailable for initial streaming; complete-file
requests remain planned. This policy does not change either app's narration.

Seeded control/resumed hashes match for four models; Chatterbox differs. That is
recorded without requiring identical stochastic regeneration. No listening,
linguistic fidelity or continuity acceptance is inferred from hashes or valid PCM.
The receipts and derived `native-summary.json` are under
`.local/validation/voiceserver-native-20261101/`; `*-owned/receipt.json` identifies
the final runs, and the summary verifies the corresponding bundle fingerprints.
Earlier Debug/setup failures and pre-fix measurements are retained separately;
the earlier Soprano fast-cancellation observation did not prove producer join.
The probe
now uses the apps' authored paragraph-window pipeline: treating the whole prompt
as one window had legitimately produced a single Qwen utterance and could not
prove first audio before completion.

Design follow-up before broad integration: prove a versioned, semantically safe
smaller first unit and an owned incremental Qwen producer, preserving normal
podcast segmentation and Kokoro prepared phonemes. Measure the actual cross-app
unload/reload path: observed initialization already costs 2.46–5.80 seconds for
the large adapters, so same-app warm results cannot stand in for cross-app TTFA.
Retain the app-owned-helper policy until that evidence justifies a separate model
host decision. No fixed production timeout follows from this one-shot probe.

Raw adapter incremental audio, initialization cancellation/EOF, changed
model/voice/reference selections, longer
memory stability, mixed-version idle residents, cross-app reload cost and actual
listening remain open. In particular, Qwen's existing incremental stream does not
expose its producer handle. Add a maintained, owned callback/join seam before
claiming safe incremental Qwen reuse; bounded-utterance results cannot establish it.

Final validation: the patched full fixture run
`.local/validation/full-0F9381B3-2943-485D-84C4-2C3218A136B4/` passes the six new
probe tests, ten first-proof tests, other shared/Libro suites and 183 VoiceRelay
app tests. It remains red on the same three unchanged VoiceRelay core assertions
named above. Debug/Release workspace builds and all four bundle audits pass in
`.local/validation/voiceserver-native-20261101/`, using isolated candidates under
`.build/VoiceServerNativeGate-5D767E69-3CC5-443A-A060-C4F6AC1E31E7/Build/Products/`.
Archives were unrequested. No installed or operator-tested app was replaced, and
no GUI, signing-account, client-streaming or listening acceptance is claimed.

### Live first-unit, incremental and reload gate — authorized November 1, 2026

The user's continuation authorizes this narrower follow-up before broad product
integration. It adds the opt-in `firstSentence` and `qwenIncremental` audio paths
and a two-native-helper `reload` driver. Normal app serving, segmentation, settings
and priorities are unchanged. No HTTP listener, app launch, model acquisition,
Tailscale or shared model-host architecture is included.

`live-first-sentence-1` selects a complete first sentence in the first ordinary
window using the platform sentence tokenizer. It preserves UTF-16 source offsets,
projection mappings, block identity, pronunciation applications and the remaining
ordinary boundary; crossing pronunciation overrides remain indivisible. The
ordinary planner and Kokoro's prepared-phoneme path remain in use. This policy is
explicit and live-only; do not use it to invalidate/resegment podcast checkpoints.

The recorded `qwen-owned-audio-callback.patch` exposes the pinned adapter's existing
incremental decoder synchronously on the probe's owned generation task. A throwing
consumer exits generation and runs decoder reset, with no hidden producer task.
The callback supplies only new codec tokens (`decodedTokens` advances after each
decode); it is not a cumulative waveform. The 0.5-second configured interval
currently means six codec tokens / 0.48 seconds of audio. No overlap removal,
crossfade, gain or decoder-math change is added. Each utterance must finish at
clean EOS with its exact codec-token/sample coverage. Silent frames are preserved.

The incremental harness records ordinary-paragraph and direct-first-sentence
controls, publishes/independently decodes every Float32 WAV frame, measures
same-unit boundary jumps, compares direct and incremental PCM, then deliberately
withholds the first frame's acknowledgement before cancellation. The same helper
must join/reset and regenerate incremental audio with more than one frame in its
first semantic unit. Frame counts and before/after-reset PCM diagnostics are
reported separately from listening or linguistic fidelity acceptance. Sequential
controls are local measurements, not a randomized latency benchmark.

Private probe wire version 2 adds `waitingForLease`, `leaseAcquired` and `unloaded`
events. The reload driver starts a VoiceRelay helper while Libro holds the actual
current/legacy locks and resident model, verifies that the new helper waits, then
cancels/joins Libro, observes unload and only then observes VoiceRelay acquire/load.
It records acceptance-to-first-WAV including helper startup, lease wait, old
unload, new load and first generation. This is a measured orchestration driver,
not the production three-rank scheduler. Production SpeechIPC remains version 3.

Eight probe-control, six first-unit and ten priority-proof tests pass (24 total).
The new cases cover multi-frame cancellation under backpressure, owned producer
reuse, safe cross-owner lease transfer, Unicode/abbreviation/Japanese
boundaries, pronunciation indivisibility and unchanged ordinary segmentation.
Debug and Release workspace builds and four bundle audits pass with isolated
ad-hoc candidates under
`.build/VoiceServerStreamingGate-B947F7A3-3A07-4F22-9D7C-6D35B864C1D3/Build/Products/`.
Evidence is retained under `.local/validation/voiceserver-streaming-20261101/`.
Archives are unrequested; installed/operator app bundles are preserved.

Native lifecycle/coverage checks pass with the audited packaged Release helpers,
but the incremental **continuity gate does not pass**. All runs are serial,
installed-assets-only and network denied. Defaults are Heart, Ryan and Chatterbox
default, speed 1×, seed 42. Smaller-first-unit results use the existing semantic
pipeline; the resumed measurements below exclude model loading:

| Path | Resumed first playable WAV (s) | Cancel to ready (ms) | Resumed pipeline RTF | Peak footprint (GiB) |
| --- | ---: | ---: | ---: | ---: |
| Kokoro / first sentence | 0.13 | 50.0 | 0.038 | 1.48 |
| Chatterbox / first sentence | 0.57 | 7.0 | 0.214 | 3.87 |
| Qwen / raw incremental probe, final parity-enforced run | 0.19 | 16.6 | 0.326 | 6.62 |

Qwen's final direct first-sentence control takes 0.90 s to its first WAV; the incremental
control takes 0.19 s and supplies six frames inside that same first semantic unit,
101 frames over the request. Both paths produce 1,138,560 samples. Regeneration
after stalled-frame cancellation is sample-identical to the incremental control.
However, incremental versus direct decoding differs by up to 0.2604 absolute
Float32 amplitude (mean absolute difference 0.00104), exceeding the probe's 0.001
numerical-review threshold. That threshold is a conservative parity check, not
an audible-quality standard. The first chunk of each new unit agrees within
about 0.000001; larger differences start at subsequent decoder chunk boundaries.
The same-unit boundary-jump diagnostic reaches 0.1091. No listening acceptance or
audible-defect claim follows from these numerical diagnostics.

Offline `pcm-boundaries.json` retains per-frame error/jump diagnostics. Source
inspection identifies a concrete hypothesis to test next: the pinned
`DecoderBlockUpsample.step` sums the next biased transposed-convolution output
with a stored biased overflow; this can add the learned bias twice in overlap
positions. The first-chunk agreement and repeated boundary differences support
investigating decoder state/overlap, but do not establish a validated model fix.
Do not hide the difference with gain, trimming, overlap guessing or crossfades.
The probe now fails its overall incremental gate on either direct/stream or
before/after-reset PCM parity failure while preserving the lifecycle evidence.
The earlier receipt with a green lifecycle/coverage outcome is retained as
diagnostic history, not incremental streaming acceptance.
The final `qwen-incremental-gated/receipt.json` records `reuseAndCoverageOutcome:
passed`, `continuityOutcome: blocked-pcm-parity` and overall `outcome: failed`, with
a nonzero exit. Both native Qwen runs reproduce the same PCM difference; the
summary uses the final parity-enforced receipt. `native-summary.json` reports
partial native acceptance and verifies all five runs against the Release bundle
fingerprints. The final harness build and explicit native failure check follow
the full fixture run; helper binaries are unchanged from the audited candidates.

| Native transfer | Accepted demand to first WAV (s) | Old cancel to ready (s) | Old unload (s) | New load (s) |
| --- | ---: | ---: | ---: | ---: |
| Libro Kokoro → VoiceRelay Kokoro | 2.75 | 1.65 | 0.027 | 0.36 |
| Libro Qwen → VoiceRelay Qwen | 4.09 | 1.45 | 0.031 | 2.20 |

Both transfers observe waiting, old quiescence/reset, old unload, then new lease
acquisition/load, using distinct PIDs and two model initializations. These transfer
requests interrupt the first inference in a newly loaded helper; they demonstrate
that warm millisecond cancellation cannot define a universal deadline. The local
acceptance-to-WAV clock includes helper startup and the probe's 100 ms wait check,
not HTTP transport or a player. The app-owned-helper policy remains in place;
cross-app warm weight reuse is not claimed. A shared model host would be a
separate architecture decision, not an implicit optimization.

Design outcome: keep the versioned smaller-first-unit policy for planned live
integration, use bounded Qwen utterances initially, leave raw incremental Qwen
disabled pending a targeted decoder-parity proof, and keep Orpheus streaming
unavailable. Before broad scheduler integration, prove responsive cancellation/EOF
during initialization plus failure/reap recovery, then exercise additional native
cancellation positions/settings and sustained memory. Derive production deadlines
from that broader evidence, including first-use and cross-app cases.

The full synthetic run
`.local/validation/full-600AF0BE-7C33-433F-921B-101F8CEF4EF5/` passes all 24
VoiceServer cases, other shared/Libro suites and 183 VoiceRelay app tests. It
remains red on the same three unchanged VoiceRelay core assertions described
above. Neither the partial native gate nor compilation closes client-streaming,
listening, GUI, protected-data or release acceptance.

### Initialization safety, decoder correction and shared foundations — November 2, 2026

The user authorized the remaining safety/decoder/stress gates and production
integration, and explicitly requested resolution of the VoiceRelay red assertions.
Those three assertions were stale: local feeds intentionally include recorded
publisher links/notes, and signing includes the shared `Version.xcconfig`. Tests
now verify those metadata/include contracts while retaining body/author/local-path
privacy assertions. Product publishing/signing behavior is unchanged. The complete
fixture run `.local/validation/full-C5082A95-69BC-4AC9-BB63-9B5DC50E7E9A/` passes,
including the 36 then-current VoiceServer cases, 355 VoiceRelay core tests, 183 app
tests and native packaging fixtures. Later shared-foundation checks are separate.

Initialization is now an owned task while the control reader remains responsive.
Cancel/EOF joins loading before GPU drain and model/storage/compatibility-lock
release. A cancelled/failed load is terminal and never emits job-ready. Private
probe wire version 4 includes a controlled `loadedAwaitingAdmission` barrier:
weights are actually held, but initialization is not acknowledged until the
correlated credit arrives. Stale credits cannot grant admission. Tests distinguish
load-entry cancellation (which can arrive before allocation) from cancellation/EOF
at this loaded-weight barrier. Production SpeechIPC remains version 3.

The full fixture run first exposed a new concurrent-close hang: Foundation
`waitUntilExit` remained in a cooperative-thread run loop after the child had
already exited. The owned test was sampled, stopped and retained as failed evidence
under `.local/validation/full-84FC9D55-350A-41BA-A729-578078BC82A9/`. The probe now
uses a bounded Foundation termination callback and one shared close result; it
does not add an unbounded second wait. Concurrent close is repeated 12 times,
and deinitialization also observes/reaps the owned process. Twenty control cases,
six first-unit cases and ten original priority cases pass after the fix.

The Qwen boundary error is reproduced by the actual upsampling layer with fixed
weights and nonzero biases: legacy split decoding differs by 0.75000012, while
the opt-in corrected path differs by only 0.00000012, with identical reset output.
The overlap had added the learned transposed-convolution bias twice. The recorded
`qwen-streaming-overlap-bias.patch` removes that duplicate feature-map bias only
for the new narration callback; ordinary app generation defaults are unchanged.
This is decoder arithmetic, not gain/normalization, trimming or smoothing.
Every bundle audit now runs the model-free CPU regression.

The final packaged Release Qwen run produces 1,138,560 samples over 101 frames,
six in its first semantic unit. Direct versus incremental maximum PCM difference
is 0.00000276, within the conservative 0.001 numerical threshold; after cancellation
under backpressure, regenerated incremental PCM is sample-identical. First resumed
WAV is about 0.17 s. This closes numerical parity/reset, not listening acceptance;
raw incremental Qwen stays probe-only and the initial bounded-unit policy remains.
Orpheus streaming remains unavailable based on sustained-throughput evidence.

All five installed adapters pass the serial native safety matrix with networking
denied: seven initialization/EOF phases per adapter, nine cancellation/reuse
cycles and ten completed short requests. The 35 phases cover lease wait, load
entry, loaded pre-admission and loaded idle; weights are unloaded/reaped before
the next owner can reacquire the compatibility locks. The 45 generation
cancellations cover immediate, inference-start and stalled-first-frame points.
Kokoro speed, Qwen/Orpheus voice changes and restored defaults are exercised;
default hashes restore for all except intentionally stochastic Chatterbox.

| Model | Loaded cancel → settled (ms) | Generation cancel → ready range (ms) | Stress peak (GiB) | Ready footprint tail spread (MiB) |
| --- | ---: | ---: | ---: | ---: |
| Kokoro | 5.4 | 0.4–24.4 | 0.93 | 58.8 |
| Soprano, Libro only | 6.4 | 0.4–12.5 | 0.37 | 14.5 |
| Qwen | 44.6 | 0.3–25.9 | 3.77 | 78.1 |
| Chatterbox | 75.8 | 0.4–1.4 | 3.43 | 12.1 |
| Orpheus | 277.7 | 0.5–2.6 | 7.01 | 31.5 |

These are bounded short-request observations within sampled budgets, not proof
of no growth or long-duration stability, and not universal production deadlines.
Earlier first-inference cross-app cancellation still took 1.45–1.65 s. Reference
changes, broader language/voice coverage, longer runs and listening remain open.
Receipts, fingerprint-checked `native-summary.json`, failed attempts and audits
are in `.local/validation/voiceserver-safety-20261102/`. Isolated ad-hoc Debug and
Release candidates are in
`.build/VoiceServerSafetyGate-7D6E7985-8B17-4715-ABA2-8CADB58AE07A/Build/Products/`.
Earlier v3 measurements are retained under `v3-before-loaded-barrier/`; the final
summary uses v4 receipts. No installed/operator candidate or published artifact
was replaced, and archives were unrequested.

Production foundation work now adds `SpeechWorkAdmission`, secured private
metadata tickets for API > Libro > Podcasts, FIFO among live API demands,
kernel-lock liveness, bounded records/counts and fail-closed ownership/link/schema
validation. `withHighest` rechecks registration and the nonblocking current/legacy
residency handshake under one gate. Its returned lease belongs to the helper from
before load through unload, not to an app host. Advisory snapshots cannot launch
work. `withDecision` provides the same registration fence for short final commit
decisions, distinguishing cooperative file mode from streaming revocation.

`SpeechAttemptFence` adds full job/attempt/epoch fencing, a verified contiguous
cursor with sparse checkpoints preserved, stale/duplicate rejection, Stop without
resurrection and quiescence before a new epoch. Hash/PCM verification remains
outside the lock and persistence adapters own the final short durable transaction.
This primitive does not itself validate bytes or implement a durable Libro journal.
Twelve admission/compatibility cases and six attempt-fence cases pass alongside
the 36 earlier cases (54 focused cases). Cross-process tests use isolated model-free
fixture clients; malformed metadata, unsafe links/permissions, capacity, foreign
tokens, crashed tickets and partial compatibility-lock acquisition fail safely.

Both apps still use their existing normal scheduling/session paths. Next is the
app-owned coordinator/helper adapter and the VoiceRelay/Libro persistence adapters,
including notification/fallback rechecks, captured settings, typed suspension and
durable Libro recovery. The shared primitives alone do not establish product
preemption, automatic resume, warm bursts or a working API listener.

Shared-foundation validation is green in
`.local/validation/full-3E9FB5F0-F42A-4E32-874E-2C03C4CD3504/`: all 54 focused
VoiceServer cases, other shared/Libro suites, 355 VoiceRelay core tests, 183 app
tests and packaging fixtures pass. The same-batch/different-job epoch case is
strengthened in the subsequent focused rerun. Debug/Release builds and four
bundle audits pass under `.local/validation/voiceserver-admission-20261102/`, with
separate ad-hoc candidates in
`.build/VoiceServerAdmissionGate-3C8CCD1A-90DD-4BB3-BCB2-14FF23FB1FD5/Build/Products/`.

Primary code seams:

- [Worker supervision](../swift-packages/Sources/ProcessingPipeline/SpeechWorkerProcess.swift)
  and [native session](../swift-packages/Sources/ProcessingPipeline/NativeSpeechSession.swift).
- [Helper generation](../swift-packages/Sources/NativeSpeechEngine/NativeSpeechWorker.swift)
  and [versioned IPC](../swift-packages/Sources/NarrationCore/SpeechIPC.swift).
- [Queue lifecycle](../VoiceRelay/Sources/VoiceRelayCore/SpeechQueue.swift),
  [worker ownership](../VoiceRelay/Sources/VoiceRelayCore/SpeechPipeline.swift),
  [checkpoint execution](../VoiceRelay/Sources/VoiceRelayCore/FixtureCoordinator.swift)
  and [native adapter](../VoiceRelay/Sources/VoiceRelayCore/NativeMLXBackend.swift).
- [Audio processing](../VoiceRelay/Sources/VoiceRelayCore/Audio.swift),
  [MP3 encoder](../swift-packages/Sources/AudioOutput/MP3Encoder.swift)
  and [shared admission](../swift-packages/Sources/NarrationCore/InferenceLease.swift).
- [Libro batch execution](../swift-packages/Sources/ProcessingPipeline/QueueCoordinator.swift),
  [manual queue control](../swift-packages/Sources/ProcessingPipeline/BatchQueueControl.swift)
  and [shared rendering](../swift-packages/Sources/ProcessingPipeline/ChunkScheduler.swift).
- [Settings](../VoiceRelay/Sources/VoiceRelayApp/SettingsViews.swift),
  [app lifecycle](../VoiceRelay/Sources/VoiceRelayApp/VoiceRelayApp.swift)
  and [credential patterns](../VoiceRelay/Sources/VoiceRelayCore/Delivery.swift).

### Coordinated render and recovery seam — November 2, 2026

`SpeechWorkCoordinator` now owns one reusable helper for explicitly opted-in native
sessions. `WorkerConfiguration.workCoordinator` defaults to nil, so both apps keep
their existing scheduling until their persistence/lifecycle adapters are complete.
The internal `--coordinated-serve` mode requires the private admission handshake;
wire version 5 carries demand metadata, prepared-text and prepared-utterance units.
Normal serving IPC remains version 3. There is no HTTP listener or new product CLI.

The helper atomically rechecks highest live demand at **every unit launch**, not
only model initialization. The host observes demand with a 50 ms fallback poll;
notification wakeups remain pending. Compatible initialization can transfer within
the app after the helper acquires residency. Incompatible/cross-app ownership
unloads and reaps before replacement. Model identity includes workspace, pinned
revision, regional frontend and reference recording; reference changes currently
reload conservatively. Broader reference/conditioning acceptance remains open.

Streaming revocation retries the unit inside the retained render operation, using
a new epoch and request spool. Complete-file work finishes the current unit before
yielding. Receipts identify each individual result, so discarding one validation
cannot clear a different pending result from the same epoch. Registration, Stop
and commit operations avoid inverted job-lock/registry-lock ordering. Pipe writes
are nonblocking with a two-second deadline; cancellation has a provisional
five-second acknowledgement fallback before bounded owned teardown. Existing
per-model footprint limits and configured request deadlines remain effective.
These are disabled-path engineering bounds, not a universal native latency promise
or the final HTTP queue/deadline policy.

`NativeSpeechSession` uses this coordinator for captured preparation and generation
when opted in, preserving its enclosing writer through automatic suspension.
`SpeechRenderJournal` durably captures a prepared plan, source fingerprint,
document order, destination, replacement decision, explicit gap and artwork digest independently of review
retention. PCM validation/hash/fsync precede the short admission/epoch-fenced
descriptor rename/fsync. Reopening verifies ownership, permissions, links, schema,
fingerprints and PCM hashes; sparse verified indices survive, and uncommitted
scratch never becomes a checkpoint. Reconstruction uses PCM, not codec state.
Corruption or mismatched consent fails closed. The host must still bind/revalidate
source and destination consent; batch discovery/recovery UI and safe journal
retention/repair are not implemented by this seam.

Seventy-three focused synthetic cases pass: 21 control/launch cases, eleven coordinator
cases, seven journal/render cases and the 34 existing first-unit/admission/fence/
priority-proof cases. The retained-render case commits unit 1, starts and cancels
unit 2 for streaming API demand, serves API audio in the same helper, then resumes
and publishes all three units with the original committed PCM intact. Another
case reconstructs completed PCM with a nonexistent helper executable, proving no
inference launch. Initialization transfer, API FIFO, cooperative file-mode yield,
manual pause/Stop, late commits, cross-app idle unload and stuck-worker replacement
are covered. A close-during-registration regression repeats 20 times and requires
no leaked demand ticket. Synthetic timing/tones are not native speech acceptance.
Cancellation racing an already-finishing reset also preserves the warm helper;
ignored old controls cannot become protocol failures in the next attempt.

Focused logs are retained in `.local/validation/voiceserver-coordinator-20261102/`.
The explicit installed-assets `NarrationNativeCheck coordinator` gate checks the
new host/helper seam separately; it does not replace the earlier cancellation,
continuity/listening or cross-app latency gates. Current reproduction commands
live in [Development](DEVELOPMENT.md#additional-model-checks).

Final full fixtures pass in
`.local/validation/full-8BA606D4-E5E5-42D1-95D8-73AA5313A802/`, including all
73 focused cases, 355 VoiceRelay core tests, 183 app tests and packaging fixtures.
Debug/Release workspace builds and four bundle audits pass. Separate ad-hoc
candidates are retained at
`.build/VoiceServerCoordinatorGate-25F8AE14-EA3F-4464-B56C-2F4F66EC8E83/Build/Products/`.
Earlier candidates are preserved.

All five installed adapters pass the serial, network-denied coordinator check:
prepared-text transfer, three bounded generations across podcast → API → podcast,
the same helper PID throughout and owned reap. Native receipts match the audited
Release worker hashes; `gate-result.json` in the coordinator evidence directory
indexes receipts, source/harness hashes and gate results. This check exercises
idle warm handoff, not active native cancellation timing, long-duration stability,
reference/region changes, audible continuity or HTTP streaming. Earlier native
cancellation evidence remains separate. Orpheus streaming remains unavailable;
Qwen raw incremental output remains probe-only. No app launch/install, model
download, live service, signing-account action, archive, commit or push occurred.

Next, bind VoiceRelay's pending validation/save transaction to these receipts and
connect Libro's durable batch/source/destination recovery, then wire both app-owned
coordinators, manual controls, setup/previews/OCR classification and waiting status.
Do not enable partial app scheduling or proceed to HTTP/Settings on the strength
of the isolated adapter tests alone.

### Persistence adapters and captured batch recovery — November 2, 2026

The opt-in native podcast adapter now returns a process-local `SpeechUnitReceipt`
and an owned, closed WAV. Receipts carry identity/epoch only, release the PCM buffer,
and are excluded from checkpoint Codable data. Existing saved checkpoints cannot
resurrect a live job. Normal non-coordinated persistence retains its prior path.

VoiceRelay validates/hashes audio, encodes the checkpoint, acquires its SQLite
writer and stages an invisible transaction **outside** the admission/epoch fence.
Only the final `COMMIT` is fenced. Revocation rolls back that transaction; a busy
database never holds the API registration gate. One validation may still overlap
the next inference. A typed rejected checkpoint retries the affected position
inside the same queue execution, discarding only uncommitted owned results, without
cancelling the backend, incrementing row attempts, resetting committed progress or
requiring manual Retry. Existing verified database chunks remain authoritative.

Article begin/end hooks bind captured demand to the active pipeline backend;
late finalizer cleanup cannot end a newer article. Explicit Stop closes only its
podcast job, preserving a same-app API context. Optional review retention runs
after durable acceptance and writer release; rejected audio never enters review.
Committed, uncertain or replaced files are protected from stale-result cleanup.

`LibroBatchRecovery` captures source/file identity and streaming SHA-256 proofs,
input encoding, original document IDs/order, settings, pronunciation entries,
narration options, cover bytes, output format, destination and replacement consent.
Private versioned records use one host writer, 0700/0600 ownership/link checks and
atomic fsynced updates. Queue ordering/manual pause writes run on an owned I/O
queue, never in MainActor control callbacks. Source hashing uses one 1 MiB block
per autorelease pool. Changed source or replacement bytes/identity fail closed;
old consent cannot replace newly changed output.

Opening a batch does not launch work. An explicit resume request excludes verified
completed outputs and skipped documents, retains the pending order and revalidates
the captured binding. The host must restore file access and obtain explicit Resume;
recovery does not grant automatic launch consent. Prepared plans and verified PCM
flow through `QueueCoordinator`/`ChunkScheduler` into the retained render adapter,
without repeating extraction/G2P or rereading the current pronunciation store.
Output is reconstructed from PCM; publication still runs the existing destination
and replacement checks. Metadata-save issues preserve completed recordings and
are reported separately through `BatchSummary.recoveryIssue`.

Manual pause is acknowledged even while priority-suspended, withdraws Libro's
demand, and remains independent of automatic waiting. Skip/Stop predicates end
queued/suspended work without waiting for API completion. Opted-in Libro sessions
close at document completion before another document's host extraction/OCR; they
do not retain an idle helper that could block the next host lease.

Seven new shared recovery cases and five VoiceRelay adapter cases pass alongside
the prior 73 cases (85 feature-focused cases). They include actual SQLite rollback
after hashing, database-writer contention during API registration, a queue retaining
chunk 1 while rejecting/retrying later work, explicit Stop with a surviving API,
captured order/pause/dictionary restoration, immutable completed recordings, linked
metadata rejection, and interrupted Libro rendering resumed with preparation
deliberately disabled. A multi-document coordinated batch also passes. All inputs,
libraries, speech workers and tones in these cases are synthetic and isolated.

Both apps still inject no coordinator by default. Activation remains gated on
app-owned lifecycle/setup/preview/OCR admission, notification wakeups, waiting-status
presentation, explicit file-access/Resume UI and journal retention/repair policies.
Do not enable partial scheduling or claim GUI, protected-file, listening or server
acceptance from these adapter tests. The native `coordinator` check now also
exercises `NativeSpeechSession.generateForCheckpoint`, verifies no early cursor
advance, independently reads back Float32 WAV and commits its deferred receipt.
Reproduction remains in [Development](DEVELOPMENT.md#additional-model-checks).

Final full fixtures pass in
`.local/validation/full-53916B16-AC23-4AF0-8178-6BE2996ED767/`, including
360 VoiceRelay core and 183 app cases. The initial full run
`full-A53279C6-C16C-4E65-B0F4-9071D5CA80E2` is retained: its initialization-transfer
test used a loader-entry flag before residency acknowledgement. The corrected
barrier waits for the actual helper lease event; the focused regression and full
rerun pass. A mismatched recovery plan is also rejected before creating job data.

Fresh ad-hoc Debug/Release workspace builds and all four bundle audits pass in
`.build/VoiceServerPersistenceGate-21FDC1FB-CBA9-4BD7-AEDD-6B7F114B1E66/Build/Products/`.
The installed-assets, network-denied `coordinator` checks pass for Kokoro, Soprano,
Qwen3, Chatterbox and Orpheus, including deferred session generation, exact Float32
WAV readback before checkpoint commit, same-helper reuse and owned helper reap.
Each native receipt matches its audited Release worker fingerprint. Evidence and
source/harness fingerprints are indexed by
`.local/validation/voiceserver-persistence-20261102/gate-result.json`.
Earlier candidate bundles remain intact. These checks do not establish native
active-cancel latency, HTTP streaming, listening, GUI or protected-file acceptance;
no archive, commit or push was performed.

### Host inference and app ownership bindings — November 2, 2026

`SpeechHostAdmission` gives Vision OCR, on-device image/title generation and explicit
local recognition a ranked ticket before acquiring existing current/legacy kernel
exclusion. Its rank comes from the app owner, so a legacy interactive call cannot
outrank API demand. Registration and kernel acquisition share the existing final
rank gate. The host ticket uses a distinct instance from its app's speech helper;
an idle resident helper therefore unloads before platform work acquires exclusion.
Cancellation withdraws queued demand. An already-started platform call is
cooperative: it retains its ticket and locks through completion/join, including
Quit. Stopping the owner refuses new grants and joins outstanding leases; it never
pretends that removing a ticket has stopped platform work. This is not evidence
of native Vision/Foundation Models cancellation latency or OS-managed residency.

Each opt-in speech coordinator now owns that host admission context. Libro's batch
extraction and document preview, and VoiceRelay's article preparation/preview,
explicitly propagate it across detached task boundaries. Existing child task groups
inherit it. Normal calls without the context retain the two-rank lease contract.
Unrelated explicit lock paths are rejected inside a coordinated context.

Setup checks use an initialize-only coordinated unit: registering a session is not
proof of model readiness. The unit waits for actual initialization and generates
no speech; failure/cancellation still closes only that job. Pronunciation previews
and manual review regeneration reuse the captured coordinator rather than creating
another model host. The explicit local recognition check uses its host context.
VoiceRelay's app model can receive one coordinator for backend/setup/preview/source
work and closes it on Quit after joining app tasks. Libro has the equivalent private
constructor binding and joined Quit path. Default constructors still supply nil;
there is no user-facing activation switch or listener in this gate.

Ten new synthetic cases cover host ordering/cancellation, retained platform leases
through Quit, lock-path mismatch, initialize-only readiness/no generation, helper
exclusion, captured preview ownership, detached article context and app Quit.
Their inputs, stores and workers are isolated; real OCR, recognition and Foundation
Models are not run. The earlier focused regression set remains part of validation.
Model install/repair/deletion maintenance, substantial CPU loops and hashes,
notification wakeups, waiting presentation and explicit recovery/file-access UI
and retention/repair policy still gate activation. No partial scheduling is enabled.

All ten new cases pass, alongside the earlier 85 feature cases (95 total).
Final full fixtures pass in
`.local/validation/full-56FED339-53F8-4236-88DF-6CC22B53511E/`, including 361
VoiceRelay core and 184 app tests. The initial focused VoiceRelay compile failure
(`quick-16DE7F53-0AC6-4F59-A72A-E4EB81070B50`) is retained: the new parameter
needed an explicit NarrationCore import. The corrected focused rerun and full gate
pass. No test assertion was removed to resolve it.

Fresh ad-hoc Debug/Release builds and all four bundle audits pass in
`.build/VoiceServerHostAdmissionGate-352F839A-9898-4E2E-8B88-8C55F01048A6/Build/Products/`.
All five installed models pass the network-denied native coordinator check,
including actual initialize-only readiness, deferred checkpoint readback before
commit, warm reuse and owned helper reap. Soprano uses Libro's helper; the other
four use VoiceRelay's helper. The source/harness fingerprints, audited-worker
comparisons and gate receipts are indexed by
`.local/validation/voiceserver-host-admission-20261102/gate-result.json`.
No Vision/Foundation Models/recognition handoff, GUI, listening or server acceptance
follows from these speech-helper checks. Those platform/manual checks remain
operator-owned. Earlier candidates remain intact; no archive, commit or push was
performed.

### Maintenance, CPU admission, wakeups and streaming codecs — November 3, 2026

This continuation began November 2 and completed its final automated gate November 3.

The still-opt-in owner now provides maintenance around installation and deletion:
refuse new jobs, cancel accepted API work without replay, suspend background epochs,
park their CPU operations, reap the owned helper, join active platform leases, then
perform the mutation. Success or failure reopens eligible background work; Quit
cancels and joins maintenance without reopening. Exclusive model-storage leases
still protect deletion across apps. This does not authorize remote helper control.

CPU-only tickets rank preparation/finalization without loading weights. Operations
own separate utility queues; a suspended background encoder cannot occupy an
HTTP/UI executor or block an accepted API encoder. Cooperative checkpoints cover
bounded PCM/codec loops, journal IO, source/output integrity proofs, validation and
publication. Libro owns preflight before its first admission wait, rejects concurrent
batches and joins Stop. Narration planning checks between blocks/emitted pieces;
existing platform and analysis subcalls still finish cooperatively. Optional review
retention and all preparation paths are not yet covered, so default activation
remains premature. Final published recordings stay published even if their recovery
receipt cannot finish; no missing receipt grants permission to overwrite/replay.

Retain private probe/coordinated wire version 6. It rejects version 5 before model
initialization: a v5 helper would not understand the same-instance CPU ticket
exception and could wait behind its own finalizer. Normal serving IPC stays v3.
MacOS notification wakeups contain only a hashed workspace namespace and no payload;
kernel-locked demand metadata remains authoritative. Periodic checks cover missed,
coalesced or unavailable notifications. Waiting projections track source sequence
and run identity, preserve counters/error state and respect manual Pause/Stop/Skip.

The shared response encoder owns one resampler and one native LAME state for the
response. Sequential MP3 output omits rewritable Xing metadata, never seeks and
flushes once; complete-file exports keep their existing metadata path. PCM is mono
signed 16-bit little-endian at 24 kHz. Native sample-rate conversion retains state
across frames. No gain, normalization or limiter is applied. PCM fails on samples
outside its representable range instead of clipping them; MP3 retains float input.
Input frames are bounded at 16,384 samples and must be nonempty/finite. The current
64 MiB output bound is provisional pending HTTP capacity/deadline policy. Sink errors,
disconnect/abort or limits terminate state without flushing or replaying audio.
Both app projects explicitly embed/sign the already pinned LAME library and shared
notices. The dependency revision is unchanged. A subsequent decoded-speech
comparison exposed LAME's CBR preset multiplier: initialization changed explicit
unity scale to 0.95 at 128 kbps. The pinned preparation now removes that multiplier
with `lame-preserve-input-scale.patch`, preserves caller scale without compensating
gain and requires actual unity scale after initialization. The pre-patch test
fails at all four tested sample rates. Completed recordings are untouched.

Focused fixtures pass maintenance, CPU/codec pause and Quit joins, same-rank
speech/finalizer overlap, API FIFO, older-helper rejection, notification loss,
stale waiting events, preflight Stop/exclusivity and interrupted recovery proofs.
The MP3 fixture independently decodes speech before flush and requires byte-identical
output across arbitrary frame segmentation; PCM checks exact little-endian bytes
and stateful resampling equality. These are not HTTP latency or listening acceptance.

The initial CPU integration exposed a real validation-ordering bug: a revoked WAV
waited behind API demand before checking its receipt. The retained process samples
localize it; a typed interruption now survives codec wrappers and aborts stale
validation before it waits/hashes. The corrected targeted case and all checkpoint
tests pass. The post-publication receipt now cancels and joins on Stop even while
API demand remains active; it preserves the published file and rejects replay at
binding validation if its completion proof is absent. A later restricted batch run could not access macOS file coordination;
the same case passed with that system access. Initial compiler failures (explicit
maintenance closure typing and a required test `try`) and the codec fixture's partial-
prefix EOF handling are retained, with corrected reruns.

Current evidence is collected under
`.local/validation/voiceserver-maintenance-20261102/`,
`.local/validation/voiceserver-cpu-20261102/`,
`.local/validation/voiceserver-wakeups-20261102/` and
`.local/validation/voiceserver-codecs-20261102/`.
Thirty-four new cases pass alongside the earlier 95 feature cases: 129 total,
119 shared and 10 VoiceRelay. Final full fixtures pass in
`.local/validation/full-27B55398-A19F-4342-AE52-DE83CBDDD07B/`, including 363
VoiceRelay core and 185 app tests. Fresh ad-hoc Debug/Release products, rebuilt
incrementally for the final fixes, pass all four bundle audits in
`.build/VoiceServerCodecGate-999D964E-DD61-40BE-B28F-9B4222BE5CB3/Build/Products/`.
The final audits initialize the packaged codec and verify unity scale as well as
architecture, signatures, symbols and notices.

All five installed models pass offline initialize-only readiness, exact deferred
checkpoint readback, warm reuse, sequential MP3/PCM export and owned reap using the
audited Release worker/codec fingerprints. Independent readback passes: four native
24 kHz model MP3 comparisons have correlation above 0.9996 and RMS ratios about
0.999–1.002; their raw PCM is within one quantization step. The Soprano 32 kHz
source is independently decoded and its converted stream rate/frame count verified.
No source audio is changed by these measurements. Final receipts, source/harness
fingerprints and decoded results are indexed in
`.local/validation/voiceserver-continuation-20261102/gate-result.json`, with synthetic
WAV/MP3 pairs linked by `listening.md`. The folder retains its November 2 start date.
These remain unreleased engineering changes under the current 0.1.0 milestone;
the completed VoiceServer activation will warrant a deliberate minor milestone.
The MP3 correction and staged work are recorded under Unreleased in CHANGELOG.md.
HTTP, Keychain, Tailscale, service Settings and default app activation are unwired.
Explicit recovery/file-access UI and retention/repair remain required. Review
listening through the single [operator checklist](OPERATOR_VALIDATION.md#voiceserver-staged-acceptance)
before accepting continuous playback quality. The operator subsequently reported
“Audio is all good” on November 3 for the linked offline bounded-unit WAV/MP3 pairs.
That acceptance does not cover raw incremental Qwen, long-duration streaming or
HTTP/client behavior; the initial model capability restrictions remain in place.
No app launch, archive, commit or push is part of this slice.

### Document and review preparation — November 3, 2026

The next opt-in slice adds a Core CPU checkpoint and an optional async-reader CPU
executor. Captured app tasks carry it across detached boundaries. Document snapshot
reads, text/Markdown/RTF parsing, EPUB chapter extraction, per-page PDFKit/render/
geometry work, progressive preview planning, article title/image projection and
optional review PCM/hash/diagnostics run as admitted synchronous units. PDFKit
objects are exclusively owned and used sequentially. Actual Vision/Foundation
Models/recognition and native speech bridges stay outside these CPU units, avoiding
nested admission or executor deadlocks. No CPU TTS backend is introduced.

OCR/image budgets measure active admitted work. Optional title-generation timeout
starts only after its native inference acquisition; injected generators retain
bounded timeout tests. A long admission wait cannot exhaust these analysis limits.
Already-submitted platform work still yields cooperatively. CPU-only metadata work
needs no valid speech model or runtime folder and cannot load a helper. Stop and
interruption also apply while maintenance refuses new CPU tickets.

Optional review writes serialize and are cancelled/joined before close or session
replacement. Interrupted writes remove only their newly owned PCM; cancelled repair
cleanup is separately joined even after the original task is cancelled. Original
reviews, authored text and published audio remain intact. Pending article removal
cancels/joins its real preparation task. Snapshot planning/hash/encoding precedes
the SQLite writer transaction, whose final revalidation compares exact saved bytes
and captured chunk limits. Cancellation and COMMIT share one short control lock.

Synthetic preparation/review/source regressions pass in focused runs. The retained
folder `.local/validation/voiceserver-preparation-20261103/` also keeps failed fixture
attempts and their fixes: cancelled repair cleanup initially inherited cancellation;
a model-invalid fixture initially used a valid Kokoro voice choice; and a throwing
test expression needed an explicit intermediate value for the Testing macro.
The full fixture gate passes at
`.local/validation/full-BFBB32B9-35EA-4501-8830-CEF8083B5F63/`, including 366
VoiceRelay Core and 185 app cases; the continuation's `fixture-result.json`
retains per-suite totals and intentional native/private skips. Both ad-hoc
Debug/Release workspace builds and all four bundle audits pass for
`.build/VoiceServerPreparationGate-60D72728-9292-41F5-BE47-CA4233F31DBC/Build/Products/`.
The continuation's `gate-result.json` retains source/bundle fingerprints. The
accepted codec/listening candidate is preserved. No app launch, new model run,
archive, commit or push was performed. The single operator checklist's VS01a owns
preparation/review GUI compatibility; synthetic disposable inputs are provided in
the continuation folder. Real document-provider,
preview/review GUI and listening acceptance remain separate. Default constructors
still supply nil; remaining intake/cover and queue-metadata paths, recovery UI/
file-access/retention, HTTP and service setup are not claimed complete.

### Deferred narration models and bounded CPU token counting — November 3, 2026

The normal-serving pipeline now prepares storage without starting a helper or
loading speech weights. Qwen, Chatterbox and Orpheus load only their existing
pinned local tokenizer, Soprano uses its existing scalar budget, and Kokoro loads
Misaki plus its pinned phoneme vocabulary. Kokoro's neural pronunciation fallback
remains under inference admission; it unloads before releasing admission at a
paused checkpoint, a boundary with pending interactive demand, and completion.
CPU-only tokenizers retain their helper across preparation windows without
occupying inference admission. The first generation promotes that same helper
after dropping frontend resources. Large speech models still reap at the existing
completed-utterance boundaries. Setup validation still loads the complete model.

First-use Qwen conversion reuses the pinned SDK's existing JSON converter through
an access-only compatibility patch; it never constructs a speech model. Generated
sidecars stay in the private overlay and pass existing size/digest validation.
A Foundation-only dependency check compiles that exact converter against
synthetic vocab/merge/special-token expectations without MLX or weight files.

Libro General adds Maximum CPU workers (Automatic uses available cores, capped at
32). The captured per-batch maximum controls joined concurrent token-counting tasks
inside the existing helper, never extra inference processes. Non-monotonic token
counts, original scan stops, errors beyond a speculative stop, linguistic boundary
scoring and exact source coverage remain covered against the frozen serial oracle.
Cancellation joins work before cleanup. Recovery manifests capture the operational
limit separately from acoustic identity; older manifests restore a serial limit.

Normal SpeechIPC advances from version 3 to 4, with explicit frontend classification,
release acknowledgement and promotion. Older or unacknowledged helpers fail closed.
The opt-in coordinated probe remains wire version 6 and still initializes full
models explicitly. Its cold frontend-only residency state is remaining activation
work, along with the already-recorded HTTP, credentials, Settings and lifecycle
gates. No CPU speech backend or additional model worker is introduced.

The full fixture gate passes (169 ProcessingPipeline, 151 NarrationCore, 87
document-processing, 43 Libro Core, 366 VoiceRelay Core and 185 app cases; existing
native/private skips retained). All five synthetic lifecycle traces promote the
same helper PID and join its reap. Debug/Release workspace builds and all four
bundle audits pass in the reused build cache. Evidence is indexed in
`.local/validation/cpu-preparation-20261103/gate-result.json`; failed sandbox,
progress-label and stale-toolchain attempts are retained separately.
Three repeated synthetic 200-window BPE runs measure median 1.412 s for the
frozen original and 0.734 s with 12 workers, about 1.9×. This is tokenizer-fixture
evidence, not an actual-book/model throughput claim. The operator
owns [L21](OPERATOR_VALIDATION.md#libro), using their normally signed Xcode build,
installed models and disposable inputs. No app launch, voice-model inference,
private-book processing, archive, commit or push was performed for this slice.

### Intake, artwork and queue metadata — November 3, 2026

The next authorized continuation adds admitted CPU work to Libro input discovery,
automatic/manual cover processing, captured-cover reads and unused-cover cleanup.
Checkpoints run between filesystem entries and image operations, including PDF
cover rendering boundaries. Native File Provider/PDF/ImageIO calls already in
progress finish cooperatively. Cancellation retains existing cover assets.

VoiceRelay queued-title preparation and queue chunk-count planning now use the
same optional CPU executor. No database writer is retained during title admission
or preparation. Its final transaction revalidates the captured row, exact snapshot
bytes and episode record. Planning rechecks successful counts and failed validation
against the saved state after actor reentry; changed/removed rows cannot be started
or failed using stale results. Normal constructors remain nil.
The full gate also exposed two setup fixtures whose absent fake model inventory
prevented their injected verification callbacks from running. They now explicitly
report synthetic installed assets and assert verification/retry/cancellation calls.
The pending-remove/re-add fixture also joins the separate metadata-removal task
and asserts Add eligibility before requesting a fresh token; waiting for its
cancelled fetch alone did not establish that the removal had finished.

All 49 focused cases, the full fixture gate, both Debug/Release workspace builds
and all four bundle audits pass. Evidence is indexed in
`.local/validation/voiceserver-intake-metadata-20261103/gate-result.json`;
the final full/build gates and operator-owned
[VS01b](OPERATOR_VALIDATION.md#voiceserver-staged-acceptance) are tracked in
[current status](IMPLEMENTATION_STATUS.md). No GUI app or real voice model was run;
archives, commits and pushes were unrequested. Remaining legacy metadata reads,
cold frontend residency in the coordinated path, recovery/file-access UI,
retention/repair and HTTP/service setup remain activation gates.

## VS01 - Work ownership and admission

- [x] Implement shared three-rank demand, ticket liveness, final admission/commit
  fences and per-attempt epoch primitives, with isolated cross-process tests.
- [ ] Integrate immutable per-job settings and each app's owned coordinator;
  an actor in one app is not a cross-process scheduler.
- [ ] Make the coordinator own speech admission and the model host. Leave the
  library PipelineLease and durable article state with the podcast pipeline;
  API work neither acquires that library lease nor creates synthetic episodes.
- [ ] Separate model lifetime from job lifetime: one compatible resident weight
  set, one active generation task, and per-job identity/settings/spool/state.
- [ ] Schedule bounded preparation/generation units, not entire articles. Inactive
  jobs retain plans/checkpoints, not separate model copies or suspended GPU work.
- [ ] Key model reuse by loaded asset revision, runtime/device and weight format;
  apply captured voice/speed/language/reference/delivery settings per job. Reset
  request-specific conditioning even when the underlying weights are reusable.
- [ ] Gate every new background preparation, inference and substantial CPU unit;
  an accepted live request prevents new background units until live work drains.
- [ ] Add cooperative pause points to existing CPU audio loops where needed.
  Keep encoder state in memory during a pause; after a crash, re-encode from
  committed PCM. Do not introduce durable serialization of encoder internals.
  Short atomic commits and already-issued network operations may settle safely.
- [ ] Authenticate, validate the complete bounded request, check capacity and
  capture settings before granting priority. Partial uploads, invalid requests
  and model/status queries never preempt podcast work.
- [ ] Recheck admission after asynchronous lease waits so a stale podcast grant
  cannot launch inference after live work has won scheduling.
- [ ] Return explicit overload/unavailable errors rather than queue indefinitely.
  Bound pending jobs, aggregate input bytes, output size, connection count and
  queue/generation/write deadlines; keep policy values centralized and tested.
- [ ] Bound waiting behind other live requests, including complete-file work.
  Return 429 with Retry-After on capacity/wait-budget rejection; report model or
  worker unavailability separately. No client can reserve priority indefinitely.
- [ ] Keep HTTP/UI executors free of synchronous speech bridges and process waits.

### Cross-process coordination and compatibility

- [ ] Extend the existing per-user lease/ticket design with three ranked demand
  classes and an observable higher-priority request. Keep kernel exclusion and
  owner/permission validation authoritative; notifications only wake observers.
  Use a bounded fallback recheck so missed/coalesced events cannot lose a handoff.
- [ ] Publish API demand only after authentication, validation and capacity
  acceptance. Notify the lower owner without holding the admission gate while
  awaiting cancellation. The owner revokes its job epoch and cancels its own work.
- [ ] Release compute admission only after job/producer/GPU quiescence or owned
  helper reap. Recheck the highest live rank atomically before every new grant.
  No lock stealing, remote process killing or assumed GPU completion.
- [ ] Coordinate model residency as well as GPU admission. An idle lower-priority
  helper must acknowledge unload before a cross-app replacement loads weights.
  In-app compatible handoffs retain their one model as already specified.
- [ ] Tie residency/liveness protection to the actual helper lifetime or an
  equivalent verified handshake. App death and ticket removal do not prove an
  orphan helper stopped computing. Parent-pipe EOF cancels owned work; replacement
  must wait for protected quiescence/exit rather than trusting a stale PID.
- [ ] Withdraw API tickets on disconnect, failure, deadline, disable or Quit.
  Keep eligible Libro demand ahead of podcasts while API runs; after API drains,
  reconsider current eligibility rather than blindly resuming the prior owner.
- [ ] Manual Pause, Stop, Skip/removal, maintenance and Quit remain independent
  constraints. Suspended work cannot reclaim admission until all constraints clear.
  A manually paused Libro batch must not unnecessarily block eligible podcasts.
- [ ] Classify setup checks, live previews and shared OCR/image-description work
  explicitly. No default interactive call may bypass the API rank. Noninterruptible
  platform work must stop new submissions and expose its bounded-handoff limitation.
- [ ] Version the coordination protocol and retain existing exclusion locks.
  Older running apps may not honor preemption; detect/report that limitation and
  require compatible builds for the new guarantee. Never bypass their held locks.
  Test new/new and mixed-version behavior without claiming old apps can be forced
  to suspend safely.

## VS02 - Fast streaming preemption with resident-model reuse

- [ ] Introduce a typed priority-suspension outcome, distinct from user Stop,
  ordinary cancellation, backend failure, model repair and application Quit.
- [ ] On accepted streaming work, atomically revoke the active lower-priority epoch,
  fence checkpoint commits and issue job cancellation without waiting for the
  completed chunk, pending hashes, full PCM validation or diagnostics.
- [ ] Keep a bounded control reader responsive independently of generation.
  Add versioned cancel-job and quiescent/ready acknowledgements correlated by
  worker identity, job identity and epoch; stale controls cannot cancel a new job.
- [ ] Separate recoverable job cancellation from supervisor-terminal failure and
  process shutdown. A compatible same-app handoff must not call the old fatal
  cancel/close path; cross-app residency transfer may unload/reap as specified above.
- [ ] Propagate cancellation into native generation/stream producer tasks. Audit
  each adapter and add reproducible pinned patches for missing cancellation checks
  where necessary, without changing model math or introducing another backend.
- [ ] Join the cancelled job and all generation subtasks, drain its submitted
  GPU work, and release its temporary tensors before acknowledging quiescence.
  Never run two inference jobs just because both reference the same weight set.
- [ ] Reset per-request KV/attention caches, streaming codec/decoder state,
  completion flags, partial PCM, conditioning and RNG/seed context as appropriate.
  Preserve verified model weights/tokenizers and compatible immutable voice data;
  do not restore a discarded job's mutable state or leak it into another request.
- [ ] For a same-app handoff, start the live job in the same helper after quiescence
  using a new job context and existing weights. Compatible idle helpers in the
  requesting app remain reusable subject to cross-app residency exclusion.
- [ ] If compatible model initialization in the owning app is underway, transfer active
  demand to that initialization instead of starting a duplicate load. Do not
  continue background speech after loading merely because it began initialization.
- [ ] If the required model identity differs, release the old weight set before
  loading its replacement; do not retain one copy per suspended job or API client.
- [ ] Use a bounded cancellation-acknowledgement deadline with per-adapter
  evidence before activation; a stuck or unsafe-to-reset worker falls back to
  termination and reap. The earlier proposed immediate-termination/100 ms policy
  is superseded for normal handoff; no production timeout is fixed by this plan.
- [ ] When recovery or cross-app handoff requires process teardown, coalesce
  close/escalation and wait for owned reap before replacement. Record the reason;
  never treat OS page caching as preserved model residency or promise instant GPU
  interruption. If exit stalls, remain unavailable rather than overlap workers.
- [ ] Retain inference admission through cancellation/drain or fallback reap.
  Retain ModelStorageLease for as long as loaded weights/assets remain in use;
  release inference between jobs according to API > Libro > Podcasts.
- [ ] Retain compatible weights for the entire active live request and immediately
  queued live burst, including gaps between semantic units. Suppress the existing
  per-utterance large-model teardown within that explicit active-demand scope.
  Preserve footprint/cache limits, eviction and deletion exclusion. Return to
  normal idle unloading when demand ends; optional idle prewarming is deferred.
- [ ] Keep diagnostic draining and safe cleanup off the live-start critical path.
  Disconnection still completes cancellation/reset or fallback teardown, then
  serves the next live job or resumes eligible podcast work.
- [ ] Each app may terminate only its own helper when cancellation/reset fails
  or its cross-app residency handoff requires teardown. Never signal another
  application, match processes by name, freeze workers
  with SIGSTOP or assume cancellation can interrupt an executing Metal kernel.

## VS03 - Rollback and durable recovery

- [x] Add shared attempt/epoch commit fencing and verified-index cursor primitives.
- [ ] Integrate verified-chunk descriptors, integrity checks, resume
  cursor and suspension reasons in the native packages. Adapt persistence to
  VoiceRelay's existing store and Libro's owned job workspace; do not move either
  app's full workflow/database into a new common scheduler.
- [ ] Add explicit Libro prepared-plan/chunk recovery independent of optional
  narration-review retention. Preserve batch/document order, source/acoustic
  identity, settings, destination/replacement consent and completed recordings.
  Any journal is private, versioned and ownership-checked; shared coordination
  files contain no document text, private paths, API keys or audio.
- [ ] Keep Libro's enclosing render/writer alive across automatic suspension
  where safe. Catch the typed yield before generic cancellation unwinds through
  writer.abort or produces a cancelled batch summary. After restart, reconstruct
  unfinished output from verified PCM, not arbitrary codec state.
- [ ] Distinguish manual pause from automatic priority suspension in both apps.
  Show "Waiting for VoiceServer" without resetting progress, incrementing attempts,
  reporting failure/completion or requiring Resume. Auto-resume only eligible jobs.

- [ ] Define the safe point as the last fully validated, durably committed work,
  not a generated file, progress callback or uncommitted validation result.
- [ ] Linearize epoch revocation against checkpoint commits. A commit already
  completed before revocation survives; a stale attempt cannot commit afterward.
- [ ] Track the completed-chunk set and contiguous resume cursor; preserve other
  compatible verified checkpoints without deleting good work or shifting indices.
- [ ] Ignore stale success, failure, progress and PCM events after revocation.
  A late result must not advance the cursor, overwrite state or mark a job failed.
- [ ] Discard only uncommitted attempt-owned PCM/preparation/encoded scratch.
  Invalidate its references immediately; unlink only after its writers are joined.
  Never roll back by restoring an entire database or replacing current metadata.
- [ ] Cancel/fence pending validation and lookahead work. It must not delay
  issuing job cancellation or produce a late checkpoint after the epoch changes.
- [ ] Preserve captured model/voice, pronunciation identity, text/source maps,
  prepared chunks, structural pauses, transcript inputs and checkpoint hashes.
- [ ] Restart the first unfinished unit after live work drains using a fresh
  job context and the same compatible resident model when safe. Do not reuse an
  old cancelled job/bridge, stale mutable state or a failed model instance.
- [ ] Represent suspension as transient "Waiting for VoiceServer" progress,
  not a manual-Retry row, permanent failure or extra attempt.
- [ ] Keep the user Stop policy intact. Stop/removal/reset while suspended must
  prevent automatic resurrection; Quit retains recoverable podcast checkpoints.
- [ ] Recover after crashes at revocation, reset, fallback reap and resume boundaries.
  Follow current automation consent; never persist/replay live HTTP requests.
- [ ] Do not promise identical regenerated speech for stochastic models. Committed
  PCM remains byte-identical; discarded work can be regenerated differently.

## VS04 - First playable audio

- [ ] Audit the pinned Swift adapters for actual incremental audio capability
  with the selected native voice, language, instructions and reference handling.
  A method named generateStream is not proof of early playable output.
- [ ] Prepare the first complete semantically safe speech unit and generate it
  before preparing the entire prompt. Bound lookahead; never truncate text.
- [ ] Use the existing semantic/pronunciation pipeline. Any smaller first-unit
  packing policy is live-streaming-only and versioned; do not resegment podcasts
  or bypass Kokoro's authenticated prepared-phoneme path.
- [ ] Expose incremental model audio through bounded/versioned helper IPC where
  supported. Tag frames by request, epoch and sequence; transfer owned CPU PCM,
  never MLX arrays or unbounded tensors/control records.
- [ ] Own and join upstream producer tasks explicitly; ending an AsyncThrowingStream
  iterator is not proof its producer or GPU work has stopped. Use bounded credits
  through generation, IPC, encoding and HTTP rather than unbounded stream buffers.
- [ ] Keep cancellation/control messages responsive even when the audio consumer
  stalls. Release shared inference admission only at a verified quiescent boundary,
  never while a detached producer can still submit GPU work.
- [ ] Validate finite PCM, rate/channels, sequence and coverage incrementally.
  Bound producer buffering and cancellation latency all the way into the helper.
- [ ] For models without usable incremental output, stream successive bounded
  prepared utterances and disclose the latency limitation. No Python fallback,
  silent model substitution or whole-request buffering presented as early audio.
- [ ] Keep raw incremental Qwen disabled until the native decoder-boundary parity
  gate and continuity/listening checks pass. Start with complete bounded Qwen
  utterances; do not promote the fast callback on lifecycle/coverage results alone.
- [ ] Gate Orpheus streaming as unavailable before admission under the initial
  capability policy. Revisit only with native first-audio and sustained-throughput
  evidence; retain explicit complete-file operation and actionable model guidance.
- [ ] Encode/write the first decodable audio promptly. HTTP headers, ID3 tags,
  empty chunks and intentional leading silence do not count as first speech.
- [ ] Add non-seeking MP3 output using one encoder state per response, preserving
  original levels. Do not concatenate independent MP3 files as a fake stream.
- [ ] Embed/sign the already-pinned native LAME library in VoiceRelay, including
  applicable notices and packaged-bundle checks. Reuse the existing native codec;
  no FFmpeg, encoder subprocess or new language runtime.
- [ ] Retain resampler/encoder state across audio frames; verify whether upstream
  chunks are incremental or cumulative and remove overlap only when the adapter
  contract requires it. Validate audible continuity, not only valid containers.
- [ ] Support raw mono signed 16-bit little-endian 24 kHz PCM with native
  conversion; keep container sample rates explicit and WAV complete-file only.
- [ ] Preflight known input/configuration/model failures before sending headers.
  Midstream failure terminates the audio response; never append JSON or replay it.
- [ ] Release inference ownership outside generation, especially while awaiting
  network writes. A slow client has a bounded timeout, not indefinite priority.

## VS05 - Shared selection and complete-file API

- [ ] Capture the existing SpeechSettings and pronunciation/reference selection
  at admission. Settings changes apply only to later requests.
- [ ] Advertise stable model alias `voicerelay` and voice alias `default`, resolving
  both to the captured GUI selection. Also accept the exact selected voice ID;
  omitted voice/speed use the selection. Reject other explicit mismatches.
  Document compatibility as a subset for clients with configurable model/voice,
  not a promise that clients hard-coded to OpenAI voice names will work.
- [ ] Report the selected voice through the voices endpoint; provide no duplicate
  model/voice picker in VoiceServer and no remotely controlled model management.
- [ ] Reject unsupported models/paths/reference inputs/generation fields. Do not
  silently ignore OpenAI options whose semantics are not implemented.
- [ ] Route complete-file requests through the same worker owner at live priority,
  using cooperative background yield rather than destructive preemption.
- [ ] Return complete MP3/WAV/PCM files with correct type, length and format.
  Cancel on disconnect; clean up private response workspaces on all exit paths.
- [ ] Default MP3/PCM requests to streaming even when `stream` is omitted.
  Accept `stream_format: "audio"`; explicitly reject SSE. Support the optional
  `stream: false` extension for complete files, with omitted/default WAV buffered;
  reject explicit streaming WAV until a compatible framing strategy is validated.
  Settings must always leave a valid default mode; do not silently ignore a mode.
- [ ] Keep API output out of podcast queues, episodes, feeds, transcripts, backups
  and retained narration-review stores, regardless of podcast review preferences.

## VS06 - HTTP and API credentials

- [ ] Declare SwiftNIO directly at the compatible resolved pin and expose only
  GET /v1/models, GET /v1/audio/voices and POST /v1/audio/speech.
- [ ] Require a Keychain-backed bearer key for every API route; use cryptographic
  random generation, constant-time validation and no prompt in background reads.
- [ ] Keep keys out of UserDefaults, URLs, logs, diagnostics, examples and backups.
  Return Cache-Control: no-store for API metadata and audio responses.
- [ ] Implement OpenAI-shaped sanitized errors, bounded HTTP parsing, content-type
  validation and header/body/idle deadlines before inference admission.
- [ ] Define rotation as revocation: reject new old-key requests, cancel queued
  old-key work and terminate active old-key responses; explain this in the action.
- [ ] Add no CORS allowance, arbitrary URL fetching, file serving, reference-path
  access, unauthenticated inference, external listening daemon or Python fallback.
- [ ] Make disconnect/error/deadline cleanup idempotent and release priority so
  background work can resume when no accepted live work remains.

## VS07 - Tailscale and private listeners

- [ ] First implement a Swift provider invoking the installed Tailscale CLI using
  Process, explicit executable/arguments, TAILSCALE_BE_CLI=1, bounded output and
  timeout: status --json --peers=false. Use recognized installation locations;
  no shell, privilege escalation, credentials in arguments or raw-output logging.
- [ ] Treat missing/permission-denied CLI status as unavailable. Add direct
  LocalAPI support only for verified accessible configurations if necessary;
  no private XPC entitlement assumptions, keychain scraping, cloud token,
  embedded node, Tailscale configuration changes or bundled runtime.
- [ ] Parse only connection state, self addresses and actual self MagicDNS name;
  do not fetch/store peers or fabricate a DNS name from the Mac's local hostname.
- [ ] Handle App Store, standalone and CLI installations, permission failures,
  absent/locked credentials, disconnected state, missing fields and MagicDNS off.
- [ ] Bind loopback and explicitly selected Tailscale addresses only. An advanced
  other-VPN mode may select an existing local interface address, never a wildcard.
  First enablement requires explicit exposure choice and a valid API key.
- [ ] Reconcile listeners on interface changes, sleep/wake and Tailscale reconnect.
  Close removed-interface connections; never silently expose a replacement LAN IP.
- [ ] Build URLs with URLComponents, correct IPv6 brackets, explicit port and
  actual MagicDNS availability. Distinguish base URL /v1 from /v1/audio/speech.
- [ ] Keep listener-running, model-ready and Tailscale-connected states distinct.
  Do not claim cross-device reachability or HTTPS from a local status response.

## VS08 - Settings and application lifecycle

- [ ] Add the VoiceServer Settings pane using Publishing's grouped native form,
  shared typography/help and accessible navigation at 80%, 100% and 200% sizing.
- [ ] Provide enable/start/stop, port/access mode, response-mode options, read-only
  selected-model/voice summary and a link to existing Voice Model settings.
- [ ] Show selectable API base URL with Copy, Tailscale/MagicDNS status, key status,
  generate/copy/rotate actions, active/queued live work and suspended podcast state.
- [ ] Default server enablement off. Persist non-secret configuration only; an
  enabled service may restart with the app when credentials/listener setup permit.
  Listening and model readiness are separate: return an authenticated actionable
  503 for missing/unavailable speech assets without disabling URL/status access.
- [ ] Keep service ownership in the running app. Closing Settings/windows does not
  stop it; Quit cancels and joins live work and preserves podcast checkpoints.
- [ ] Integrate setup validation, pronunciation previews, model changes/deletion,
  library maintenance and existing busy flags with the single worker owner. No
  background check or preview may launch a competing inference helper.
- [ ] Integrate Libro's shared coordinator and status projection as part of this
  feature. Manual pause remains separately visible; automatic API suspension
  must not trigger batch-completion notifications or consume queued jobs.
- [ ] Coordinate maintenance by refusing new requests and quiescing owned work;
  preserve explicit model-download/repair consent and exclusive storage deletion.
- [ ] Do not silently prevent system sleep. Restore listeners safely on wake;
  disconnected API requests are not replayed and podcasts follow existing consent.
- [ ] Show privacy-safe errors without request text, API keys, reference paths or
  upstream stderr. Disable retained review artifacts for every API request.
- [ ] Never persist raw worker stderr tails from a model host serving API text,
  including when it later resumes podcast work or debug logging is enabled.
  Use controlled events/codes; request-scoped buffers must not leak across jobs.

## VS09 - Deterministic regression checklist

Add synthetic cases in the existing VoiceRelayCoreTests, VoiceRelayAppTests,
ProcessingPipelineTests, NarrationCoreTests and AudioOutputTests targets. Use
fake clocks, controlled barriers and isolated fixture workers, never real models.

- [ ] Streaming arrival during cancellable generation revokes the background job
  without completing its chunk; assert quiescence/reset precedes live inference.
- [ ] Assert same helper PID, one model initialization and the same weight-owner
  identity across podcast -> live A -> live B -> resumed podcast for compatible
  settings within the owning app; peak active generation and weight-set counts
  stay one. Cross-app cases assert unload-before-load instead of impossible
  cross-process array reuse.
- [ ] Verify request-local caches, decoder state, conditioning, completion flags
  and seeded contexts reset; changed voices/settings never inherit prior output.
- [ ] Deliver stale cancel/ready events and race cancellation with completion;
  controls cannot cancel a later epoch or cause concurrent inference.
- [ ] Hang cancellation or fail safe reset; assert bounded recovery fallback,
  one teardown, joined close callers and old-worker reap before new initialization.
- [ ] Test disconnect during reset/fallback, compatible initialization transfer,
  incompatible model swaps, memory-pressure eviction and explicit model deletion.
- [ ] Check cancellation while GPU work is still draining; no early ready event,
  inference-lease release or new generation occurs before quiescence.
- [ ] Test admission/revocation before launch, during model initialization and
  text preparation, during PCM transfer, validation and checkpoint transaction.
- [ ] Put a barrier on both sides of checkpoint commit: pre-revocation commits
  survive, post-revocation stale attempts cannot commit or advance progress.
- [ ] Use this trace: podcast chunk 1 committed; chunk 2 started then discarded;
  live A then B; podcast chunk 2 regenerated once and followed by chunk 3.
- [ ] Assert unchanged hashes for committed PCM; no missing/duplicate source,
  samples, gaps or transcript segments; deterministic fake output matches a
  control run. Do not assert real stochastic regeneration is byte-identical.
- [ ] Inject late events and cleanup from an old epoch after resume. They cannot
  overwrite the resumed job, append old PCM, delete new scratch or change status.
- [ ] Suspend/resume repeatedly, change live settings, remove/reset/Stop a
  suspended job and Quit/crash at each transition. Verify recovery and consent.
- [ ] Complete-file requests yield cooperatively; live requests remain FIFO;
  invalid/unauthenticated/overload/partial-body requests never preempt podcasts.
- [ ] For multi-unit inputs or genuinely incremental adapters, first playable audio
  precedes whole-request completion. Cover the single-indivisible-unit limitation
  explicitly; test incremental-event and bounded-utterance fixture capabilities.
- [ ] Test ordinary SDK-shaped requests without a stream flag, stable aliases,
  stream_format audio/SSE, buffered mode and unsupported format combinations.
  Verify API operation independently of Reading List, publishing and library state.
- [ ] Prove bounded producer/IPC/HTTP buffering under stalled writes, responsive
  cancellation and absence of GPU work after quiescence acknowledgement.
- [ ] Independently decode streaming MP3/PCM fixtures for format, order, no
  unintended gain and valid first audio; check complete-file content length/type.
- [ ] Exercise slow readers, producer overflow, body/output/deadline limits,
  client disconnect and midstream errors with bounded memory and released priority.
- [ ] Verify missing models never download, settings snapshots never mix voices,
  API jobs create no library/feed/review artifacts and cleanup stays request-owned.
- [ ] Cover key generation/storage/rotation, missing/locked Keychain, parser and
  routing errors, no-store headers and secret/text/path-free diagnostics.
- [ ] Cover Tailscale schema/install/state variants, stale discovery results,
  listener rebinding, IPv6 URLs, unavailable DNS and no wildcard fallback.
- [ ] Prove cross-process API > Libro > Podcasts admission and nested suspension:
  podcasts wait for Libro, Libro yields to API, and Libro resumes before podcasts.
  Exercise arrivals before grant, during generation and between chunks.
- [ ] Disconnect/disable/quit/crash the API owner while Libro waits; stop, skip,
  remove or manually pause Libro while API runs. Resume only currently eligible
  work; no stale ticket or late callback can block or resurrect a job.
- [ ] Test the active app crashing while its helper still drains GPU work,
  idle-helper residency handoff, simultaneous registration, lost wakeups,
  stale tickets, mixed-version apps and incompatible captured model selections.
  Kernel exclusion must survive requester/owner failure without orphan overlap.
- [ ] Preserve model-deletion exclusion, app Quit joins, Libro output replacement
  safeguards, both apps' queue progress and Settings sizing.

## VS10 - Latency evidence and release gates

- [ ] Instrument monotonic timestamps for accepted request, cancellation issued,
  quiescence acknowledged, request-state reset, optional fallback reap/model load,
  first valid PCM and first playable encoded write. Record reuse/fallback reason
  and load count, never prompts, samples, keys or client identity.
- [ ] Define server TTFA as acceptance to first playable audio write. Report
  header latency separately; client-observed first spoken sound includes transport,
  decoder/playback buffering and must not be inferred from server timestamps.
- [ ] Separately measure request receipt/validation, live-queue wait, cross-app
  lease wait, cancel/reset, loading/preparation and encoding. Include queue time
  in end-to-end results rather than starting the clock only when inference begins.
- [ ] Measure sustained generation relative to audio duration, inter-chunk gaps,
  client playback underruns and peak memory as well as TTFA. A quick first word
  followed by repeated long stalls does not meet the live-listening goal.
- [ ] Separate idle reuse, interrupted same-model warm reuse, incompatible-model
  swap and failed-cancellation/cold-reload cases. Record model/voice, input class
  and response format; do not combine them into one misleading latency result.
- [ ] Report same-app warm handoffs separately from Libro-to-VoiceRelay residency
  transfers. Measure the latter's unload/load cost before deciding whether a
  single shared model host is justified; no cross-app warm-reuse claim from fixtures.
- [ ] Use controlled cancellation fixtures to prove discarded background work is
  not completed and same-model handoff avoids reinitialization. Do not treat
  synthetic wall-clock timing as MLX performance or assert arbitrary kernels stop.
- [ ] With explicit operator approval, collect native first-audio/listening evidence
  and tune cancellation/recovery deadlines and streaming unit size against it.
  Do not promise a universal latency SLA or weaken global memory safety limits.
- [ ] Run changed-target tests first, one final full synthetic fixture gate, then
  Debug/Release workspace builds and all four bundle audits; skip archives unless
  distribution changes require them. Preserve evidence and operator app bundles.
- [ ] Update architecture, VoiceRelay guides/help, scoped AGENTS, dependency notices,
  implementation status and changelog only as corresponding work is implemented.
- [ ] Update Libro guidance and root/shared/app priority rules when implemented:
  API > Libro > Podcasts replaces the old Libro-first contract. Keep current
  behavior documentation accurate until then; this planned revision is explicit.
- [ ] Register VoiceServer manual acceptance in the single operator checklist:
  actual model latency/listening, client streaming, Tailscale variants/reachability,
  Keychain rotation, sleep/wake and suspended-podcast recovery. Keep results separate
  from automated checks; do not contact private/live services in fixture validation.
- [ ] Choose the next development milestone deliberately; retain commit-derived
  builds. Ship disabled by default; API stop/disable releases admission to the
  highest eligible remaining class, Libro before podcasts.

## Historical staged completion rule

The user authorized the successive bounded gates and integration. The following
describes the November 3 stage; the November 4 implementation above supersedes its
activation/API remaining-work statements. The synthetic
proof, native initialization/EOF/reuse/first-WAV paths, smaller first unit, measured
two-helper reload, corrected Qwen numerical parity and shared admission/attempt
foundations are implemented above. Raw Qwen stays probe-only pending continuity/
listening acceptance; Orpheus streaming stays unavailable. The three VoiceRelay
red assertions are resolved and full fixtures pass. Opt-in coordinator, render and
persistence adapters and opt-in app/host ownership bindings exist; default
activation, complete preparation/review admission, recovery UI/retention and broader
acceptance remain. Opt-in CPU/maintenance admission, waiting presentation and
streaming codec primitives are now implemented, with final evidence recorded above. Complete
VS01-VS03 safety behavior, integrate VS04-VS06 audio/API paths, and finish
VS07-VS08 discovery/UI. Add VS09 regressions alongside each stage, not afterward;
VS10 records final evidence. First-audio latency and sustained playback are core
requirements. A stage is complete only when its behavior and tests exist;
synthetic state-machine evidence checks no native or operator acceptance boxes.
