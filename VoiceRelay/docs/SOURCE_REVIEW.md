# Manual source review — Slice 3 development

October 3, 2026. **Articles…** opens a source-review window alongside the existing
tone/Kokoro fixture controls. This is the first part of Slice 3: discovery, a
selected fetch, semantic/narration preview and explicit private export. It does
not yet turn a fetched article into an episode or persist a processing queue.

## Behavior and boundaries

- Refresh explicitly reads one property-list file using Foundation. It supports
  saved XML/binary hierarchies, prefers Safari UUIDs, and uses a URL/insertion-date
  fingerprint when a UUID is absent. It does not change Safari flags or bookmarks.
  Successful refreshes merge entries; absent entries remain visible. A failed or
  incomplete refresh retains known entries and exclusions.
- The inventory, selection and exclusions last only for the current app session.
  They are source-review controls, not durable queue or episode state. Selecting
  an entry does not fetch it; **Review selected** does. **Review URL** fetches
  exactly the entered URL, independently of the Reading List inventory.
- Each fetch has a fresh ephemeral URLSession, no cookies, credential store or
  cache, a byte bound and overall deadline. Defaults are 10,000,000 response
  bytes, 30 seconds and five redirects. Imported `max_article_bytes`,
  `http_timeout_seconds` and `chunk_max_chars` are used; fetch limits above 50 MB
  or 300 seconds are refused. HTML/XHTML, HTTP status and encoding are checked.
  UTF BOM, declared charset and HTML meta charset are supported; otherwise UTF-8
  is required. Credentials in URLs and every HTTPS-to-HTTP redirect are refused;
  authorization/cookie headers are stripped on accepted redirects.
- HTTP and HTTPS source URLs are recognized, but **system transport security
  remains enabled**. An HTTP source may be refused in the app; use its HTTPS URL.
  App-bundle HTTP behavior remains an operator gate. No blanket ATS exception is
  installed. Apple describes this policy in its
  [App Transport Security documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity).
- Fixed diagnostics avoid echoing private URLs or server error descriptions.
  Conservative title heuristics flag some login, consent and access-check pages;
  these are inspection aids, not comprehensive detection. Unknown pages still
  require review. Unsupported/status/deadline failures remain visible errors.
- Extraction and narration use the existing replaceable core. The window renders
  plain text only: ordered block kinds/text, warnings, bounded narration chunks
  and special-structure notices. It never loads scripts or displays downloaded
  HTML as a web page. Saved HTML is private source material, not sanitized HTML.
- **Save private snapshot…** is an explicit export to an empty folder or a marked
  VoiceRelay source-review folder. It refuses overlap with imported source,
  configuration, state, media and feed paths, the app's selected fixture workspace,
  and marked fixture ancestors. Root/export folders use mode 0700;
  files use 0600. The destination must be separate from fixture and served media.
  Each export has an opaque UUID directory. `response.json` is committed last;
  a directory without it is incomplete. Export cancellation can leave an incomplete
  private directory. Quit cancels and awaits owned review/fixture work.

```text
source-review/
  .voicerelay-source-review
  <uuid>/
    source.html       original response bytes
    response.json     original/final URLs, fetch metadata, source SHA-256, issue
    article.json      ordered semantic article and extraction version, if extracted
    cleaned.html      extractor output, if extracted
    narration.json    deterministic chunks/provenance/notices, if prepared
```

Failed extraction or a flagged HTML page can still be exported for inspection.
An HTTP/type/size/encoding failure does not create an export. Snapshots contain
private URLs and article text and must remain outside served media. Use
`var/source-review/` if storing them in this project; `var/` is ignored. Model and
runtime paths remain project-local and ignored; this slice adds no downloads.

## Step-by-step Xcode checks

No GUI or protected Safari validation has been performed by the agent.

1. Quit any running copy of VoiceRelay. Open
   `/path/to/VoiceRelay/VoiceRelay.xcodeproj` in Xcode.
   Choose **VoiceRelay → My Mac**, then **Product → Build** (⌘B).
   Run **Product → Test** (⌘U) when ready to run the core tests yourself.
   Report build/test failures with their first source diagnostic.
2. **Product → Run** (⌘R). Click the waveform in the macOS menu bar, then
   **Articles…**. Expect an ordinary review window. Opening it should not refresh
   Safari, fetch an article, start speech, or alter a feed.
3. Click **Choose plist…** and select
   `/path/to/VoiceRelay/Fixtures/reading-list.synthetic.plist`.
   Click **Refresh Reading List**. Expect two synthetic entries, including
   “Café 日本語”, and zero skipped entries. Select an entry, click **Exclude**,
   refresh and confirm its exclusion remains. Click **Include** to restore it.
   The fixture's `.invalid` URLs are placeholders; use the URL field for the
   article-quality checks below.
4. For actual Safari discovery, choose your `~/Library/Safari/Bookmarks.plist`
   through **Choose plist…**, then refresh explicitly. This step reads protected
   data under the actual app identity. If access is denied, keep the error and
   report it; permission changes remain your decision. A previously chosen
   synthetic file overrides the imported profile until another file is chosen.
   Alternatively test with a saved plist copy you can already access. Verify
   expected entries against Safari and that Safari's state remains unchanged.
5. Select one actual entry and click **Review selected**, or enter one public
   article's HTTPS URL and click **Review URL**. Expect either a plain-text review
   or an inspectable error. Confirm the original/final URLs and compare title,
   beginning/middle/end, headings, list order, quotation, Unicode and punctuation
   with the source. Check that menus, ads and footers have not become narration.
   Review code/table omission notices if present. Repeating the explicit fetch
   retries that one source; it does not process the backlog.
6. Click **Save private snapshot…**. Create/select a new empty directory outside
   all media/fixture roots, for example the project's ignored `var/source-review`.
   In Finder, inspect the returned UUID folder. Expect the files above and matching
   private source/provenance. A flagged/failed extraction has fewer files. Save
   again and expect a different UUID, preserving the earlier export.
7. While a fetch is in progress, click **Cancel**; the window should stay responsive
   and return to idle. A very fast response may finish before you can cancel.
   Enter `file:///private/synthetic` and click **Review URL** to check safe refusal.
   Try a selected PDF URL and verify it is reported as unsupported. Neither should
   produce speech, RSS, or published media.
8. Refresh with an invalid/unreadable plist (a copy you control). Confirm that
   existing entries and exclusions remain visible with an error. Close/reopen
   Articles and verify the session inventory remains. Quit/relaunch and verify
   that it resets; no durable source queue is implemented yet.
9. Open `Sources/VoiceRelayApp/SourceReviewView.swift`, enable **Editor → Canvas**,
   and check the named synthetic review, consent and retained-entry previews.
   They use inert file/network/export actions. Record Canvas rendering separately
   from compilation. Continue to track startup layout/linkd messages with the
   existing diagnostic guide; this slice does not claim to fix those warnings.

Return the build/test outcome and any failed step. For source quality, a short
description of omitted/reordered content is enough; private source exports do
not need to be shared. Test a conventional short, medium and long article before
we extend the reviewed-source path into Kokoro speech processing.

## Optional CLI and focused checks

Run from the project root. The synthetic discovery check needs no Safari access:

```sh
cd /path/to/VoiceRelay
swift build
native_bin="$(swift build --show-bin-path)"
"$native_bin/voicerelay" reading-list --plist "$PWD/Fixtures/reading-list.synthetic.plist"
swift test --filter SourceReviewTests
```

Expected discovery output: two entries, zero skipped; no titles/URLs printed.
`reading-list --plist /absolute/path/to/Bookmarks.plist` is the explicit protected
read under the launching CLI/Terminal context. It is separate from app and future
agent permissions. `doctor` remains read-only and does not read Reading List data.

To fetch/export exactly one URL, choose the source yourself and substitute its
HTTPS URL below. The command produces no audio/feed or live-state mutation:

```sh
"$native_bin/voicerelay" review-url --url 'https://example.com/selected-article' \
  --directory "$PWD/var/source-review"
```

An optional explicit `--config /absolute/config.toml` preserves imported limits
and adds destination-overlap protection. A local `config.toml`, if present, is
also imported read-only. A review-needed outcome is a completed diagnostic
export, not successful article acceptance. Operational fetch/export failure
returns exit 1 with a fixed diagnostic.

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

Extraction/narration version fingerprints have changed. Existing exported
snapshots remain unchanged; fetch/review/save again to create a new export.
Published fixture checkpoints continue to use their validated saved versions;
they are not re-extracted or regenerated merely because a version changed.
Use a new empty fixture folder to test the current policy. Browser rendering
and listening still need operator validation.

## Remaining acceptance gates

The focused suite exercises synthetic XML/binary files, URL/delegate redirect
policy, charset handling, in-process URLSession responses, bounds/deadlines/
cancellation, semantic provenance, failed-page outcomes and private exports.
It does not establish live network redirect/auth/TLS behavior, actual Safari
hierarchy/permissions, Xcode bundle/Canvas behavior or article quality.

Persistent queue/exclusion/retry state, representative real-source corpus,
reviewed-article Kokoro processing/listening, signed app relocation, agent
permissions and delivery remain future work. The existing explicit Kokoro speech
fixture has its own [operator guide and listening gates](KOKORO_PROVIDER.md).
No model inference, helper enrollment, live state adoption or upload occurs as
a side effect of opening Articles or building the project.
