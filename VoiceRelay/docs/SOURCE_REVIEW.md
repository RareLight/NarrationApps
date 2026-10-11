# Article handling and source diagnostics

Updated October 10, 2026. Everyday queue/processing instructions are in
[README](../README.md#everyday-use); native interaction checks are in
[UI_ACCEPTANCE.md](UI_ACCEPTANCE.md). This guide covers article preparation,
optional archived copies and explicit source diagnostics.

## Discovery, preview and saved text

Choose the Reading List source in **General → Reading List**. The app checks it
at startup, every five minutes, on Articles appearance/source change and through
pull-down refresh. Safari input is strictly read-only. Transient failures retain
known inventory. Articles shows newest saved entries first, stable discovery
order for ties, and undated entries last.

After a successful read, entries removed from Safari disappear from Articles and
Queue. Their cached pages, narration plans, chunk checkpoints and unfinished
generation files are cleared after owned work stops. Failed reads preserve data.
Published episode metadata and server media stay in Server Audio until manually
removed; unconfirmed finished audio stays locally until publishing succeeds.
Previously exported backups are not rewritten. Today and This Week use local
calendar periods and saved dates; undated entries do not match those filters.

Selecting rows fetches nothing. Add to Queue prepares them in displayed order in
the background, showing Preparing and collecting per-entry issues. Already-queued
sources are omitted from manual Add. Existing saved text is reused offline;
removing queue membership does not delete the snapshot or source. New admissions
capture voice, region and speed; changing preferences does not rewrite existing
captured choices. Failure of one admission does not stop later selected entries.

Double-click or Preview Article in either scope opens the dedicated preview window.
For a retained job, its URL is resolved read-only from saved metadata, then the
window fetches the page. Inert previews never fetch. Troubleshooting shows source
status and diagnostics, not another saved-article list, URL importer or preview.

Original website and Reading List saved date follow the article through Queue and
Server Audio independently of RSS canonical-link metadata and publication time.
Narration starts with title and publisher (host fallback), preserves source blocks,
and closes with a separate “End of article.” paragraph. Unreadable, login/challenge,
missing or incomplete article results remain inspectable failures, not silent
success. Source rendering is plain text; raw HTML is retained privately, not shown
as a runnable page.

## Optional archived-article recovery

Under **Settings → General → Reading List**, enable **Try archived copies when
articles fail**. This preference defaults off. A new admission or Article Preview
first tries the original site. Recoverable HTTP/network errors and rejected
login, subscription, missing-page, browser-check or extraction results can then
try Archive.ph, followed by the Wayback Machine. Re-select previously unsuccessful
Articles and use **Add to Queue** after enabling it; automatic admission does not
retry a failed entry again in the same session. Already saved text remains offline.

Lookup discloses the public article URL to the archive provider. Known tracking
parameters and fragments are removed; other queries, embedded credentials,
local/private host names, IP literals and nonstandard ports are excluded. This
reads existing captures only. There are no archive submissions, browser cookies,
JavaScript execution, authentication tricks or CAPTCHA solving. A provider error
or unusable snapshot falls through once; failed recovery keeps the original issue
and adds a safe unavailable message. Unsupported document types/size-limit failures
remain failures. Each provider has at most one index and one HTML request, bounded
by ten seconds per request and the existing byte limits. Archive requests and
redirects stay on the provider's HTTPS hosts with standard certificate validation.

When available, captures closest to the Reading List saved date are preferred;
otherwise the latest listed capture is used. Original URL, queue identity, saved
date and publisher narration are retained. Snapshot URL, provider and capture date
stay in the private integrity-checked article snapshot; Article Preview displays
that provenance. Archive chrome is omitted from extraction where identifiable.
Publisher-hosted HTTPS artwork can remain; archive-hosted replacements are omitted.
Nothing about archive provenance is added to RSS. Debug logging records only fixed
provider/outcome events, never lookup URLs or article contents. Cached text can be
older, incomplete, or unavailable; live acceptance remains an operator check.

Research before implementation:

- [archivetoday](https://github.com/HRDepartment/archivetoday) is an unofficial
  JavaScript client exposing TimeMap lookup and capture creation separately.
- [@agntn/archives](https://github.com/agntn/archives), formerly omnichron, is a
  TypeScript adapter over multiple archives and requires Node.js.
- [Memento RFC 7089](https://www.rfc-editor.org/rfc/rfc7089.html) describes TimeMap
  link serialization; Archive.ph's public example.com response confirmed its
  timestamped replay links and `application/link-format` MIME type.
- [Wayback Availability API](https://archive.org/help/wayback_api.php) documents
  read-only lookup, timestamp selection and available snapshot results.
- The supplied RemovePaywall search page could not be retrieved during research;
  no supported automation API was verified, so it is not an automatic provider.

VoiceRelay uses these existing protocols with its bounded Foundation client and
SwiftSoup, without adding a JavaScript runtime or copying third-party library code.

## Explicit diagnostic CLI

These commands are optional and do not run in the normal app workflow. Build the
CLI once from the project root:

```sh
swift build --product voicerelay
native_bin="$(swift build --show-bin-path)"
"$native_bin/voicerelay" reading-list --plist "$PWD/Fixtures/reading-list.synthetic.plist"
```

The synthetic fixture reports two entries, zero skipped, without printing titles
or URLs. Reading a real Bookmarks.plist requires an explicit path and the launching
Terminal/CLI's protected-file permission, which is separate from the app's context.
Doctor is read-only and does not read Safari input.

To fetch/export one deliberately selected article into private ignored storage:

```sh
"$native_bin/voicerelay" review-url --url 'https://example.com/selected-article' \
  --directory "$PWD/var/source-review"
```

Use `--use-archives` only to opt into archive lookup for that diagnostic, and an
optional `--saved-at` ISO8601 timestamp to inform capture selection. An explicit
`--config /absolute/config.toml` imports limits and destination-overlap protection;
no config is implicitly imported by review-url. The command produces no audio,
feed, server changes or live-library adoption. A review-needed outcome is a
completed private diagnostic export, not article acceptance. Operational failures
return exit 1 with sanitized text. Exported files/paths and article content remain
private; do not publish them with a bug report.

## Caption, encoding and footnote policy

Cleaned HTML exports are complete documents with an explicit UTF-8 charset.
Inline media and embedded content are removed from this review artifact. The
immutable source snapshot retains original image markup, URLs and alt/caption
material. Explicit caption classes are converted to caption elements before
extraction; adjacent identical caption blocks are retained once. Repeated body
paragraphs and captions separated by other content are preserved. Captions are
read once as authored text; no AI image interpretation runs.
Header publication-time/permalink markup is omitted from the derived review to
avoid metadata and URL readouts; it remains in the original snapshot.

Semantic blocks preserve original reference-marker text. Optional
`narrationText`, `footnoteReferences` and `footnoteID` fields distinguish spoken
wording and target/provenance from that text; old artifacts without these fields
still decode. Recognized local footnote/citation links (numbered or symbol
markers, explicit roles/relations/classes, and common target IDs) omit their
marker/backlink from speech. At the first reference, narration inserts the
resolved note's paragraphs after the referring block:

```text
Referring paragraph without its reference marker.
Footnote:
First footnote paragraph.
Second footnote paragraph.
End Footnote
Next article paragraph.
```

Repeated references do not repeat the note. Definitions discarded by the
extractor are recovered from the private source for referenced targets; unrelated
source-page notes are not imported. Unreferenced notes retained by the extractor
remain at the end with a notice. Unresolved marked references produce a notice,
with no invented note text. Ordinary numbers, mathematical superscripts and
unmarked citations are not guessed or stripped. Decorative symbol separators
are retained semantically and omitted from speech.
Repeated adjacent table/code omission announcements are spoken once per run,
including across silent separators. Spoken prose or footnote boundary cues end
a run. Original blocks and per-block omission notices remain available for review;
authored prose is not deduplicated.

Extraction/narration fingerprints preserve versioned requests. Existing exported
snapshots remain unchanged; use the explicit diagnostic CLI to create a new export.
Published fixture checkpoints keep their validated saved versions;
they are not re-extracted or regenerated merely because a version changed.
Use a new empty fixture folder to test the current policy. Browser rendering
and listening still need operator validation.

## Acceptance

Use a private representative corpus and compare completeness, title/source,
paragraph/list order, captions, notes and archive provenance with the original.
Saved text can be older than the live page; recovery availability is not guaranteed.
Listening is separate from extraction assertions. See
[BETA_TESTING.md](BETA_TESTING.md#1-normal-run-and-real-article-corpus) for the
operator report and [SERVER_RECOVERY.md](SERVER_RECOVERY.md) for server history
reconciliation, which does not restore lost article text.
