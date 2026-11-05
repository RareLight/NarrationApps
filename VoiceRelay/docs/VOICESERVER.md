# VoiceServer speech API

VoiceServer serves locally generated speech while VoiceRelay is running. It is
off by default and works independently of Reading List and podcast publishing.
Clients must use HTTP/1.1; older HTTP versions are rejected before admission.
It uses the model, voice, speed, language, pronunciation rules and narration
options selected in the existing settings. Each accepted request keeps its
captured selection; changing settings affects later requests.

## Start and connect

1. Open **Settings → VoiceServer** and choose **Access** explicitly. **This Mac
   only** binds IPv4 and IPv6 loopback. **Tailscale** also binds only the local
   Tailscale addresses you select. **Other private VPN (advanced)** accepts only
   selected addresses currently present on this Mac; verify they belong to your
   intended private interface.
2. Choose a port and **Generate Key**. The bearer key is stored in VoiceRelay's
   Keychain item. **Copy Key** places it on the clipboard; configure it as your
   client's API key. Never put the key in a URL.
3. Turn on **Enable VoiceServer**. Copy an **API base URL**, which ends in `/v1`.
   The speech route is `/v1/audio/speech`. For a client with a configurable
   OpenAI-compatible base URL, use model `voicerelay` and voice `default`.
4. Install or repair the selected speech model in **Voice Model** when needed.
   Listener status and model readiness are separate. Metadata remains available
   with a valid key; speech returns a setup error if the model is unavailable.

The API implements a subset of OpenAI-shaped speech requests. Clients that
require other model/voice names, SSE, unsupported generation options or formats
need configuration changes or are incompatible. VoiceServer does not provide
remote model management, reference-file access, file serving, CORS or a public
relay. It binds HTTP; a running listener does not prove cross-device reachability
or HTTPS. Check private-network access from the intended client.

Tailscale discovery uses an installed Tailscale CLI's self status. It does not
configure Tailscale, obtain cloud tokens, store peers or fabricate a MagicDNS
name. Missing, disconnected or inaccessible CLI status is shown as unavailable.
Only the actual self MagicDNS name is displayed when available. Interface changes
close affected listeners and connections; no replacement LAN address is selected.

## Requests and formats

All three routes require `Authorization: Bearer <your key>` and return
`Cache-Control: no-store`:

| Route | Result |
| --- | --- |
| `GET /v1/models` | Stable model alias `voicerelay` |
| `GET /v1/audio/voices` | Alias `default`, selected voice identifier and model readiness |
| `POST /v1/audio/speech` | Binary speech audio; JSON request body required |

The minimal speech body is `{"input":"Read this sentence."}`. Optional supported
fields are `model`, `voice`, `speed`, `response_format`, `stream` and
`stream_format`. Omitted model/voice resolve to the captured selection. Explicit
model must be `voicerelay`; voice must be `default` or the exact currently
selected voice identifier; explicit speed must match the GUI setting. Other
fields and mismatches are rejected, rather than ignored. Input text is not saved.

| `response_format` | Default behavior | Encoding |
| --- | --- | --- |
| `mp3` or omitted | Streaming | One continuous mono 24 kHz MP3 stream |
| `pcm` | Streaming | Raw mono signed 16-bit little-endian, 24 kHz; no header |
| `wav` | Complete file | Mono Float32 WAV at the selected model's native rate |

`stream_format: "audio"` is accepted; SSE is rejected. Set `stream: false` for
a complete MP3 or PCM response. WAV is complete-file only; explicit streaming WAV
is rejected. Orpheus currently requires complete-file output. Settings must keep
at least one response mode enabled; disabled modes produce an explicit error.
No normalization, leveling, limiting or gain is applied. PCM conversion rejects
out-of-range samples rather than clipping them.

The initial live unit is smaller than ordinary narration packing. Audio is sent
as completed bounded utterances become available. A single indivisible unit
still needs generation before its audio can arrive. Qwen's raw incremental
decoder remains outside normal serving pending listening acceptance. Native
latency and sustained client playback require operator validation; fixture timings
are not model performance measurements.

## Limits and lifecycle

Defaults bound the body to 64 KiB, input to 16 KiB of UTF-8, accepted queued work
to four requests plus one active request, aggregate accepted input to 64 KiB,
connections to eight and response audio to 64 MiB. Header/body receipt has a
10-second deadline, queued work a 30-second wait, accepted work a 10-minute
deadline and stalled writes a 15-second timeout. Each connection serves one
request and closes. Overload returns 429; known setup failures return 503 before
audio headers. A failure after audio begins closes that response without JSON
appended to audio or automatic replay.

Live API work has priority over Libro, then podcasts. Streaming requests cancel
unfinished lower-priority inference through the owned helper and resume eligible
work from verified checkpoints. Complete-file requests yield at safe boundaries.
Compatible requests in the same app can reuse its loaded model; moving between
apps unloads the old model before loading the new one. Manual pause stays separate.
Older builds retain compatibility locks; restart both current builds when testing
the new cross-app behavior.

**Stop** stops the current service without changing the saved enablement choice;
**Start** restarts it. Turning enablement off prevents launch-time restart. Closing
Settings or other windows leaves the service running. Quit, sleep, disconnect,
deadline and key rotation cancel affected live work; interrupted API requests are
never replayed. Listeners may restart on wake if enabled and not manually stopped.
VoiceServer does not prevent system sleep. **Rotate Key…** revokes the old key and
cancels all queued and active API responses; update every client afterward.

API requests create no podcast queue rows, episodes, feeds, timed transcripts,
backups or retained narration reviews. Private response scratch is removed after
joined work; versioned, unlocked orphan scratch can be cleaned on later use.
Unknown or still-owned scratch is retained. Keys are never stored in preferences,
URLs, logs or library backups, and worker stderr is not retained across API jobs.

Actual model listening, client streaming, Keychain signing, private-network
reachability and sleep/wake acceptance are tracked in the
[operator checklist](../../docs/OPERATOR_VALIDATION.md#voiceserver-staged-acceptance).
