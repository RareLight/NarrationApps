# Source provenance and licensing records

SwiftNarration's original extraction/audio/assets/IPC fixtures were moved from
Libro; semantic document and presentation foundations came from VoiceRelay.
App-specific GUI/workflow remains in each app directory. The current native
intake, pronunciation, preparation and audio implementations are maintained here
once, with synthetic shared regressions. Source-only migration baselines remain
private ignored evidence, not additional maintained implementations.

Project code is under the repository [AGPL-3.0 license](../LICENSE). Dependencies,
models/voices and pronunciation data retain their original terms. Exact pinned
sources, patches, resource hashes, codec provenance and notice collection are in
[DEPENDENCIES.md](DEPENDENCIES.md); original texts in `ThirdPartyNotices/` must not
be rewritten during documentation cleanup. App bundles include dependency notices;
model assets are explicitly acquired outside the bundle. Distribution review is
separate from local build feasibility.

The November 4 VoiceServer transport directly declares the already bundled
SwiftNIO 2.95.0 source pin, using NIOCore/NIOPosix/NIOHTTP1 and test-only
NIOEmbedded. Existing upstream NIO/HTTP-client/SSL notice texts remain unchanged.
The API renderer reuses the maintained native codec and assembly implementations;
no external TTS server, Python runtime or model weights are bundled.

The November 2 VoiceServer codec work reuses the pinned LAME 3.100 archive and
existing native build recipe. `lame-preserve-input-scale.patch` removes the
preset's bitrate-dependent input-scale multiplier after a regression demonstrated
explicit unity becoming 0.95 at four sample rates. The wrapper and bundle audits
require unity after initialization; no inverse gain, normalization or PCM limiter
is introduced. Existing copyright/license notices remain byte-preserved, and
completed audio is not rewritten. Public distribution review remains separate.

The October 27 model integration retains the exact Qwen3-TTS 1.7B 8-bit,
Chatterbox Turbo FP16 and Orpheus BF16 checkpoints used by the local comparison.
Complete primary/auxiliary hash inventories and two adapter patches are recorded
in [dependencies](DEPENDENCIES.md). Eighteen new bundled English samples were
generated through the shared production session/helper from the existing authored
sample phrase; the previous 29 audio resources are byte-preserved. No private
article, imported reference or model weights are included in those resources.
New Chatterbox samples use raw product PCM rather than the pinned SDK's inherited
peak normalization/fade; original benchmark artifacts keep their original bytes.

The November 1 VoiceServer feasibility work adds the recorded
`soprano-owned-producer.patch` at the same MLX Audio revision. It retains and joins
the internal token-generation task before decode or cancellation returns; it
changes no model math, weights, sampling or audio levels. Existing upstream
licenses/notices remain intact. The [checklist](VOICESERVER_IMPLEMENTATION_CHECKLIST.md)
separates opt-in native evidence from product integration and listening acceptance.
The following first-unit gate adds `qwen-owned-audio-callback.patch` at that same
pin: it exposes the existing incremental decoder synchronously on the owned
generation task, propagates throwing consumers and reports sample coverage. It
changes neither sampling/decoder math nor audio levels. The private live first-unit
policy preserves mappings and does not resegment existing app jobs or recordings.
The subsequent `qwen-streaming-overlap-bias.patch` corrects duplicated convolution
bias only in that new opt-in callback and adds a fixed-weight, model-free decoder
regression. Ordinary app decoder defaults, model weights, published recordings
and audio levels are preserved; the correction performs no gain processing.

The November 3 deferred-loading change adds `qwen-text-tokenizer-preparation.patch`
at the same MLX Audio revision. It exposes the existing local JSON converter
without changing its implementation, so the tokenizer can be prepared before
speech weights load. Its generated sidecar uses the existing pinned validation;
the real converter is compiled in isolation for synthetic dependency tests.

The optional native PDF word joiner adapts Readium Swift toolkit proposal #877 at
commit `3a50f066f0b050f2951c211b41cf69d8eab9be6a`. Its original BSD-3-Clause license,
copyright and adaptation record are retained in
[`swift-packages/ThirdPartyNotices/Readium/`](../swift-packages/ThirdPartyNotices/Readium/README.md)
and included by both apps' existing notice-packaging flow. This adds no Readium
package or binary dependency.

Optional private `.build/longform/accepted/` records preserve source/sample/helper hashes,
operator selection and final artifact checks. Historical public stage summaries
are indexed in [README.md](README.md); they are not current setup commands or
permission to expose private source documents, caches, credentials or audio.
