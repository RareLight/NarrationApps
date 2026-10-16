#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
bash "$project_root/swift-packages/scripts/prepare-dependencies.sh"
xcodebuild -workspace "$project_root/NarrationApps.xcworkspace" \
    -scheme 'Build Both Apps' -resolvePackageDependencies \
    -onlyUsePackageVersionsFromResolvedFile "$@"
printf '%s\n' 'Open NarrationApps.xcworkspace after closing the standalone Libro, VoiceRelay and package windows.'
