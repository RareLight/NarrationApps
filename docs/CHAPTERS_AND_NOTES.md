# Chapters and show notes

Libro and VoiceRelay add source-derived chapters and show notes to new recordings
when the output format supports them. They do not change the narrated text,
audio levels, or existing recordings.

## Formats and players

| Output | Chapters | Show notes |
| --- | --- | --- |
| VoiceRelay podcast (M4A) | Embedded QuickTime chapter track | Embedded description and RSS episode description |
| Libro M4A / M4B | Embedded QuickTime chapter track | Embedded description |
| Libro MP3 | ID3 CHAP frames and an ordered table of contents | ID3 comment |
| Libro WAV | Not added | Not added |
| VoiceServer API responses | Unchanged | Not added |

Players decide how to display embedded metadata. In a compatible player, chapter
titles appear in its chapter list and tapping one seeks within the recording.
Overcast documents support for embedded MP3 and M4A chapters. [Overcast podcaster guide](https://overcast.fm/podcasterinfo)

The notes also include readable timecodes as a fallback.
Tappable web links in file descriptions depend on the player. VoiceRelay's RSS
show notes include real HTML bulleted links.

No chapter-specific external links or images are generated. Container roundtrip
fixtures are engineering evidence, not acceptance in Overcast, Apple Books, or
another device player.

## How chapters are selected

- VoiceRelay uses article headings, or the authored outline of a PDF.
- Libro prefers the main authored EPUB contents/PDF outline level, rather than
  every nested subsection. A lone grouping wrapper can be descended to reach its
  chapters. Without an authored outline, the shallowest source headings are used.
- Bookmarks into omitted or unresolved content are skipped. A document without
  usable structure does not receive invented chapters.
- PDF destinations are matched to source text on the destination page when
  possible. Otherwise they mark the first narrated block on that page, not an
  inferred exact position within the page.
- A title/opening marker covers preceding material when needed. Duplicate
  positions are collapsed. More than 255 markers (including an opening marker)
  omit the chapter list rather than silently truncating it; audio still exports.

Times come from the actual rendered audio frames, including resampling and
silence compensation. They are not estimates based on word counts, nor are they
speech-recognized word timings.

Apple's native M4A/M4B header writer can expose the encoder's existing trailing
AAC padding: less than one AAC-LC packet (1,024 samples, about 43 ms at 24 kHz).
It does not synthesize or re-encode audio, and chapter starts are not shifted.
This small end-of-file duration difference is a container limitation.

## Brief on-device summaries

**Generate brief summaries** is enabled by default. In Libro, find it under
**Settings → Document**. In VoiceRelay, open **Settings → General → Document Narration**.

When available, Apple Intelligence creates a summary in the document's language:
one to three sentences, no more than 50 words. The entire source must fit both
limits: **1,500 words and 8,000 UTF-8 bytes**. Larger sources are skipped, rather
than summarized from an opening excerpt. This intentionally means most full-length
books have chapters and links but no generated summary.

There is no cloud fallback or automatic model download. Missing/disabled Apple
Intelligence, refusals, invalid output, and model errors omit the summary without
preventing audio export. Active generation has a 20-second budget after inference
access becomes available. Generated summaries can contain mistakes.

Summaries are metadata only: they are not spoken. Captured results are reused by
checkpoint recovery, rather than regenerated each time work resumes.

## Source links and privacy

Notes list up to 50 unique HTTPS URLs found in the readable source, including
HTML/EPUB links, PDF URL annotations, and links in supported text documents.
Relative web links resolve against the article's final URL. Internal contents and
footnote anchors, unencrypted HTTP links, local file links, executable URL schemes,
and credential-bearing URLs are excluded.

Collecting links does not visit their destinations. Notes are bounded, and source
text is escaped rather than treated as trusted HTML. Links and summaries become
part of the exported recording and, in VoiceRelay, its podcast feed: review the
source before publishing material you do not want subscribers to see.

## Existing work and recovery

These additions apply to newly prepared output. They do not automatically retag,
regenerate, or re-upload completed recordings or remote podcast media. Previously
captured jobs may lack new metadata.

Container metadata is finalized before the output is committed and hashed.
M4A/M4B metadata editing copies compressed audio without transcoding; MP3 tagging
preserves the MPEG audio stream. A tagging failure preserves the previous completed
destination and recoverable work rather than publishing an incomplete recording.
