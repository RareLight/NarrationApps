# Native validation

The operator confirmed on October 16, 2026 that both relocated apps build and run.
This accepts the basic workspace/build/launch smoke check; detailed document,
listening, setup, persistence and live-service cases below remain separate.

Use isolated synthetic fixtures, native Swift tests and Xcode builds. Prior
implementation results and retired commands are preserved in Git history and the
[shared status](../../docs/IMPLEMENTATION_STATUS.md). Root
[development gates](../../docs/DEVELOPMENT.md) provide the coordinated entry points.

```sh
bash ../swift-packages/scripts/check.sh
NARRATION_FIXTURE_WORKER="$PWD/../swift-packages/.build/debug/NarrationFixtureWorker" \
  swift test --disable-sandbox --no-parallel --jobs 4
bash scripts/check-packaging.sh
bash scripts/check-docs.sh
```

Packaging fixtures use fake build/copy/sign tools and native Swift atomic exchange;
they neither sign, launch nor install an app. The suite uses supplied transports
and storage and does not access Safari, Keychain or live servers. Native model
checks are separate and use explicitly prepared local assets.

Release/Archive must embed VoiceRelaySpeechWorker and its Metal library, omit Python
and retired executables, and pass code-signature/resource verification. Validate
actual models offline, one-worker session reuse and interactive/background admission, cancellation/reaping and sampled
parent/helper memory separately. Audio regressions check exact Float32 values,
current-file integrity, resampling/rate/gaps, atomic output preservation and native
AAC absolute quiet/loud levels without normalization or volume leveling.

The remaining operator tests, current app paths and reporting IDs are maintained
only in the [consolidated checklist](../../docs/OPERATOR_VALIDATION.md#voicerelay).
It covers setup, samples/pronunciation, real source/OCR/image quality, lifecycle,
live Publishing/Keychain, restore and conditional distribution. Historical results
remain in Git history; automated passes do not
mark operator acceptance complete.

The latest accepted-policy results and current artifacts are maintained in the
[shared status](../../docs/IMPLEMENTATION_STATUS.md). Earlier stage counts describe
their own revisions, not today's suite totals. Documentation refreshes are not
new app acceptance. Delivery A listening/letter A is operator accepted; unreported
preview and Delivery B B06 checks remain separate. See
[Delivery A evidence](../../docs/TEXT_PROCESSING_IMPROVEMENT_PLAN.md#delivery-a-evidence).

Cover/navigation engineering is recorded in the shared current status. Validate
Podcast Cover and unchanged per-episode images through V17, Contents through V18,
and captured note/auxiliary settings through V19. Library backup excludes the
Publishing cover/configuration. Automated artwork transport tests never upload to
your real server; use the normal team-signed build and a disposable destination
for Keychain, feed publication and podcast-cache acceptance.
