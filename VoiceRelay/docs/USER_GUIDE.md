# VoiceRelay user guide

VoiceRelay turns Safari Reading List articles into a private podcast using local
local native speech and WebDAV publishing. While the macOS app runs, it discovers
articles, prepares saved text, processes the queue and publishes episodes according
to your preferences. Failed items remain available for manual Retry. Safari
bookmarks and Reading List flags are never modified.

Requires Apple Silicon and macOS 27.0 or later. For building/signing, use
[contributor instructions](../CONTRIBUTING.md#signed-builds).

## First launch and startup

On first launch without a speech model, **Model Setup** offers
**Install Model**, **Choose Custom Model Folder…** or **Not Now**. Choosing an
installed model folder offers **Check Model** to verify it offline.
Installation starts only after your choice;
you can cancel or retry without leaving setup. Installed models skip this window
and are checked offline at startup. To install later, use
the **Download** arrow icon beside the model picker in **Settings → Voice Model**.
Installation explicitly downloads verified native model and pronunciation assets;
**Check Speech Setup** loads the installed model offline without generating audio. Models default to the shared Hugging Face cache. **Voice Model → Downloaded models** lists disk usage, deletion controls and a folder override. Existing custom locations remain supported. Cancel and Quit join owned setup work;
global environments are unchanged. See [model selection and setup](../../docs/MODEL_SELECTION.md); the [Kokoro provider notes](KOKORO_PROVIDER.md) describe the retained original backend.
The result appears beside Check: Speech setup not checked, Speech setup ready or the failure.
Publishing and source refreshes do not disable speech setup controls; active audio
work and library maintenance do, with a reason shown in Voice Model.

**Start VoiceRelay at login** defaults on for fresh configurations and is controlled
only in **Settings → General → Startup**. Existing configurations retain their
startup setting; disabling it in VoiceRelay or macOS is respected on later launches.
The default is attempted once; failures can be retried from Settings.
If macOS requires approval, use **Open Login
Items Settings**. VoiceRelay starts in the menu bar after sign-in, without opening
library/setup windows, and resumes your configured automation. Quit stops the app;
it next starts when you open it or log in again. Turn the option off to stop future
automatic launches. Changes in System Settings are reflected when you return to
Settings. This starts the ordinary app at login, not a service before sign-in.

## Voice model

**Settings → Voice Model** brings together model and voice selection, speaking
speed where supported, download when no files are cached, model details, and **Play Sample**.
Model and Voice keep the same positions when switching models; extra options
appear below them in compact, aligned rows, followed by **Play Sample**. The section
grows or shrinks to fit the selected model's controls. Speed’s value and
arrows stay beside its label. Cached models show only **ⓘ** beside the picker;
sizes and deletion are in **Downloaded models**, in compact aligned columns.
Click **ⓘ** for the
model description and quality/speed meters. For cached models, **Download missing
files** in that popover completes or repairs installation without deleting it first.
Use **Downloaded models** for disk usage, deletion and storage location; use
**Check Speech Setup** to verify the selected model offline. Changes apply to newly
queued articles; existing jobs keep their captured choices. The Articles window
focuses on browsing and processing your queue.

## Everyday use

**General → Appearance → Text size** adjusts text throughout the library,
Settings, previews, Help and menu popover. Use **⌘+**, **⌘−** and **⌘0** to enlarge,
reduce or reset it. The preference persists; small text stays at least 12 points.

Left-click or right-click the circular waveform menu-bar icon to open the same
compact popover immediately, without an opening animation, with overall status, **Sync Now**,
**Articles**, **Server Audio**, **Copy Podcast URL**, **Settings** and **Quit VoiceRelay**.
**Copy Podcast URL** copies the configured subscription address to the clipboard;
it is unavailable until a Public folder URL is configured. Green **Ready**
requires a successful Reading List read, verified speech runtime and verified
WebDAV connection this session. A red problem status opens its affected Settings
pane. Startup checks the installed speech runtime offline, without downloading.
The menu fits its command labels with 25% extra horizontal room and follows your text size. Status text and Sync
progress fit within that width. Keyboard focus outlines appear after you press
**Tab**; Tab and Shift-Tab navigate commands as usual. The menu-bar symbol uses
a larger SF Symbols configuration within the standard square click target.

**Sync Now** refreshes the Reading List, checks existing server audio, prepares new
articles, generates Ready work and publishes it, even when automatic admission and
processing are off. It does not change those preferences or retry failed speech
rows. During this one-shot task, its button becomes a compact phase progress bar:
measured generation/current-file transfer progress, animated checks, then the button returns.
Articles and Queue are scopes in one library window alongside Uploads and Server
Audio. Opening a standalone window enables the Dock/⌘-Tab entry; closing the last
returns to menu-bar-only operation. Closing windows does not stop work.

1. In **Settings → Voice Model**, choose Model and Voice. Fresh settings use
   **Kokoro (Recommended)** with Heart at 1.0×; saved choices are preserved. Kokoro offers 28 English
   voices marked US/UK and speaking speed from 0.5–2.0× in 0.05 steps. Qwen offers a
   narration language and optional delivery instruction; Chatterbox offers local
   reference-voice import. The **ⓘ** popover’s relative speed/quality meters compare models
   without benchmarking your Mac. See the [model guide](../../docs/MODEL_SELECTION.md).
   New admissions capture these choices; earlier queued articles keep theirs.
2. Safari's `~/Library/Safari/Bookmarks.plist` is the default source. In
   **General → Reading List**, choose another file if needed. Discovery runs at startup,
   every five minutes, when Articles appears or the source changes, and on
   Articles' pull-down gesture. Newest saved items appear first; ties keep discovery
   order and undated entries come last. Automatic admission and processing are
   controlled by the General preferences.
   If an entry's address changes, refresh removes its old queued work and cached
   source text once no current entry refers to that address. Published episodes remain.

3. **Add to Queue** prepares selected articles in displayed order in the
   background, showing Preparing and per-entry failures. Saved text is reused
   offline. Double-click or **Preview Article** opens the dedicated preview window;
   that window fetches the page. Optional **Try archived copies when articles
   fail** is off by default; see [article handling](SOURCE_REVIEW.md).
4. **Generate Audio** (⌘⇧G) drains Ready work, pending preparations and late
   additions in processing order. **Stop** (⌘.) returns interrupted speech to
   Ready and suspends automatic processing until new work arrives or Generate is
   pressed; already-started finalization can finish. Quit joins owned work while
   retaining recoverable checkpoints. Relaunch resumes eligible automation.
   Failed rows require Retry; they are not repeatedly retried automatically.
5. Queue removal deletes only queue membership. Source entries, saved text and
   server audio remain. Individual and multi-selection removal need no
   confirmation; **Reset Queue…** does. Scope selections remain independent.

### Duplicate articles

VoiceRelay compares copies with the same title and original website, or the same
source URL. It chooses readable full text over a paywall preview or failed copy.
Among copies within 5% of the longest extracted prose, the most recently saved
wins. Dates help choose the copy; they are not part of duplicate matching.
Other copies stay visible in All Articles, gray and labelled **Inactive duplicate**.

A new save of an already narrated article generates fresh audio with your current
voice settings. Existing unfinished work keeps its captured settings unless a new
duplicate admission replaces it. VoiceRelay confirms the replacement audio and
feed membership before removing older matching episodes from the feed, then
cleans up their owned server audio and transcripts. Failures retain the old server
files until safe cleanup can finish. No Safari entry is changed.

Handled entries, including inactive copies, are remembered in the private library.
Leaving duplicates in Safari, refreshing, restarting, clearing the queue or
removing their audio does **not** automatically create more recordings. A genuinely
new save is eligible again. You can explicitly Add to Queue for the active copy
when you want another recording; queued retries retain their captured settings.

Search in Articles (All Articles/Queue), Uploads and Server Audio matches visible
titles, source, saved dates, status and errors. Searches are local, combine with
the Website/state filters and do not restrict automatic processing or publishing.

Articles, Queue/preparing rows and Server Audio share the original-website and
Saved-date line. A missing saved date is omitted rather than replaced by the
voice-generation date. Progress appears only during owned work; publishing is
shown separately from speech/finalization.

### Article titles

When adding an article, VoiceRelay keeps a useful document title or Reading List
title. An embedded PDF title that repeats the original or redirected filename is
treated as a fallback: VoiceRelay looks for a richer opening headline first.
Capitalization, separators and the `.pdf` extension do not make a filename into
a distinct title. If no reliable improvement is found, the original title remains.
For web articles, a descriptive title matching the URL slug is retained.
The recovered title appears in All Articles, Queue, the spoken introduction and
the resulting podcast episode; Safari's Reading List is never modified.

**Settings → General → Article titles → Generate missing titles using Apple
Intelligence** is off by default. When enabled, VoiceRelay can create a short,
factual title from the opening text if extraction finds no useful title. This
uses available on-device Apple Intelligence, with no cloud fallback. If it is
unavailable or generation fails, the article continues with its fallback title.
The preview identifies generated and recovered titles. For queued articles, the
preview uses saved text rather than fetching a different copy from the website.

To correct a title, stop audio processing, select a queued article and use its
context menu's **Edit Title…** before its first audio-generation attempt. The
correction also updates its spoken introduction. Saved titles are reused; these
changes do not automatically rename old snapshots or published recordings.

## Timed episode transcripts

**Settings → General → Episode transcripts → Publish timed transcripts** is on by
default. The choice is captured when an article is queued; changing it affects new
articles. Existing queued jobs and completed recordings keep their captured choice.
Old recordings are not regenerated or automatically given estimated transcripts.

Enabled articles produce a WebVTT transcript from the final prepared narration
text, including its introductions and pronunciation changes. Timestamps describe
synthesis segments and account for resampling and inserted pauses. They do not
claim individual word timing or correct words a speech model may omit/mispronounce.
Original article text and audio levels are unchanged. No extra speech-recognition
model, cloud transcription service or download is needed.

Sync Now uploads the transcript beside the episode under `audio/`, verifies its
contents and publishes a standard `podcast:transcript` RSS link. Your host must
serve `.vtt` files with the `text/vtt` content type and the same access protections
as your audio. Player support determines whether live scrolling and seeking are
available. Overcast support for supplied transcripts remains unverified, including
the reported App Store version 2026.10.1 (1182).

A transcript failure leaves audio publishing available and appears in Uploads as
**Transcript needs retry**. Sync Now retries it without regenerating the recording.
Transcript text is retained with private episode metadata and included in library
backups, even after temporary audio/article caches are released. Removing a server
episode removes its owned transcript after its RSS entry is removed; changing hosts
preserves copies at the previous destination.
Changing only the Public folder URL refreshes owned transcript links through normal
publishing, with verified sidecar readback and no audio regeneration.

## Publishing and Server Audio

In **Settings → Publishing**, supply complete HTTPS **Feed folder URL** and
**Public folder URL**, channel details and WebDAV credentials. For example,
`https://webdav.example/podcast/` can upload files served at
`https://podcast.example/`. Follow your provider's mapping instructions; these
addresses need not be identical. VoiceRelay puts `feed.xml` and lowercase `audio/`
under each folder. **Subscription URL** is read-only with **Copy** for Overcast
or another podcatcher.

Turning Publishing off cancels the active publishing batch and prevents further
requests. A request already accepted by the server may have completed; retained
verification and retry state allow publishing to resume when you turn it on again.

**Podcast Cover** in Publishing accepts a square, opaque JPEG/PNG of at least
1400 pixels per side; larger images are reduced to at most 3000 pixels. VoiceRelay
starts with the bundled icon-derived cover when no cover has been chosen. Replace
it freely, or Remove it to keep the show without art; custom covers and explicit
removals persist across launches. Choose,
Replace or Remove applies to the overall show. Episode pictures still come from
article preview/social metadata. Artwork is verified before the feed references
it; a failed change preserves the previous feed. Cover-only changes do not
regenerate episode audio. The cover is Publishing configuration, separate from
library backups; restoring a library keeps the current cover configuration.
The bundled default uses the compressed `VoiceRelay_Cover.jpg`. Existing saved
covers stay selected; to switch a previously saved default, choose the new JPEG
in Publishing and use Sync Now. See [artwork troubleshooting](SERVER_RECOVERY.md#podcast-artwork)
if a podcast player still shows no cover.

In article previews, **Contents** navigates authored headings or PDF bookmarks;
page-only destinations remain page-only. **General → Document Narration** offers
**Footnotes** (Read with the text, Read at the end, Do not read) and
**Read appendices and extra sections**. Citation stripping and experimental PDF
word joining are also available, off by default. See the
[narration guide](../../docs/NARRATION_GUIDE.md). These settings
apply to newly queued articles with explicit source semantics. Without citation stripping, bibliographies
and unclassified prose remain, source omissions are visible, and existing queued
articles keep their captured preferences. Shared implementation is recorded in the
[cover/navigation stages](../../docs/COVER_ART_AND_NAVIGATION_PLAN.md).

Pasted URLs normalize on commit: whitespace, missing HTTPS, spaces/percent escapes,
redundant slashes, dot segments, default ports and trailing slashes are handled.
A pasted feed.xml URL resolves to its parent. Credentials or query parameters
require a field-specific correction and are never echoed in diagnostics.

Passwords persist only in the device-local Data Protection Keychain, accessible
after the first unlock following a reboot, including while the screen is locked.
Background publishing never opens an authentication prompt. For a password saved
by an older build, enter it again and choose **Save Password** once to update its
access policy; macOS may ask for authorization during that explicit Save. Cancelling
preserves the previous item. Successful reads are cached until Quit; opening
Settings does not query Keychain. Passwords never enter preferences or backups.
Keep a stable app signing identity; changing identity/distribution channels can
separately affect Keychain authorization even in Release builds.

**Test Connection** probes folders read-only; it proves neither write permission
nor the public website mapping. A readable ancestor permits a missing-folder
result; uploading creates folders if authorized. Use the popover's **Sync Now**
for a complete manual sync, or **Uploads** for targeted upload retries. Publishing
settings has no upload action. Enabled publishing drains after publication/removal, launch and
periodically while the app runs. Media size and hash are confirmed before feed publication; the uploaded feed is
read back through authenticated WebDAV and its exact contents confirmed.

**Server Audio** is durable episode history. **Published** means current-destination
media bytes and feed membership are confirmed. **Upload New Items** appears only
while shown episodes need upload/publication. Removing an episode retires feed
membership before remote media deletion. Clicking **×** removes the row immediately,
without a deletion animation; cleanup continues in the background and the lower
status bar reports progress. You can delete other items while it runs. Failed
cleanup returns the affected item with its retry/error state. If Publishing is off
or unavailable, unfinished server cleanup stays listed rather than remaining hidden.
**Reset Server Audio…** requires confirmation. Source entries and retained text
are preserved. **Show in Finder** applies only to older remaining local copies.

Server Audio sorts newest article saved dates first, with undated episodes last.
Saved dates and original websites remain searchable after removing the source
article from Safari; generation dates do not replace missing saved dates.

Finished audio uses app-owned macOS temporary storage. Its local copy is removed
only after both media and feed confirmation, with committed cleanup intent and
hash/file-identity checks. Missing unconfirmed output regenerates from retained
text under the same episode identity and captured voice; failed rows stay manual Retry.
Destination changes recreate released bytes and preserve old-host files. There is
no audio-folder preference or scheduled retention policy.

### Understand removal actions

| Action | Removes | Preserves |
| --- | --- | --- |
| Remove from Queue | Queue membership | Safari entries, saved article text and server audio |
| Uploads × | The tracked local audio copy and matching pending queue work | Server audio and saved text; the discarded copy is not automatically regenerated |
| Remove an article in Safari, then refresh | Article/queue entries, cached source text and unfinished generation files | Server history/copies, unconfirmed finished audio and already exported backups |
| Remove in Server Audio | Feed membership first, then verified server audio and a safely removable matching local copy | Safari entries and saved article text |

Remove unwanted articles in Safari Reading List. After a successful source refresh,
VoiceRelay removes them from Articles and Queue and clears cached article text and
unfinished generation files. Server Audio history and server copies remain until
you remove them in Server Audio. Unconfirmed finished local audio stays available
for publishing; confirmed media/feed copies can be released locally as usual.
Failed source reads preserve the library. Private backups already exported are
not changed by later article removal.

The Articles filter starts with **Today** and **This Week**, based on the Reading
List saved date in your local calendar. Undated articles appear under All Websites
or their website filter. Search combines with the selected filter in each scope.

Publishing automatically reconciles existing server feed/audio with local state.
Verified matches restore history and leave Queue without regeneration or media PUT.
At comparable voice/speed, the longer valid copy wins; ties retain the server copy.
Recovery conflict replacements preserve the old server file. Deliberate new-save
replacements follow the duplicate rules above. Item errors retain existing feed membership
while unrelated work continues. Cached proofs and conditional requests reduce
repeated downloads. Exact identity or retained-link evidence is required; titles
and orphan filenames are insufficient. See [automatic reconciliation and operator
tests](SERVER_RECOVERY.md) for conflict rules, caching and matching limits.


**Uploads** is the publishing outbox, between Articles and Server Audio. It shows
per-item transfer progress, pending feed publication and verification failures.
Confirmed published items leave the outbox; unresolved local cleanup conflicts
remain with their diagnostics. Both screens have independent **Filter** menus,
including **Needs Attention** and **Failed Verification**. Filter changes do not
contact the server. Partially generated speech remains in Articles → Queue.

Uploads rows offer **×** to discard only their tracked local copy, keeping server
audio and saved article text. Explicitly discarded copies are not automatically
regenerated. Failed removals remain listed for retry. Server Audio records an
unpublished discarded copy as **Local Upload Removed**.

Articles and Queue each retain their own **Website** filter. Foundation parses
and normalizes original hosts; HTTP/HTTPS, capitalization, trailing host dots
and `www.` aliases group together. Other subdomains stay distinct. Filtering does
not change source URLs, processing order or automatic processing; selection
actions apply only to visible rows.

Discarding local audio also removes its matching Queue work; you can add the
article again manually.

For publishing or backup guidance, open **Help → Publishing and Uploads** or
**Help → Library Backup and Restore**. Section ⓘ controls give brief summaries;
**More Help…** opens the corresponding guide. Help content is bundled and offline.

## Privacy and backups

Speech generation and the shared pronunciation dictionary stay on the Mac.
Fetching articles and optional images uses the network. If archive recovery is
enabled, eligible article URLs are sent to archive providers. Publishing uploads
audio, feed metadata and show artwork to your configured server. Privacy of the
published podcast depends on that server's access settings.

The native library remains at
`~/Library/Application Support/VoiceRelayPrototype/SpeechLibrary`. Compatibility
paths and internal preference keys are retained. Clearing Xcode Derived Data does
not erase the library; changing the app bundle identifier changes its preferences
domain. The running app owns processing/publishing. Optional login startup registers the
ordinary app with macOS; there is no separate background agent or daemon.
Private legacy environments, customized state and published files are preserved
in their existing locations and never silently imported.

**Troubleshooting → Library backup** exports retained text, inventory, queue,
episode history and delivery bookkeeping using SQLite backup, including WAL
commits. Backups exclude credentials, preferences, audio, scratch and models.
They contain private source content and server information: keep them private.
Restore validates/stages before replacing the library, preserves the previous
library and disables automation/publishing behind **Finish Library Review**.
It does not change Safari, local audio or server files. See [backup/restore checks](../../docs/OPERATOR_VALIDATION.md#voicerelay).

**Troubleshooting → Enable debug logging** retains the newest 200 events in memory.
The toggle persists; events do not survive Quit. Copy Debug Log and Clear Log
operate on this session. Logs include sanitized HTTP outcomes/stage timings,
never credentials, URLs, paths, source text, authorization headers or server bodies.

## Speech samples and pronunciation

General's Play Sample/Stop Sample plays the supported voice's bundled recording at
1.0× without loading a model. All samples now use:

> Hello, I can narrate everything from short articles to entire ebooks. Let's get started on a new read together!

Settings → Pronunciation edits one shared Libro/VoiceRelay spelling dictionary.
Use English phonetic spellings and Play to hear a native preview at the selected
voice/speed. Saved samples do not incorporate new overrides. Ordinary narration
captures rules for its work; editing a rule does not rewrite finished recordings.
See [pronunciation](../../docs/PRONUNCIATION.md) and
[sample regeneration](../../docs/VOICE_SAMPLES.md).

The accepted Kokoro pacing is implemented. Explicit kilograms, temperatures, AM/PM times and letter-A labels have shared
spoken-form corrections. Ambiguous forms and contextual homographs remain [known frontend limitations](../../docs/TEXT_NORMALIZATION_RESEARCH.md);
changing speed or voice is not a general correction for those cases.

## If something goes wrong

Use the row's error and the relevant Settings section to identify whether the
problem concerns Reading List access, speech setup, article extraction or
Publishing. Retry failed speech explicitly. Test Connection checks read access;
it does not prove upload permission or the public URL mapping. Rebuilding with a
different signing identity can affect Keychain access; use a consistently signed
build for account checks.

For detailed source failures, see [source handling](SOURCE_REVIEW.md). For pending
or conflicting server copies, see [server recovery](SERVER_RECOVERY.md). Back up
before experimenting with a library restore; never delete the live library or
models to fix an Xcode build problem.

### Optional narration quality review

Kokoro always uses semantic phrasing. For other models, Voice Model Settings offers
**Try semantic phrasing**, initially off. Model details
can retain private chunks for review. Pronunciation Settings then supports
sentence-context previews, scoped rules and explicit retained-passage checks or
regeneration. Reviewing/exporting a new WAV does not replace podcast episodes,
RSS or transcripts. See [long-form quality](../../docs/LONGFORM_QUALITY.md) for
local recognition availability, storage limits and the blind comparison.
