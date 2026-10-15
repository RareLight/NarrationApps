#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
shared_root="$(cd "$native_root/../../swift-packages" && pwd)"
bash "$shared_root/scripts/check.sh"
swift test --package-path "$native_root/LibroCore" --scratch-path "$native_root/.build/CoreTests" --no-parallel
bash -n "$native_root"/scripts/*.sh "$native_root/Libro/Configuration/embed-worker-resources.sh"
plutil -lint "$native_root/Libro/Libro.xcodeproj/project.pbxproj" "$native_root/Libro/App/Info.plist"
