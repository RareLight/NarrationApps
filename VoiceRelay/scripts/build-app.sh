#!/bin/bash
set -euo pipefail
build_configuration="${1:-debug}"
case "$build_configuration" in debug|release) ;; *) echo 'Usage: build-app.sh [debug|release]' >&2; exit 1;; esac
native_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$native_root"
swift build -c "$build_configuration" --product VoiceRelayApp
binary_directory="$(swift build -c "$build_configuration" --show-bin-path)"
application="$native_root/dist/VoiceRelay.app"
mkdir -p "$application/Contents/MacOS" "$application/Contents/Resources"
cp "$binary_directory/VoiceRelayApp" "$application/Contents/MacOS/VoiceRelayApp"
cp Packaging/Info.plist "$application/Contents/Info.plist"
# SwiftPM's generated Bundle.module searches Bundle.main.resourceURL in an app.
cp -R "$binary_directory/VoiceRelay_VoiceRelayCore.bundle" "$application/Contents/Resources/"
mkdir -p "$application/Contents/Resources/Acknowledgements"
cp -fR Acknowledgements/. "$application/Contents/Resources/Acknowledgements/"
codesign --force --sign - "$application"
codesign --verify --strict "$application"
echo "$application"
