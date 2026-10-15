# Libro validation

The latest accepted-policy automated evidence is maintained once in the
[shared current status](../../swift-packages/docs/IMPLEMENTATION_STATUS.md) and
[longform implementation record](../../swift-packages/docs/KOKORO_LONGFORM_IMPLEMENTATION.md).
It covers shared/AppPresentation and LibroCore fixtures, actual native offline
workers, Float32 fidelity, complete ad-hoc archives/resources and cross-app arbitration.

From Libro-TTS, run `bash scripts/check.sh` for the required isolated regression
gate. Prepare sources with `bash macos/scripts/prepare-dependencies.sh`; build/Archive
with `macos/scripts/build.sh` and `LIBRO_CONFIGURATION=Release` for Release checks.
The test suite does not operate the GUI, private documents or signing accounts.

The [consolidated checklist](../../swift-packages/docs/OPERATOR_VALIDATION.md#libro)
is the only manual test list: L01–L14 for Libro, B01–B04 for shared behavior and
conditional installation/distribution checks. The earlier A/B profile choice is
complete; final GUI/playback, OCR/caption quality and the original private
12-page PDF/600-word Markdown memory retest remain operator-owned. Synthetic
measurements and compiled fixtures are not those acceptances.

For package-resolution and diagnostic steps use [troubleshooting](TROUBLESHOOTING.md).
Older paths/counts and retired worker modes are [historical evidence](README.md#historical-evidence),
not current release candidates. Documentation-only checks do not constitute a new
app build or operator signoff.
