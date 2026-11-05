#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
audit="$(mktemp -d "$native_root/.build/native-tokenizer.XXXXXX")"
trap 'rm -rf "$audit"' EXIT
# The pinned Qwen converter is the last method in its MLX-owning type.
# Compile that exact Foundation-only method without importing or initializing MLX.
# A changed/missing public signature fails this check rather than using a copy.
awk 'BEGIN { print "import Foundation\nenum Qwen3TTSModel {" }
     /^    public static func generateTokenizerJson\(/ { found=1 }
     found { print }
     END { if (!found) exit 1 }' \
    "$native_root/.build/dependencies/mlx-audio-swift/Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift" > "$audit/Converter.swift"
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
    "$audit/Converter.swift" "$native_root/DependencyTests/QwenTokenizerPreparation.swift" -o "$audit/check"
"$audit/check" "$audit"
