# VoiceServer speech API

VoiceServer serves locally generated speech while VoiceRelay is running. It is
off by default and works independently of Reading List and podcast publishing.
Clients must use HTTP/1.1; older HTTP versions are rejected before admission.
It uses the model, voice, speed, language, pronunciation rules and narration
options selected in the existing settings. Each accepted request keeps its
captured selection; changing settings affects later requests.

## Start and connect

1. Open **Settings → VoiceServer** and choose **Set Up VoiceServer…**. Until an
   access mode is chosen the pane shows only the setup launcher; afterwards the
   full settings appear and the same button returns to setup.
2. In setup, choose **Access** explicitly. **This Mac only** binds IPv4 and
   IPv6 loopback. **Tailscale** also binds only the local Tailscale addresses
   you select. **Other private VPN (advanced)** accepts only selected addresses
   currently present on this Mac; verify they belong to your intended private
   interface. Choose a port.
3. Choose **Generate Key**. The bearer key is stored in VoiceRelay's Keychain
   item. **Copy Key** places the complete key on the clipboard — it always begins
   `vs_` followed by the secret. Configure the whole `vs_…` string as your
   client's API key; a partial copy cannot authenticate. Never put the key in a
   URL.
4. Choose **Enable VoiceServer** to finish. The pane lists labeled **Speech
   endpoint** rows for this Mac and any selected private interfaces, with
   Tailscale MagicDNS when available in Tailscale mode. The **this Mac** row
   shows the IPv4 loopback address. **Copy** places the full `/v1/audio/speech` URL;
   metadata routes `/v1/models` and `/v1/audio/voices` share the same host and
   port. For a client with a configurable OpenAI-compatible base URL, use model
   `voicerelay` and voice `default`. Tailscale needs no `tailscale serve`; the
   listener binds the Tailscale interface directly and the tailnet itself
   carries the traffic.
5. Install or repair the selected speech model in **Voice Model** when needed.
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

## Client request headers

Send exactly these request headers; anything else is optional or rejected.

| Header | Required value |
| --- | --- |
| `Authorization` | `Bearer vs_<key>` — the complete generated key, which begins `vs_`. Send exactly one header; multiple, partial or missing headers return `401 invalid_api_key`. |
| `Content-Type` | POST `/v1/audio/speech` only: `application/json`, optionally `; charset=utf-8` (quoted or unquoted). Omit on GET routes — other types or multiple headers return `415`. |
| `Content-Length` | Optional; if sent it must fit within the request size limit. Metadata GETs must not send a body. |
| `Expect` | Optional; `100-continue` is the only supported expectation (the server answers `100` before the body). Any other value returns `417`. |
| `Host` | Sent automatically by your HTTP client. |

Rules that reject requests outright:

- HTTP/1.1 only, one request per connection — the response ends with
  `Connection: close`, so open a new connection for the next request.
- Do not send `Content-Encoding` (compressed request bodies are not supported)
  or request trailers.
- Never put the API key in a URL. The request header block is limited to 8 KiB.
- Responses carry `Cache-Control: no-store` and either a `Content-Length` or
  chunked streaming audio.

## Requests and formats

All three routes require `Authorization: Bearer vs_<your key>` and return
`Cache-Control: no-store`:

| Route | Result |
| --- | --- |
| `GET /v1/models` | Stable model alias `voicerelay` |
| `GET /v1/audio/voices` | Alias `default`, selected voice identifier and model readiness |
| `POST /v1/audio/speech` | Binary audio or a JSON-wrapped MP3, selected by `response_format`. The request body is JSON. |

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
| `json` | Complete file | `application/json` envelope `{"audio":"<base64 mp3>","content_type":"audio/mpeg"}` |

`stream_format: "audio"` is accepted; SSE is rejected. Set `stream: false` for
a complete MP3 or PCM response. WAV is complete-file only; explicit streaming WAV
is rejected. `json` is likewise complete-file only; explicit streaming is
rejected. For clients that need JSON, decode `audio` from base64 to obtain the
MP3 bytes. The response is about one third larger than the binary MP3. The
**Complete MP3, WAV and PCM files** toggle also controls the JSON envelope.
Orpheus requires complete-file output. Keep at least one response mode enabled.
Requests for disabled modes return an explicit error.
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
