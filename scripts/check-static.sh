#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
swift scripts/check-layout.swift
swift scripts/check-contracts.swift
for directory in "$root" "$root/swift-packages" "$root/Libro"; do
    swift scripts/check-docs.swift "$directory"
done
bash VoiceRelay/scripts/check-docs.sh
for script in scripts/*.sh swift-packages/scripts/*.sh Libro/scripts/*.sh Libro/macos/scripts/*.sh VoiceRelay/scripts/*.sh; do
    bash -n "$script"
done
plutil -lint Libro/macos/Libro/Libro.xcodeproj/project.pbxproj Libro/macos/Libro/App/Info.plist \
    VoiceRelay/VoiceRelay.xcodeproj/project.pbxproj
