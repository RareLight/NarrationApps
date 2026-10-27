#!/bin/bash
set -euo pipefail
tool_root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$tool_root/../.." && pwd)"
if [[ ! -d "$repo_root/swift-packages/.build/dependencies/mlx-audio-swift" ]]; then
    echo 'Prepare the project dependencies first; see CONTRIBUTING.md.' >&2
    exit 1
fi
unset TTS_BENCH_CORE_ONLY
if ! xcrun metal --version >/dev/null 2>&1; then
    component="$(xcodebuild -showComponent MetalToolchain -json 2>/dev/null)"
    compiler_id="$(printf '%s' "$component" | plutil -extract toolchainIdentifier raw -o - -)"
    export TOOLCHAINS="$compiler_id"
    xcrun metal --version
fi
swift build --package-path "$tool_root" --scratch-path "$tool_root/.build/native" --disable-sandbox --force-resolved-versions -c release --jobs 4
bench_bin="$(swift build --package-path "$tool_root" --scratch-path "$tool_root/.build/native" -c release --show-bin-path)"
swift "$tool_root/scripts/build-evidence.swift" "$repo_root" "$bench_bin"
