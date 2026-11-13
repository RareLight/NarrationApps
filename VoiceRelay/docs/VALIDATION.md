# VoiceRelay validation

Behavior and limits are in the [user guide](USER_GUIDE.md) and
[architecture](ARCHITECTURE.md). Dated test and build evidence is in
[implementation status](../../docs/IMPLEMENTATION_STATUS.md).

## Automated evidence

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

Follow the [operator checklist](../../docs/OPERATOR_VALIDATION.md#voicerelay) for
build selection and manual checks. Build the **VoiceRelay** scheme in
`NarrationApps.xcworkspace` with your normal signing configuration for Keychain,
Publishing and VoiceServer testing. Use a disposable library for restore tests.
Use the [release checklist](RELEASE_CHECKLIST.md) for distribution work.
