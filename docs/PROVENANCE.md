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

The October 27 model integration retains the exact Qwen3-TTS 1.7B 8-bit,
Chatterbox Turbo FP16 and Orpheus BF16 checkpoints used by the local comparison.
Complete primary/auxiliary hash inventories and two adapter patches are recorded
in [dependencies](DEPENDENCIES.md). Eighteen new bundled English samples were
generated through the shared production session/helper from the existing authored
sample phrase; the previous 29 audio resources are byte-preserved. No private
article, imported reference or model weights are included in those resources.
New Chatterbox samples use raw product PCM rather than the pinned SDK's inherited
peak normalization/fade; original benchmark artifacts keep their original bytes.

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
