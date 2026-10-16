# Cover art and document navigation implementation plan

Authorized and implemented October 15, 2026. CA0–CA3 and DN1–DN3 are implemented;
automated evidence and operator gates are recorded below. SF1 retains the accepted
spoken-form baseline and its regression coverage: no new lexical rule was added
without a reproduced context-safe defect. GUI, real-player/listening and live-feed
acceptance remain operator-owned, including the earlier B06 gate.

## Goals and scope

Deliver cover art first, then the highest-value document improvements: authored
outlines/navigation, local duplicate-heading handling, explicit note/auxiliary
narration controls, and narrowly justified spoken-form corrections. Keep shared
behavior in SwiftNarration; neither app must depend on the other's checkout.

Libro covers belong to individual document exports. VoiceRelay's user-selected
cover belongs to the channel/show. Existing episode artwork continues to come
from each article's HTTPS Open Graph/Twitter preview URL. Feed art, episode art,
and narrated image descriptions are three separate uses with separate policies.

Keep macOS 27.0, native Swift/Apple frameworks, the pinned native dependencies,
one inference worker per app, shared admission/Libro priority, and existing
Kokoro/Soprano engine behavior. Do not normalize, level, limit, compress dynamics,
apply gain, or introduce volume-adjustment metadata. WAV keeps original Float32
samples; the selected AAC profile stays 64 kbps/24 kHz. Preserve private data,
source blocks/provenance, installed settings, existing recordings and remote files.

Existing Delivery B operator gate B06 remains open. Its unreported checks do not
become accepted merely because the next feature stages are approved or built.

## Baseline before this increment

- AudioOutput already exports WAV, M4A, M4B and MP3. AtomicAudioWriter closes the
  encoder, synchronizes same-directory scratch, then atomically publishes it.
  There is no artwork input or general metadata-writing step today.
- MP3 already uses the pinned bundled LAME library. Its header exposes album-art
  and ID3 tag APIs. The existing seek/gapless-frame rewrite starts at offset zero;
  introducing a leading ID3 tag requires correcting that offset.
- VoiceRelay Feed.swift emits per-item itunes:image from Episode.artworkURL.
  RemoteChannel/DeliverySettings do not currently hold user-selected show art.
  Publication hashing and feed readback already exist and must cover new art.
- SemanticDocument has typed blocks, headings, resource paths, PDF page/layout
  evidence and mapped narration omissions, but no document-outline model.
- EPUB intake already resolves package/spine/resources and explicit note links.
  HTML intake already retains footnote definitions/references. The narration
  planner has a current note-placement policy; this is an extension, not a second
  parser or another speech frontend.

## Ownership and dependencies

| Owner | New responsibility |
| --- | --- |
| NarrationCore | Optional authored outline/source destinations; explicit semantic roles and narration policy; mapped heading/note decisions |
| DocumentProcessing | EPUB navigation/cover resource discovery, PDF bookmarks and HTML/Markdown heading destinations; bounded source extraction |
| AudioOutput | Bounded artwork preparation and format capabilities; embedded cover metadata and transactional finalization |
| ProcessingPipeline | Immutable export-art selection; separate packaging identity; progress, cancellation and reuse of valid speech |
| NarrationUI | Shared narration-policy controls and reusable cover-selection presentation where both apps need it |
| Libro / LibroCore | Per-document cover selection and persistence, bulk apply by explicit user action, outline navigation and export workflow |
| VoiceRelay core/app | Channel-art ownership, Publishing Settings, destination-aware upload/readback/RSS publication, recovery/backup integration |
| AppPresentation | Existing generic typography, Settings layout, notices and accessibility only |

No new package or target is initially required. Keep the imported-art value and
ImageIO preparation in AudioOutput. DocumentProcessing returns bounded source
resource bytes/type/provenance for an EPUB cover; the caller passes them to
AudioOutput. Do not add an AudioOutput dependency to DocumentProcessing or place
image blobs in speech IPC. Revisit extraction only if a second real consumer
requires a different dependency boundary.

## Implemented stages and gates

### CA0 — Contracts and compatibility probes

- [x] Confirm export capability policy: embedded covers for MP3, M4A and M4B;
  WAV has no cover option in the initial supported contract because portable
  player support is insufficient. Do not describe WAV as incapable of all tags.
- [x] Prototype standard AVFoundation artwork metadata on AAC using passthrough
  export or another supported native container path. Verify the installed SDK's
  supported combinations for both M4A and M4B, not just the filename extension.
- [x] Probe the pinned LAME ID3 album-art APIs and metadata-size limits. Select
  its supported tag path rather than implementing an ID3 serializer.
- [x] Prove metadata insertion preserves encoded AAC packets/timing and MP3
  frames/seek information with independent inspection; full decoded comparisons
  supplement packet checks. No second lossy encode may be hidden in tagging.
- [x] Record concrete input-byte, pixel, decoded-memory and output-byte limits
  after those probes. These are enforced limits, not unlimited image loading.

Gate: tiny synthetic artwork/audio fixtures establish the actual native tagging
route. If a supported export route cannot preserve audio, revise the design
before product wiring; do not silently drop a requested cover or re-encode audio.

### CA1 — Shared artwork preparation and transactional tagging

- [x] Add optional cover metadata and explicit format-capability contracts.
  Old callers and persisted data decode with no cover and retain current output.
- [x] Use ImageIO/CoreGraphics for bounded JPEG/PNG intake, orientation, thumbnail
  downsampling and sRGB conversion. Inspect dimensions before raster allocation;
  reject corrupt, excessive or unsupported input. Strip unrelated EXIF/GPS and
  source paths from the prepared derivative. Keep original artwork files intact.
- [x] Support book-cover aspect ratios. Do not force portrait Libro covers into
  podcast squares. Prepare small UI thumbnails separately from embedded images.
- [x] Add the native AAC artwork finalizer and LAME ID3 front-cover support.
  Account for ID3 length when updating LAME's seek/gapless frame; verify one cover,
  correct MIME/type, and intact seek information.
- [x] Finish tagging inside the existing atomic publication transaction. Validate
  cover readback, media format/duration and cancellation before the final rename.
  Failure keeps any previous destination intact and reports an export failure.
- [x] Separate acoustic identity from packaging identity. Artwork changes must
  invalidate final packaging/hash proofs, not pronunciation/prepared speech or
  otherwise reusable completed speech chunks. Compute final byte hashes/sizes
  only after all tags are finalized. Include cover digests in resume decisions.
- [x] Expose real finalization progress, using an indeterminate phase when there
  is no measurable denominator. Keep work off the UI actor and outside GPU leases
  where the existing ownership contract permits it.

Gate: AudioOutput/ProcessingPipeline fixtures cover all supported formats, nil
cover compatibility, large/corrupt images, cancellation, tag errors, replacement
safety, packet preservation and MP3 seeking. No new codec dependency by default.

### CA2 — Libro export cover workflow

- [x] Add a Cover Art control beside document output options: thumbnail, Choose,
  Replace and Remove. Selection is per document; multi-selection may explicitly
  apply one image to selected documents. Never leak one book's cover to the next.
- [x] Show the control for metadata-capable output formats. Preserve a document's
  choice when switching to WAV, explain that it is not embedded there, and use it
  again if the user switches back to a supported format.
- [x] Import a validated, bounded derivative into app-owned persistent storage
  instead of depending on the chosen file remaining available. Persist a reference
  and digest, with explicit cleanup limited to unreferenced app-owned assets.
- [x] Freeze the cover choice when a batch starts, like its other export inputs.
  Changes affect subsequent exports. Requested artwork that becomes unavailable
  fails that export clearly; it must not disappear silently.
- [x] Cover changes apply to new or explicitly replaced exports. Do not modify
  existing finished files in the background. Honor current replace/collision rules.

Gate: LibroCore fixtures cover per-document/bulk selection, restart, moved source
images, format switching, batch snapshots and replacement safety. Operator checks
Finder/Quick Look and player artwork/seek behavior for MP3, M4A and M4B.

### CA3 — VoiceRelay podcast show cover

- [x] Add Podcast Cover in Publishing Settings, near channel title/description,
  with thumbnail, Choose/Replace/Remove and validation status. Selection stages
  locally; publication follows the existing enabled/destination/restore gates.
- [x] Use a distinct podcast preparation profile: square JPEG/PNG, opaque RGB,
  1400–3000 pixels per side for RSS compatibility; prefer 3000 when the source
  supports it. Request suitable source art rather than silently cropping or
  stretching it. Show a clear error for unsuitable size/aspect/transparency.
- [x] Store the bounded derivative durably with a content digest. Because current
  library backups exclude preferences, explicitly document its configuration
  ownership: initially exclude the channel-art asset with Publishing preferences;
  a library restore keeps the current channel-art configuration. Missing assets
  remain recoverable through Replace/Remove, never an unannounced feed change.
- [x] Extend delivery with a distinct artwork resource and destination-specific
  proof. Upload under an app-owned content-addressed artwork path using existing
  authenticated transport. Confirm bytes before referencing it in RSS. A changed
  image gets a different URL to avoid stale caches. Art does not use audio proofs.
- [x] Emit channel-level itunes:image, plus a compatible standard RSS image entry
  with dimensions within the RSS specification. Keep per-item itunes:image and
  automatic article preview discovery unchanged; do not embed show art in episode
  audio or download/rehost existing external episode images in this stage.
- [x] Include the selected/confirmed art digest and URL in publication identity.
  Artwork-only changes must publish without regenerating/re-uploading episode
  audio or changing episode GUIDs, dates, ordering or membership.
- [x] Publish the new feed only after matching art confirmation; read back the
  feed through existing integrity checks. A failed pending art change preserves
  the last confirmed cover/feed and remains a visible retryable publication issue.
  Recheck desired selection/destination generation before commit to prevent races.
- [x] Handle replacement, removal, destination changes and reconciliation without
  losing confirmed channel art. Distinguish never configured, explicit removal,
  locally unavailable and remote-only recovered art. Preserve old remote artwork
  files initially; no orphan scan or old-host cleanup is introduced.

Gate: mocked transport covers upload/feed ordering, missing/readback-corrupt art,
retry, removal, settings races, restored/legacy settings, destination changes and
channel-versus-episode XML. Live upload and podcast-cache behavior are operator
checks, not effects of automated tests. Missing episode artwork stays nonfatal.

### DN1 — Authored document outlines and navigation

- [x] Add optional outline metadata with stable IDs, labels, hierarchy, provenance
  and resolvable source destinations. Use bounded depth/item counts and nil
  defaults for older records. Unresolved entries are unavailable with a notice,
  never guessed into a different section.
- [x] Read EPUB 3 nav TOC and EPUB 2 NCX through existing ZIP/XML/HTML adapters;
  map resource fragments to retained source positions. Prefer authoritative nav
  when both exist. Retain spine reading order; do not append linked non-spine
  chapters or synthesize spoken headings from TOC labels.
- [x] Read PDFKit bookmarks/outlines and map page/position destinations with honest
  precision. A page destination may navigate to a page without claiming an exact
  paragraph or an audio chapter boundary.
- [x] Use existing HTML/Markdown heading structure. Retain source anchor identity
  where needed. Plaintext gets no speculative chapter classifier in this stage.
- [x] Add outline navigation to Libro's existing document/narration preview and
  the corresponding VoiceRelay article preview when an outline is present.
  Keep display/navigation separate from speech order and generation selection.
- [x] Discover explicitly declared EPUB 3 cover-image / EPUB 2 cover metadata as
  an optional Libro cover candidate, using the same archive/image limits. Manual
  art wins; Use Book Cover is explicit. No first-page PDF cover guess or network
  cover search. Unsupported SVG covers remain unavailable unless a bounded native
  rendering route is established; ordinary document intake must still succeed.

Gate: nav-only EPUB 3, EPUB 2 NCX, fragments, duplicate/missing IDs, malformed and
oversized trees, non-spine links, PDF page-only destinations and nested headings.
Navigation metadata alone must not change narration or acoustic identity.

### DN2 — Local duplicate-heading decisions

- [x] Suppress only duplicate announcements proven to refer to the same source
  destination or adjacent duplicated structural heading. Repeated wording in
  separate chapters, running prose, quoted text or distinct destinations remains.
- [x] Keep navigation labels out of spoken content rather than reading them and
  deleting a second copy afterward. Deduplication concerns actual source repeats.
- [x] Retain original source blocks and expose every speech omission with mapped
  provenance/reason in previews. Use the current projection/omission mechanism.
- [x] Version the changed narration policy and preserve compatible unchanged
  chunks. Do not silently revise previously finished/published recordings.

Gate: positive structural duplicates and adversarial equal-text headings across
chapters, repeated headings separated by prose and TOC/body title pairs.

### DN3 — Explicit note and auxiliary narration controls

- [x] Distinguish footnotes/endnotes, bibliography entries and auxiliary sections
  from reliable source markup. Review the existing doc-biblioentry-to-footnote
  classification before exposing choices; ambiguous PDF prose stays unclassified.
- [x] Add shared typed policy/UI: Notes = Current Placement / End of Document /
  Omit, plus Include Auxiliary Sections for explicitly marked auxiliary content.
  Retain current behavior by default, including existing note cues and unreferenced
  note handling. Each app owns its preference persistence; unlike pronunciation,
  these choices are not automatically shared across apps.
- [x] Do not equate an EPUB non-linear spine flag with a bibliography or an
  instruction to discard text. Define exact eligible roles and preserve uncertain
  material. Bibliographies are not silently controlled by the Notes selection.
- [x] Freeze policy into batch/queue inputs and checkpoint identities. Preserve
  source/reference maps and preview reordered/omitted content before generation.
  Changes affect future work; never regenerate published episodes automatically.
- [x] Keep authored captions, legal/license notices and generated image-description
  preference separate. Do not offer an apparently comprehensive control when the
  source did not provide reliable classification.

Gate: linked/unlinked/repeated/cyclic note references, unresolved targets,
explanatory notes versus bibliography, explicit auxiliary sections, old settings,
policy changes during queued work and faithful preview/source mapping.

### SF1 — Bounded spoken-form improvements alongside these stages

- [x] Add each abbreviation, range or dimension rule only with a reproducible
  positive example and negative/context-ambiguous counterexamples. Reuse the
  mapped normalizer and current pronunciation dictionary/precedence contracts.
- [x] Preserve accepted letter-A, numeric correctness, 1.0x cadence and both
  engine-specific frontend contracts. Expand the offline US/GB fixtures and make
  matched clips only for changed audible behavior.
- [x] No global homograph replacement, invented number expansion, generative
  paraphrase or automatic OCR spelling repair in this increment. New examples
  may justify separate bounded rules; a missing example is not a test failure.

Gate: focused projection/phoneme/source-map regressions, full affected suites,
operator listening for new audible changes. No arbitrary dictionary expansion
solely to make this stage appear complete.

## Implementation decisions and evidence

- Shared input limits: 20 MiB encoded input, 40 million source pixels and 16,000
  pixels per dimension. ImageIO thumbnails cap book output at 1200 pixels and
  120 KiB (within pinned LAME's 128 KiB art limit), and podcast output at 3000
  pixels and 2 MiB. Small images are not enlarged. App-owned podcast raster output
  is at most 3000 x 3000 RGB pixels; these budgets are not a hard cap on framework
  or whole-process memory. Imported image metadata and original paths are stripped.
- JPEG/PNG input is supported. Podcast alpha channels and non-square/undersized
  art are rejected clearly. Book derivatives flatten transparency onto white and
  retain their aspect ratio. Prepared derivatives load without another JPEG encode.
- MP3 uses LAME's ID3 API with a recorded one-byte APIC Front Cover patch,
  writes one leading front-cover tag and adjusts the seek
  frame's file offset. M4A/M4B use AVFoundation passthrough and read back the cover
  before atomic publication. Independent Core Audio packet comparisons and decoded
  Float32 bit comparisons prove AAC metadata insertion does not re-encode speech;
  MP3 packet equality, duration and seek tests also pass.
- Libro stores per-source cover references, supports explicit multi-selection and
  Use Book Cover for declared EPUB JPEG/PNG covers, freezes in-memory export
  inputs and joins cover work on Quit. Remove cleans only unreferenced canonical
  derivatives whose bytes match their filenames; unrelated files and links remain.
- VoiceRelay keeps art in Publishing configuration, separately from episode art
  and library backups. Each changed feed verifies the full show image and a small
  RSS thumbnail at the current destination before feed publication. There is no
  separate cached artwork-proof schema: byte readback is repeated when publishing
  a feed. Existing audio/GUIDs are not repackaged for a cover change. Remote-only
  channel artwork survives recovery; explicit Remove is distinct from no setting.
  Old remote artwork files remain. Channel-only lookup avoids revalidating all
  episode XML when constructing a candidate feed.
- Outlines are bounded to 4096 entries and 32 levels. EPUB fragments map to retained
  source anchors; PDF bookmarks keep page precision. Invalid/oversized optional
  outlines abstain with a warning and retain prose. Image-description insertion
  shifts affected outline block destinations. Contents navigates original source,
  independently of speech order; it does not create audio chapters.
- Duplicate heading decisions stay local, preserve distinct anchors/resources and
  retain source spans. Notes default to Current Placement; End of Document/Omit
  and Include auxiliary sections affect future batches/new queue captures. Explicit
  bibliography semantics are distinct from note definitions and remain narrated.
  Controls and metadata never enter acoustic identity. The existing compatible
  chunk identity is retained through narration/extraction metadata upgrades.
  Queue preview windows also use the job's captured profile rather than newly
  edited preferences, while retaining the existing URL-based preview workflow.

Automated evidence is consolidated in [current status](IMPLEMENTATION_STATUS.md).
The synthetic operator fixture directory is `.build/cover-navigation/fixtures`:
`navigation-and-notes.epub`, `outline.md`, portrait/square covers, an invalid alpha
cover, expected narration text for three policies and `validation.json`. These
are private generated artifacts, not shipped samples or maintained product tools.
Use [L17–L19 and V17–V19](OPERATOR_VALIDATION.md) for acceptance; no checkbox there
was marked passed by engineering tests.

## Later candidates after these increments

Chapter-split output and M4B chapter markers build on DN1, but require a separate
decision on one-file versus per-chapter output, chapter precision, naming,
partial-book recovery and player compatibility. M4B cover support in CA1–CA2 does
not imply chapter support.

Caption/sidebar scheduling and complex-column reconstruction need representative
failing documents and reliable associations. Evaluate existing PDFKit/Vision
structure first; do not add custom layout ML or speculative source reordering.
Broader boilerplate/figure-label suppression and contextual homograph/OCR repair
remain separately justified work. Existing caption deduplication stays active;
it is not a new unimplemented feature.

## Validation, delivery and documentation

For each implemented increment, run the smallest meaningful isolated regressions
first. At integration boundaries run Libro's bash scripts/check.sh, affected
VoiceRelay core/app suites and both Release builds. Verify packaged ad-hoc signing
and codec/helper embedding where changed. Report counts/skips and evidence paths;
do not substitute successful builds for GUI, listening or service acceptance.

Use synthetic covers/audio/documents and fake transport. Include a large-image
memory/cancellation check, metadata readback and encoded-media preservation checks.
Exercise full decode and seeking without FFmpeg or a new external tool dependency.
Keep model, speech and art workloads bounded; do not start another inference worker.

When implementation lands, add new cases to the existing consolidated
[operator checklist](OPERATOR_VALIDATION.md), grouped by app. Do not create a
second competing checklist or mark B06 and earlier unreported checks accepted.
Libro checks include choose/remove/relaunch, bulk selection, each tagged format,
preview navigation, omissions and replacement failure. VoiceRelay checks include
feed cover replace/remove/retry, unchanged episode art, metadata-only publication,
destination changes and real podcast display/cache behavior. Live checks remain
operator-owned.

Update architecture, status, intake, Settings ownership and relevant app Help
when behavior ships. Retire replaced adapters/tests/docs after equivalent shared
coverage passes, while preserving historical evidence and unrelated work. No
public distribution release, live upload, cache reset or Git commit was performed by this increment.

## References checked for this plan

- [Apple show-cover specifications](https://podcasters.apple.com/support/5514-show-cover-template):
  square RSS art 1400–3000 pixels, JPEG/PNG, no alpha.
- [Apple podcast RSS guide](https://help.apple.com/itc/podcasts_connect/en.lproj/itcb54353390.html):
  channel artwork uses itunes:image and RGB image files; standard RSS image has
  different requirements and must be validated separately.
- [RSS 2.0 image specification](https://www.rssboard.org/rss-specification#ltimagegtSubelementOfLtchannelgt):
  standard image dimensions differ from podcast show-cover pixel dimensions.
- [AVFoundation artwork identifier](https://developer.apple.com/documentation/avfoundation/avmetadataidentifier/commonidentifierartwork)
  and [passthrough export](https://developer.apple.com/documentation/avfoundation/avassetexportpresetpassthrough):
  establish the native route; actual M4A/M4B behavior is a CA0 fixture gate.
- [LAME public API](https://github.com/lameproject/lame/blob/master/include/lame.h):
  use the installed pinned header/API for implementation, not an unpinned upgrade.
- [EPUB 3.3](https://www.w3.org/TR/epub-33/): navigation, resource fragments,
  cover-image declaration and spine semantics.
- [PDFKit outlineRoot](https://developer.apple.com/documentation/pdfkit/pdfdocument/outlineroot):
  consume authored PDF bookmarks before considering inferred document structure.
