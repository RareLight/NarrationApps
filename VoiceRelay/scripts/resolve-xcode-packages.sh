#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"

# Match Xcode's GUI workspace; build-app.sh uses separate repo-local DerivedData.
bash "$native_root/../swift-packages/scripts/prepare-dependencies.sh"
xcodebuild -project "$native_root/VoiceRelay.xcodeproj" -scheme VoiceRelay \
    -resolvePackageDependencies -onlyUsePackageVersionsFromResolvedFile "$@"
printf '%s\n' 'Package resolution completed. If Xcode was open, save your work and reopen VoiceRelay to reload its package graph.'
