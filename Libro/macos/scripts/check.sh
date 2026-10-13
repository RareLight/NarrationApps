#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$native_root/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$native_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$native_root/.build/module-cache"
# No MLX, model downloads, private documents, or Python environment required.
swift build --package-path "$native_root/LibroCore" --scratch-path "$native_root/.build/CoreTests" --product LibroFixtureWorker
export LIBRO_FIXTURE_WORKER="$native_root/.build/CoreTests/debug/LibroFixtureWorker"
swift test --package-path "$native_root/LibroCore" --scratch-path "$native_root/.build/CoreTests"
bash "$native_root/scripts/check-preparation.sh"
bash -n "$native_root"/scripts/*.sh "$native_root/Libro/Configuration/embed-worker-resources.sh"
plutil -lint "$native_root/Libro/Libro.xcodeproj/project.pbxproj" "$native_root/Libro/App/Info.plist"
