# Libro troubleshooting

Use the current project and the sibling `swift-packages` checkout. This is operating
guidance; earlier Metal/build/memory investigations are clearly labeled in
[history](README.md#current-and-historical-records).

## Missing Xcode package products

If the error also says a package is “already opened from another project or
workspace”, close standalone Libro/VoiceRelay and package windows, then open
[the combined NarrationApps workspace](../../NarrationApps.xcworkspace).
Use the per-app schemes there for both Debug and Release. See
[workspace setup](../../docs/PACKAGE_BOUNDARIES.md#develop-both-apps-in-one-xcode-workspace).
This is a local-package ownership conflict in Xcode, not an app runtime lock or a
reason to reinstall Xcode/delete dependencies.

For a standalone Libro project without that ownership conflict:

Save work and quit Xcode completely. From the Libro root:

```sh
bash macos/scripts/resolve-xcode-packages.sh
```

Reopen `macos/Libro/Libro.xcodeproj` and build the Libro scheme. The resolver prepares
pinned sources and refreshes Xcode's default package workspace without deleting
models. The build script uses its own repo-local DerivedData/SourcePackages, so a
successful script build alone does not reload an already-open GUI package graph.
If errors remain, inspect the first package-resolution error before the summary
“Missing package product” messages. Do not copy build/dependency workspace state
between Macs or remove active package checkouts while Xcode is using them.

## Model setup and speech failures

Use Models → Choose Existing Models or Install Speech Model explicitly, then Check
Speech Setup offline. Installation is distinct from the bundled helper/Metal check.
British voices require their own pinned resources; select the voice and install/
update if requested. No implicit download, US fallback or alternate engine replay
occurs. Existing models/settings/finished output should not be deleted to diagnose
an installation problem. Source pins/patches are maintained in the
[shared dependency record](../../docs/DEPENDENCIES.md).

The preparation stage can reject unsupported/overlong text explicitly rather than
silently truncating it. Combined unit/temperature and some homograph readings
are [known frontend defects](../../docs/TEXT_NORMALIZATION_RESEARCH.md),
not a reason to change accepted pacing or normalize audio levels.

Contents pages with dotted leaders exposed a native subtoken-range bug fixed on
October 15: repeated punctuation inherited overlapping source ranges and was
rejected before speech. Rebuild the complete app/helper from current sources and
make a new Archive/export; earlier `accepted/` copies predate the correction.
Do not edit the book or delete its models to work around this failure. Whole-book
preparation and the formerly failing M4B passage passed with both rebuilt helpers;
full-book GUI generation/listening remains an operator check.

## Memory or responsiveness

Observe Libro and LibroSpeechWorker separately; note the input type/size, phase,
memory pressure and whether it settles after completion/Stop. For a true UI freeze,
capture Activity Monitor's Sample Process for the affected process. Keep private
inputs/logs local. Model allocator thresholds and sampled worker limits are not hard
caps; Apple OCR/Intelligence can also allocate in system services. The synthetic
mixed-input measurements are in [current status](../../docs/IMPLEMENTATION_STATUS.md);
they do not close the original private-document GUI retest.

## Diagnostics and output safety

Troubleshooting provides Check Embedded Helper and optional workspace logging.
Logging is off by default, private and local: `models/.native/diagnostics/debug.log`,
rotating to `debug.previous.log` at 1 MiB. Dependency stderr may contain document
text/paths; review before sharing. Copy/Open/Reveal/Clear operate on these owned
files, with idle/busy controls. No automatic diagnostic upload occurs.

Use a separate output folder for reproductions. Resolve name collisions or missing
remembered destinations through the normal GUI; failures/replacement cancellation
must preserve completed files. Report the checklist ID, app/model, input alias,
phase and sanitized error. Normal team signing/public distribution acceptance is
separate from local ad-hoc archive verification.
