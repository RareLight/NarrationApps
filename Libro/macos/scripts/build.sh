#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
bash "$native_root/scripts/prepare-dependencies.sh"
mkdir -p "$native_root/.build/cache" "$native_root/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$native_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$native_root/.build/module-cache"
xcodebuild -project "$native_root/Libro/Libro.xcodeproj" -scheme Libro \
    -configuration "${LIBRO_CONFIGURATION:-Debug}" -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$native_root/.build/DerivedData" \
    -clonedSourcePackagesDirPath "$native_root/.build/SourcePackages" \
    -packageCachePath "$native_root/.build/cache" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES "$@"
