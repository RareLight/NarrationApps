#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
bash "$native_root/scripts/prepare-hub.sh"
mkdir -p "$native_root/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$native_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$native_root/.build/module-cache"
swift test --package-path "$native_root/HubDownloadTests" \
    --scratch-path "$native_root/.build/HubDownloadTests" \
    --cache-path "$native_root/.build/cache" --force-resolved-versions --jobs 4 "$@"
