#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${LIBRO_CONFIGURATION:-Debug}"
products="$native_root/.build/DerivedData/Build/Products/$configuration"
worker_objects="$native_root/.build/DerivedData/Build/Intermediates.noindex/Libro.build/$configuration/LibroSpeechWorker.build/Objects-normal/arm64/LibroSpeechWorker.LinkFileList"
[[ -f "$worker_objects" && -d "$products/MLXLLM.swiftmodule" ]] || {
    echo 'Build the native app before running dependency behavior checks.' >&2
    exit 1
}
audit="$(mktemp -d "$native_root/.build/engine-behavior.XXXXXX")"
trap 'rm -rf "$audit"' EXIT
# Link the exact built package objects, excluding the production worker entry
# point. Keep the fixture beside Xcode's bundles so MLX finds its Metal library.
rg -v '/LibroSpeechWorker.build/' "$worker_objects" > "$audit/packages.list"
executable="$products/LibroDependencyCheck"
compiler=(xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors
    -parse-as-library -target arm64-apple-macos27.0
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" -I "$products"
    -I "$native_root/.build/dependencies/mlx-swift/Source/Cmlx/include"
    -module-cache-path "$native_root/.build/module-cache")
for module_map in "$native_root/.build/DerivedData/Build/Intermediates.noindex/GeneratedModuleMaps/"*.modulemap; do
    compiler+=(-Xcc "-fmodule-map-file=$module_map")
done
for include in "$native_root/.build/SourcePackages/checkouts/"*/Sources/*/include; do
    if [[ -f "$include/module.modulemap" ]]; then compiler+=(-I "$include"); fi
done
"${compiler[@]}" "$native_root/DependencyTests/EngineBehavior.swift" \
    -Xlinker -filelist -Xlinker "$audit/packages.list" \
    -lc++ -lz -framework Foundation -framework Metal -framework Accelerate \
    -o "$executable"
MTL_DEBUG_LAYER=1 "$executable"
