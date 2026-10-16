# VoiceRelay 1.0 release checklist

This is the engineering/distribution gate, separate from the
[consolidated app validation checklist](../../docs/OPERATOR_VALIDATION.md).
Verify the version/build of the actual candidate; this document does not authorize
publishing, notarization, developer-account operations or live state changes.

## Source and automated gates

- [ ] Review [current shared status](../../docs/IMPLEMENTATION_STATUS.md), operator results and remaining accepted issues.
- [ ] Run the [contributor regression commands](../CONTRIBUTING.md#prerequisites-and-safe-checks).
- [ ] Build Debug and Release in Xcode; verify all app sources/resources and runtime pins.
- [ ] Inspect the candidate's Git changes/history for private URLs, source content,
      credentials, diagnostics and generated artifacts. Retain LICENSE and notices.
- [ ] Confirm Package.swift and both Package.resolved files agree; no incidental downloads.
- [ ] Review README, Help, beta checks and current validation for the candidate behavior.

## Operator acceptance

Complete and record VoiceRelay V01–V16, shared B01–B04 and applicable D01–D02
from the [single operator checklist](../../docs/OPERATOR_VALIDATION.md#voicerelay).
Operator results are separate from fixture/build/signature evidence.

## Distribution and signing decision

- [ ] Choose development-only delivery or distribution to other users. Existing Apple
      Development signing is not a completed public distribution workflow.
- [ ] Keep the bundle identifier and Keychain entitlement stable. Validate the chosen
      provisioning/signing policy with a clean account/device; do not change user
      presence requirements or access groups to bypass signing problems.
- [ ] For outside-App-Store distribution, prepare Developer ID signing and notarization
      with the appropriate account/certificate/profile. Confirm hardened runtime and
      necessary entitlements against the actual candidate and its nested code.
      Follow Apple's [distribution signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
      and [notarization guidance](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
- [ ] Validate third-party redistribution rights before bundling tools/models; currently
      explicit installation downloads assets and build/startup do not.
- [ ] Choose archive/update delivery and retain a known-good rollback artifact privately.

## Candidate packaging

- [ ] Assign an approved marketing version/build number in Packaging/Info.plist.
      Keep build numbers increasing; verify the packaged Info.plist, not only project UI.
- [ ] Package with `bash scripts/build-app.sh release`. It stages the new bundle,
      verifies nested signatures and exchanges the existing package atomically.
      Copy/verification failures must leave the previous package intact.
- [ ] Inspect entitlements and signature without launching:

      ```sh
      codesign --verify --deep --strict dist/VoiceRelay.app
      codesign --display --entitlements - dist/VoiceRelay.app
      /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/VoiceRelay.app/Contents/Info.plist
      /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' dist/VoiceRelay.app/Contents/Info.plist
      ```

- [ ] For an approved notarized candidate, staple and assess Gatekeeper on a clean
      downloaded copy using Apple's documented workflow. Local build verification
      alone does not establish downloaded-app acceptance.
- [ ] Confirm Acknowledgements/runtime resources are present, obsolete agent files
      are absent, and no private configuration/state is embedded.
- [ ] Record final automated/operator results and explicitly approve the release before upload.
