#!/bin/bash
set -euo pipefail
build_configuration="${1:-debug}"
case "$build_configuration" in debug|release) ;; *) echo 'Usage: build-app.sh [debug|release]' >&2; exit 1;; esac
native_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$native_root"
swift build -c "$build_configuration" --product VoiceRelayApp
swift build -c "$build_configuration" --product VoiceRelayAgent
binary_directory="$(swift build -c "$build_configuration" --show-bin-path)"
application="$native_root/dist/VoiceRelay.app"
mkdir -p "$application/Contents/MacOS" "$application/Contents/Resources"
cp "$binary_directory/VoiceRelayApp" "$application/Contents/MacOS/VoiceRelayApp"
cp "$binary_directory/VoiceRelayAgent" "$application/Contents/MacOS/VoiceRelayAgent"
mkdir -p "$application/Contents/Library/LaunchAgents"
cp Packaging/org.voicerelay.prototype.agent.plist "$application/Contents/Library/LaunchAgents/"
cp Packaging/Info.plist "$application/Contents/Info.plist"
# SwiftPM's generated Bundle.module searches Bundle.main.resourceURL in an app.
cp -R "$binary_directory/VoiceRelay_VoiceRelayCore.bundle" "$application/Contents/Resources/"
mkdir -p "$application/Contents/Resources/Acknowledgements"
cp -fR Acknowledgements/. "$application/Contents/Resources/Acknowledgements/"
# Ad hoc package builds can run the inert self-check; trusted listener mode stays refused.
codesign --force --sign - --identifier org.voicerelay.prototype.agent "$application/Contents/MacOS/VoiceRelayAgent"
codesign --force --sign - "$application"
codesign --verify --strict "$application"
echo "$application"
