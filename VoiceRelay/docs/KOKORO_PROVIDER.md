# VoiceRelay native speech adapter

VoiceRelay uses the shared native engine through its private VoiceRelaySpeechWorker.
The GUI presents 18 English Kokoro voices; shared Soprano support does not add a
VoiceRelay model selector. New preferences use Heart at 1.0×; saved voice/speed and
admitted job settings remain intact.

NativeSpeechSetup performs explicit model/pronunciation installation and offline
Check Speech Setup. Build/startup/generation never implicitly download. British
voices require their pinned regional resources without a US fallback. The app's
managed root is `~/Library/Application Support/VoiceRelayPrototype/SpeechRuntime`;
existing validated native workspaces remain usable.

NativeMLXBackend adapts PreparedTTSBackend to the shared NativeSpeechSession. It
forwards captured dictionary settings, prepares the semantic projection once,
freezes final utterances and renders each prepared chunk once. There is no second
app-specific chunker or G2P pass. SingleWorkerSpeechPipeline retains a compatible
helper across articles, joins failures/cancellation and safely yields to Libro.

The accepted policy, memory guard, bounded IPC, structural gaps and acoustic identity
are documented in [shared architecture](../../docs/ARCHITECTURE.md).
Legacy character preparation survives for archived developer comparisons, not a
user mode. Shared mapped spoken forms now correct explicit kilograms, Celsius/
Fahrenheit quantities and 12-hour AM/PM times, with source preservation and preview
notices, including capital-A labels. Delivery A matched listening is accepted;
unreported app-preview checks remain separate, and contextual homographs remain
[follow-up work](../../docs/TEXT_NORMALIZATION_RESEARCH.md).

Native podcast audio is mono AAC-LC 64 kbps/24 kHz, with original levels/dynamics
and no normalization, gain, limiter or DRC. VoiceRelay's saved gap preference is a
structural minimum; explicit zero remains zero. Semantic/acoustic and encoding
fingerprints are independent; published/verified already-placed media is preserved.
The helper is native Swift/MLX, with no Python or external FFmpeg/ffprobe fallback.

Exact pins/licenses/patches are maintained in the [shared dependency record](../../docs/DEPENDENCIES.md).
Use the [single operator checklist](../../docs/OPERATOR_VALIDATION.md#voicerelay)
for real setup, listening, lifecycle and live services.
