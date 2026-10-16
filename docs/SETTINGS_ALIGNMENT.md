# Settings ownership and shared presentation

Settings alignment is implemented. The [original stage plan and automated evidence](SETTINGS_ALIGNMENT.md)
are historical; the only current manual tests are in the
[consolidated checklist](OPERATOR_VALIDATION.md).

| Owner | Shared responsibility |
| --- | --- |
| Independent AppPresentation | Semantic typography, 80–200% text sizing/commands, adaptive pane navigation, help, notices and Appearance controls |
| NativeSpeech | Voice names/quality metadata and bundled sample catalog/resources |
| NarrationUI | Speech speed, setup status/actions, sample controls and image-description preference presentation |
| PronunciationUI | Shared dictionary editor and on-demand native pronunciation preview |
| Each app | Preferences, pane inventory, file/source access, active-work gating, scene and playback lifecycle |

Libro has General, Models, Pronunciation and Troubleshooting. Main-window narration
and export choices remain part of its batch workflow; Models owns workspace/install/
offline setup checks and Troubleshooting owns the separate embedded-helper check.
VoiceRelay has General, Pronunciation, Publishing and Troubleshooting; General owns
Speech, Reading List and automation, Publishing owns credentials/destination/channel,
and Troubleshooting owns library backup/review and sanitized session logs.

Common actions use Install Speech Model, Check Speech Setup and Play Sample/Stop
Sample. Installation is explicit; checks initialize offline without playback or
model downloads. A busy/failed/missing state gives a direct reason or recovery action.
Samples play recorded audio and do not preview selected speed or spelling rules.

New Kokoro settings share Heart at 1.0×; valid existing saved values remain intact.
Text-size preferences stay app-owned; the pronunciation dictionary is shared.
Image-description choices affect future preparation, preserve authored ALT/OCR and
do not rewrite existing recordings. Source/Publishing, completion alerts, storage,
backup and diagnostic privacy remain appropriate to each app.

## Cover and document controls

NarrationUI now supplies the common CoverArtworkPicker presentation and typed
NarrationOptionsControls. Both apps call the note setting Notes, with Current
Placement / End of Document / Omit, and use Include auxiliary sections in Document
Narration. Defaults preserve current behavior. Libro persists choices for future
batches; VoiceRelay captures them when adding queue records. These preferences
remain app-specific, unlike the shared pronunciation dictionary.

Libro's per-document Cover Art selection lives with its document queue/export
workflow. VoiceRelay's Podcast Cover lives beside channel details in Publishing.
Both offer Choose/Replace/Remove; validation/storage remain in shared AudioOutput
and app-owned state. Podcast cover import errors are separate from server delivery
errors. AppPresentation remains independent of narration, documents and audio.
