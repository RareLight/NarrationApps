# VoiceRelay validation

Reviewed October 21, 2026. VoiceRelay includes the shared narration policies,
optional login startup, background-safe credential reads, default podcast cover,
source/queue workflows, outbox and server reconciliation. Behavior and limits are
in the [user guide](USER_GUIDE.md) and [architecture](ARCHITECTURE.md).

## Automated evidence

The latest recorded product gate is the October 20 monorepo validation: full shared
and app fixtures, combined Debug/Release builds and all four bundle audits passed.
[Migration validation](../../docs/MONOREPO_MIGRATION.md#validation) records the source,
evidence and command-local Metal selection. Later documentation checks are not new
app builds, live-service tests or operator signoff.

From the NarrationApps root, after explicit dependency setup:

```sh
bash scripts/check.sh --tier quick --scope voicerelay
```

Use `bash scripts/check.sh` for all coordinated fixtures. The
[contributor guide](../CONTRIBUTING.md) documents direct app commands; the root
[development guide](../../docs/DEVELOPMENT.md) owns tiers and opt-in native checks.

Fixtures use isolated stores, fake transports/credentials and synthetic speech
workers. Packaging fixtures inject fake build/copy/sign tools; they do not sign,
install or launch the app. Bundle audits verify actual generated resources and
signatures and probe the packaged Metal helper, but do not contact a real server.
Offline native speech with prepared models is a separate explicit gate.

## Manual acceptance and candidates

The [operator checklist](../../docs/OPERATOR_VALIDATION.md#voicerelay) owns V01–V20,
shared B01–B08 and conditional distribution checks. Use a consistently normal-signed
build for Keychain, provisioning and live Publishing. Ad-hoc signatures cannot
establish those behaviors. The October 16 launch/build smoke and accepted Delivery A
listening do not close unreported service, UI, source-quality, restore or reboot checks.

The latest automated bundles are under
`.build/MonorepoValidation/Build/Products/{Debug,Release}/VoiceRelay.app` relative to
NarrationApps. Select the operator candidate explicitly and preserve earlier bundles
already under review; local generated products are not guaranteed in a fresh clone.
Do not treat an old per-feature path or historical test count as today's release.

Podcast-cover publication, per-episode images, Contents and captured narration
choices are covered by V17–V19. Library backup excludes Publishing artwork/configuration.
Restoration must use a disposable test library, never the live one. The
[release checklist](RELEASE_CHECKLIST.md) separates engineering artifacts from
account, clean-Mac, notarization and public distribution acceptance.
