# VoiceRelay source handling

Current application policy reviewed October 21, 2026. Shared parsing/OCR/image/narration
algorithms belong to [DocumentProcessing and NarrationCore](../../docs/DOCUMENT_PROCESSING.md).
VoiceRelay owns the authorized source fetch, archive lookup, retained article
identity/saved date and integrity-checked snapshots.

## Discovery, preview and retained text

Safari Reading List is read-only. Source selection belongs to General; the default
is Safari's Bookmarks.plist when no preference exists. Refresh failures retain known
inventory. Adding an article prepares it asynchronously, reports a per-entry error
if unusable and retains verified source plus semantic text for offline narration.
Original URLs/hosts/save dates remain the episode identity even after redirects or
archive recovery; generation time does not replace a missing saved date.

Double-click/Preview Article opens the dedicated, cancellable preview window.
Previewing an unprepared source fetches intentionally and does not implicitly add
queue membership. A queued article previews its integrity-checked saved text,
including its captured title; it does not refetch or regenerate that title.
Compare title/source, beginning/end, paragraph/list order, notes, omission notices
and generated-description provenance before narrating sensitive or complex inputs.
A login page, challenge or teaser is not successful complete extraction.
Preview captures the selected voice and shared pronunciation dictionary once and
uses the same mapped quantity/time decisions as narration from that context, with
visible notices. Native markup retains inline-code protection. Older retained
markup without trustworthy classification can abstain from automatic spoken forms;
it is not silently refetched or rewritten.

PDF responses use native PDFKit text and bounded structured Vision OCR, including
mixed/scanned pages. Locked/unreadable/oversized inputs fail individually. HTML
uses existing pinned extraction with semantic source provenance. Saved text resumes
offline without reopening URLs or repeating OCR/image models.

## Title recovery

New asynchronous preparations select useful document metadata, then a useful
Reading List title, then a reliable opening headline. Metadata matching either
PDF URL's filename is weak even when capitalization, punctuation, separators or
the extension differ. Native opening-page line geometry supports conservative
multiline headline recovery; recurring headers and ambiguous prominent bands
abstain. OCR paragraph height is not treated as font-size evidence; recognized
text remains available to optional generation. Ordinary first-paragraph prose is
not automatically used as a headline.

Optional Apple Intelligence title generation is off by default. It sees only a
bounded opening excerpt (first two PDF pages, at most 600 words/4,000 characters),
uses the shared inference lease and an eight-second cooperative cancellation
budget, and has no cloud fallback or app-initiated model download. Availability,
refusal, malformed results and inference errors preserve a fallback title.
Cancellation of the owning preparation cancels and joins title work. Injected
transports never invoke a native model; tests must explicitly inject a generator.

Title provenance is optional, backward-compatible snapshot metadata. VoiceRelay
persists the chosen title with approved text before narration. Local display
titles survive source refreshes without changing Safari metadata or URL-based
identity. Explicit Edit Title is limited to queued, unattempted, extracted work;
it updates the snapshot/checkpoint, queue row, episode and local catalog together.
Started work and published audio cannot be renamed by this operation. Existing
snapshots are reused without a new title-generation pass.

## Images and narration

Authored ALT and tagged PDF descriptions take precedence. Empty/decorative imagery
is not narrated. Conservative caption/credit/image dedup avoids repetition without
deduplicating ordinary article prose. Generated descriptions are brief, labeled,
on-device and optional; there is no cloud or automatic-model-download fallback.

General's Describe images with Apple Intelligence preference defaults on for future
admissions; retained text and finished media remain unchanged. Disable it to avoid
generated descriptions and their web-image retrieval; authored ALT and OCR remain
active. Web images use bounded credential-free public HTTPS retrieval. An unavailable
model or failed image leaves article text usable. PDF page imagery is not assumed
to have isolated figure geometry. Exact UI labels/ownership are in
[shared Settings guidance](../../docs/SETTINGS_ALIGNMENT.md).

Known local footnote links retain markers in source and resolve narration at their
first reference with explicit note cues. Repeated references do not repeat a note;
unresolved/unreferenced material produces visible notices rather than invented
text. Clear tables read labelled entries; uncertain tables identify the original,
with consecutive unavailable-table/code cues announced once per run. Shared
[scientific narration](../../docs/SCIENTIFIC_NARRATION.md) defines the conservative
equation/table rules and their limits. Decorative
separators can remain in source while omitted from speech. Actual reading order,
OCR and caption quality still require operator review.

## Optional archived-article recovery

General → Reading List → Try archived copies when articles fail is off by default.
When enabled, new preparation/preview first tries the original page. Eligible
network/HTTP or rejected-content failures may try Archive.ph, then Wayback. Already
retained text remains reusable; failed automatic admissions are not repeatedly
retried in the same session. Re-add explicitly after changing recovery preference.

Lookup sends eligible public article URLs to the archive provider. Known tracking
parameters/fragments are removed; other queries, embedded credentials, local/private
hosts, IP literals and nonstandard ports are excluded. There are no new archive
submissions, browser cookies, JavaScript execution, authentication tricks or CAPTCHA
solving. Requests/redirects stay bounded on provider HTTPS hosts with normal TLS
validation; rate limits/unusable responses fail safely. Prefer captures near the
saved date when available, otherwise the available latest capture.

Preview/snapshots record provider, capture date and source provenance. Archive
chrome is omitted where identifiable; original publisher narration/RSS identity is
retained. Archive lookup cannot recover source text that was never retained when
no eligible readable capture is available. Logs use sanitized provider/outcome
categories, never private URLs or bodies.

## Validation and diagnostics

The product CLI and its reading-list/review-url export commands are retired. Use
the app's Article Preview and sanitized Troubleshooting log for real-source
investigation. Use supplied synthetic files/providers for automated tests; never
point them at Safari or a live library. Do not publish source snapshots, private
URLs or full article text in bug reports.

Current operator cases are V05–V08 in the
[consolidated checklist](../../docs/OPERATOR_VALIDATION.md#voicerelay).
[Server reconciliation](SERVER_RECOVERY.md) restores matching audio history, not
lost article text. Previous implementation evidence is [historical](ARCHITECTURE.md).
