# VoiceRelay 1.0 release checklist

The development version remains 0.1.0 (build 1) until acceptance and distribution
policy are approved. This is a release gate, not permission to publish, notarize,
operate developer accounts or change live state.

## Source and automated gates

- [ ] Complete [final polish](FINAL_POLISH.md) and record remaining accepted issues.
- [ ] Run the [contributor regression commands](../CONTRIBUTING.md#prerequisites-and-safe-checks).
- [ ] Build Debug and Release in Xcode; verify all app sources/resources and runtime pins.
- [ ] Inspect the candidate's Git changes/history for private URLs, source content,
      credentials, diagnostics and generated artifacts. Retain LICENSE and notices.
- [ ] Confirm Package.swift and both Package.resolved files agree; no incidental downloads.
- [ ] Review README, Help, beta checks and current validation for the candidate behavior.

## Operator acceptance

- [ ] Daily unattended discovery → preparation → speech → publishing works with windows closed.
- [ ] Manual Sync overrides automation preferences without changing them; Stop/Quit/relaunch recover correctly.
- [ ] Invalid snapshots and individual sync failures retain actionable rows and allow healthy work.
- [ ] Backup/restore of a private test library shows restored Articles and blocks changes until review.
- [ ] Real Keychain access, cancellation and session reuse work under the chosen stable signing identity.
- [ ] Real server media/feed readback, retries, source removal, local discard and feed-first server deletion pass.
- [ ] Destination edits preserve old-host copies and invalidate old proofs/deletes.
- [ ] Search/filter counts and saved-date ordering survive content removal and reloads.
- [ ] Keyboard, VoiceOver, focus, light/dark, reduced transparency/motion and window/menu behavior pass.
- [ ] Representative article extraction and Overcast listening pass; synthetic fixtures are insufficient.
- [ ] Fresh managed runtime installation and app relocation work on another supported Apple Silicon Mac.
      Confirm python3, uv, ffmpeg and ffprobe prerequisites; no global environment changes.

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
