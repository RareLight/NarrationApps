# Libro validation

See the [user guide](../README.md) for current behavior and
[implementation status](../../docs/IMPLEMENTATION_STATUS.md) for dated test and
build evidence.

## Automated evidence

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

Follow the [operator checklist](../../docs/OPERATOR_VALIDATION.md#libro) for build
selection and manual checks. Build the **Libro** scheme in `NarrationApps.xcworkspace`
with your normal signing configuration. Use the shared chapters and pronunciation
cases for those features. Historical engineering builds and their tested source
snapshots are recorded in [implementation status](../../docs/IMPLEMENTATION_STATUS.md).
Use [troubleshooting](TROUBLESHOOTING.md) for package, model and output errors.
