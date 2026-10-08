#!/bin/bash
set -euo pipefail
build_configuration="${1:-debug}"
case "$build_configuration" in
  debug) xcode_configuration=Debug ;;
  release) xcode_configuration=Release ;;
  *) echo 'Usage: build-app.sh [debug|release]' >&2; exit 1 ;;
esac
native_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$native_root"
# Use Xcode's signed bundle so Data Protection Keychain entitlements and the
# matching provisioning profile survive packaging. Building never launches it.
build_command=(xcodebuild -project VoiceRelay.xcodeproj -scheme VoiceRelay
  -configuration "$xcode_configuration" -derivedDataPath "$native_root/DerivedData"
  -disableAutomaticPackageResolution)
if [[ -n "${VOICERELAY_SIGNING_IDENTITY:-}" ]]; then
  build_command+=("CODE_SIGN_IDENTITY=$VOICERELAY_SIGNING_IDENTITY")
fi
"${build_command[@]}" build
application="$native_root/dist/VoiceRelay.app"
mkdir -p "$native_root/dist"
# Replace only the generated bundle; merging would retain obsolete signed files.
if [[ -e "$application" ]]; then rm -rf "$application"; fi
ditto "$native_root/DerivedData/Build/Products/$xcode_configuration/VoiceRelay.app" "$application"
codesign --verify --strict "$application"
echo "$application"
