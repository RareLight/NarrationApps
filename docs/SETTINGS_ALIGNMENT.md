# Settings ownership and shared presentation

Settings alignment is implemented; ownership below was reviewed October 21, 2026.
Implementation-stage evidence is historical; the only current manual tests are in the
[consolidated checklist](OPERATOR_VALIDATION.md).

| Owner | Shared responsibility |
| --- | --- |
| Independent AppPresentation | Semantic typography, 80–200% text sizing/commands, adaptive pane navigation, help, notices and Appearance controls |
| NativeSpeech | Voice names/quality metadata and bundled sample catalog/resources |
| NarrationUI | Speech speed, setup status/actions, sample controls and image-description preference presentation |
| PronunciationUI | Shared dictionary editor and on-demand native pronunciation preview |
| Each app | Preferences, pane inventory, file/source access, active-work gating, scene and playback lifecycle |

Libro has General, Document, Models, Pronunciation and Troubleshooting, in that
order. General owns appearance and completion alerts. Document owns narration text
choices and image descriptions, with short control tooltips and illustrative
document/narration examples that update with each choice. Examples start collapsed
behind **Show example**, whose trailing chevron rotates down when expanded.
Pronunciation remains in its dedicated pane; the shared dictionary list and editing
buttons use a centered 75% of the window width in both apps. The list uses a soft
gray rounded background with native row selection, adapting to light/dark appearance.
Future document text controls belong in Document.
Main-window speech and export choices remain part of its batch workflow; Models owns workspace/install/
offline setup checks and Troubleshooting owns the separate embedded-helper check.
VoiceRelay has General, Pronunciation, Publishing and Troubleshooting; General owns
Speech, Reading List, automation, optional login startup and the default-on timed
episode transcript choice; Publishing owns credentials/destination/channel,
and Troubleshooting owns library backup/review and sanitized session logs.

Common actions use Install Speech Model, Check Speech Setup and Play Sample/Stop
Sample. Installation is explicit; checks initialize offline without playback or
model downloads. A busy/failed/missing state gives a direct reason or recovery action.
Samples play recorded audio and do not preview selected speed or spelling rules.

New Kokoro settings share Heart at 1.0×; valid existing saved values remain intact.
Text-size preferences stay app-owned; the pronunciation dictionary is shared.
The entire pronunciation pane is the single `PronunciationUI.PronunciationSettingsView`
used by both apps, not an app-local copy. Its matching/preservation explanation lives
in the shared AppPresentation ⓘ section-help popover, leaving the editor uncluttered.
Whole Settings panes or sections can be shared views with app-supplied bindings,
preview configuration and action closures; persistence and lifecycle stay app-owned.
Image-description choices affect future preparation, preserve authored ALT/OCR and
do not rewrite existing recordings. Source/Publishing, completion alerts, storage,
backup and diagnostic privacy remain appropriate to each app.

## Cover and document controls

NarrationUI now supplies the common CoverArtworkPicker presentation and typed
NarrationOptionsControls. Both apps call the note setting **Footnotes**,
with **Read with the text / Read at the end / Do not read**, and use **Read appendices
and extra sections**. Libro places these in Document; VoiceRelay keeps them in
General → Document Narration. Only marked sections are affected; unclassified prose
and bibliographies remain included unless citation stripping is selected. Immediately
after Footnotes are **Strip inline citations**
and **Strip endnote citations**, both off by default. See [cleanup rules](DOCUMENT_CLEANUP.md).
Defaults preserve current behavior. Libro persists choices for future
batches; VoiceRelay captures them when adding queue records. These preferences
remain app-specific, unlike the shared pronunciation dictionary.

These controls also offer **Join split words in PDFs (experimental)**, off by
default and captured with future jobs. Both engines use the same source-mapped
PDF rule. English dictionary checks preserve recognized compound hyphens and leave
unknown spellings unchanged; unsupported layouts and non-PDF inputs retain their text.

Libro's per-document Cover Art selection lives with its document queue/export
workflow. VoiceRelay's Podcast Cover lives beside channel details in Publishing.
Both offer Choose/Replace/Remove; validation/storage remain in shared AudioOutput
and app-owned state. Podcast cover import errors are separate from server delivery
errors. AppPresentation remains independent of narration, documents and audio.

## Planned model-selection guidance

The [multi-model integration plan](MULTI_MODEL_TTS_IMPLEMENTATION_PLAN.md#model-selection-guidance-speed-and-quality-meters)
adds common static generation-speed and narration-quality meters, text tiers and
model details to both apps. NativeSpeech will own reviewed generalized guidance;
NarrationUI will own presentation. These are shipped estimates, with no user-system
benchmark, automatic model load or network lookup. Current model/voice controls
have not yet been replaced by this planned UI.
