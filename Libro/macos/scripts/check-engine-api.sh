#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${LIBRO_CONFIGURATION:-Debug}"
products="$native_root/.build/DerivedData/Build/Products/$configuration"
[[ -d "$products/MLXAudioTTS.swiftmodule" ]] || {
    echo 'Build the native app before running the engine API checks.' >&2
    exit 1
}
audit="$(mktemp -d "$native_root/.build/engine-api.XXXXXX")"
trap 'rm -rf "$audit"' EXIT
compiler=(xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors
    -target arm64-apple-macos27.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)"
    -I "$products" -I "$native_root/.build/dependencies/mlx-swift/Source/Cmlx/include"
    -module-cache-path "$native_root/.build/module-cache"
    -c "$native_root/DependencyTests/CacheTransfer.swift" -o "$audit/check.o")
for module_map in "$native_root/.build/DerivedData/Build/Intermediates.noindex/GeneratedModuleMaps/"*.modulemap; do
    compiler+=(-Xcc "-fmodule-map-file=$module_map")
done
# Swift module imports also require the packages' handwritten C module maps
# (including platform shim maps that Xcode does not generate itself).
for include in "$native_root/.build/SourcePackages/checkouts/"*/Sources/*/include; do
    if [[ -f "$include/module.modulemap" ]]; then compiler+=(-I "$include"); fi
done
"${compiler[@]}"
for define in REUSE_LLAMA_CACHE REUSE_QWEN_CACHE; do
    if "${compiler[@]}" -D "$define" > "$audit/reuse.log" 2>&1; then
        echo "$define unexpectedly accepted a cache alias after transfer." >&2
        exit 1
    fi
    rg -q 'sending .* risks causing data races' "$audit/reuse.log" || {
        cat "$audit/reuse.log" >&2
        exit 1
    }
done
echo 'Engine cache ownership: valid transfers compile; both post-transfer aliases are rejected.'
