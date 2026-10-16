# Libro validation

The operator confirmed on October 16, 2026 that both relocated apps build and run.
This accepts the basic workspace/build/launch smoke check; detailed document,
listening, setup, persistence and live-service cases below remain separate.

The latest accepted-policy automated evidence is maintained once in the
[shared current status](../../docs/IMPLEMENTATION_STATUS.md) and
[longform implementation record](../../docs/KOKORO_LONGFORM_IMPLEMENTATION.md).
It covers shared/AppPresentation and LibroCore fixtures, actual native offline
workers, Float32 fidelity, complete ad-hoc archives/resources and cross-app arbitration.

From Libro, run `bash scripts/check.sh` for the required isolated regression
gate. Prepare sources with `bash macos/scripts/prepare-dependencies.sh`; build/Archive
with `macos/scripts/build.sh` and `LIBRO_CONFIGURATION=Release` for Release checks.
The test suite does not operate the GUI, private documents or signing accounts.

The [consolidated checklist](../../docs/OPERATOR_VALIDATION.md#libro)
is the only manual test list: L01–L19 for Libro, B01–B06 for shared behavior and
conditional installation/distribution checks. The earlier A/B profile choice is
complete; final GUI/playback, OCR/caption quality and the original private
12-page PDF/600-word Markdown memory retest remain operator-owned. Synthetic
measurements and compiled fixtures are not those acceptances.

For package-resolution and diagnostic steps use [troubleshooting](TROUBLESHOOTING.md).
Older paths/counts and retired worker modes are [historical evidence](README.md#current-and-historical-records),
not current release candidates. Documentation-only checks do not constitute a new
app build or operator signoff. Current EPUB/encoding fixture, build and offline
render evidence is in the shared status; L15/L16 cover its remaining operator checks.

Delivery A mapped-spoken-form and preview validation is ready for operator B05;
[the shared plan](../../docs/TEXT_PROCESSING_IMPROVEMENT_PLAN.md#delivery-a-evidence)
records current gates, costs and listening artifacts. Delivery B remains gated.

The cover/navigation increment adds L17–L19: per-document export art, authored
Contents/source navigation and explicit note/auxiliary controls. Synthetic fixtures
and expected narration previews are in swift-packages/.build/cover-navigation/fixtures.
Packet/Float32 preservation, source-map and isolated workflow tests are engineering
evidence; real-player cover display/seeking, GUI and actual-book listening remain
operator checks.

When checking L17, confirm the empty-selection hint points to cover art and WAV
explains which formats support it. The existing-output confirmation should list
the conflicting output filenames; Cancel must leave those files untouched.
