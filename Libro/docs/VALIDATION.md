# Libro validation

Reviewed October 21, 2026. The current source includes queue transport/reordering,
unpacked EPUB intake, existing-output review, automatic covers, progressive PDF
previews, the Document Settings pane and the shared narration policies. See the
[user guide](../README.md) for visible behavior and
[shared current status](../../docs/IMPLEMENTATION_STATUS.md) for feature state.

## Automated evidence

The latest recorded product gate is the October 20 monorepo validation: the full
isolated suite, combined Debug/Release workspace builds and all four bundle audits
passed. [Migration validation](../../docs/MONOREPO_MIGRATION.md#validation) identifies
the source commit, summaries, signing class and local Metal selection. This page
and later documentation checks do not constitute another product build or GUI pass.

From the NarrationApps root:

```sh
bash scripts/check.sh --tier quick --scope libro
```

Use `bash scripts/check.sh` for the full cross-app fixture gate and
[development gates](../../docs/DEVELOPMENT.md) for filtered/native/release tiers.
The standalone `bash scripts/check.sh` inside `Libro/` also runs the shared/Libro
checks; the working directory changes its scope. Preparation and standalone
build/archive commands are in [the native guide](../macos/README.md).

## Manual acceptance

The [operator checklist](../../docs/OPERATOR_VALIDATION.md#libro) owns L01–L20,
shared B01–B08 and conditional D01/D02. It is the single pending manual list.
The October 16 operator confirmation accepts basic relocated build/launch smoke;
feature, actual-document, listening, accessibility and account checks are separate.
Delivery A listening, including capital-A labels, is accepted; unreported app
preview checks and later PDF/scientific quality checks stay open.

Use a deliberately selected candidate. The latest automated bundles are under
`.build/MonorepoValidation/Build/Products/{Debug,Release}/Libro.app` relative to
NarrationApps. Earlier feature candidates such as TransportFooterValidation,
AutomaticCoverValidation and FlowNarrationValidation are historical local builds;
none is automatically the active operator candidate. Local artifacts may be absent
in a fresh clone. Preserve a bundle already under operator testing.

Automated cover/tagging/source-map tests do not establish real-player cover display,
seeking, GUI layout or correct reading of a book. Full fixtures use synthetic
inputs; private book/preview exports remain outside Git. Use
[troubleshooting](TROUBLESHOOTING.md) for package, model and output errors.
