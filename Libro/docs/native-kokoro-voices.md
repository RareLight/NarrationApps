# Libro voice selection

New native settings use **Heart (`af_heart`) at 1.0×**, with the operator-accepted
longform pause profile. Existing explicit voice/speed settings and active jobs are
preserved. Libro presents 28 English Kokoro voices plus Soprano's single voice;
VoiceRelay presents its smaller supported Kokoro subset.

Names, overall grades, ranking and recommendations are owned by shared
`NativeSpeech.VoiceCatalogPresentation`. This is bundled metadata from the recorded
upstream VOICES.md revision, not a live web lookup or a guarantee of listening quality.
Equal grades sort alphabetically; unknown available IDs remain selectable last.
Libro recommends Heart, Bella, Emma and Nicole, uses friendly names/stars and keeps
the actual voice ID in requests. No normalization or gain is used to make voices match.

The accepted Heart/Michael/Emma comparisons, exact profile and final sample
provenance are in [the longform record](../../docs/KOKORO_LONGFORM_IMPLEMENTATION.md).
All 29 current samples use the common phrase selected after listening; they do not
introduce each voice by name. Samples play at recorded 1.0× without a model and do
not apply current speed/dictionary edits. Pronunciation Play is a separate live render.
See [shared samples](../../docs/VOICE_SAMPLES.md) and
[pronunciation](../../docs/PRONUNCIATION.md).

Current manual checks are L03/L09 in the
[consolidated checklist](../../docs/OPERATOR_VALIDATION.md#libro).
The earlier ranking report is retained in Git history; its 1.1× default is retired.
