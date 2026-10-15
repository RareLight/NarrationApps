#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
audit="$(mktemp -d "$native_root/.build/native-numbers.XXXXXX")"
trap 'rm -rf "$audit"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
    "$native_root/.build/dependencies/mlx-audio-swift/Sources/MLXAudioTTS/Models/StyleTTS2/G2P/EnglishNum2Word.swift" \
    "$native_root/DependencyTests/EnglishNumbers.swift" -o "$audit/check"
"$audit/check"
