#!/bin/bash
set -euo pipefail
tool_root="$(cd "$(dirname "$0")/.." && pwd)"
export TTS_BENCH_CORE_ONLY=1
mkdir -p "$tool_root/.build/fixtures"
saved_lock="$(mktemp "$tool_root/.build/fixtures/lock.XXXXXX")"
had_lock=0
if [[ -f "$tool_root/Package.resolved" ]]; then
    cp "$tool_root/Package.resolved" "$saved_lock"
    had_lock=1
fi
restore_lock() {
    if [[ "$had_lock" == 1 ]]; then cp "$saved_lock" "$tool_root/Package.resolved"; fi
    rm -f "$saved_lock"
}
trap restore_lock EXIT
swift build --package-path "$tool_root" --scratch-path "$tool_root/.build/fixtures" --disable-sandbox --product BenchmarkFixtureWorker --jobs 4
tool_bin="$(swift build --package-path "$tool_root" --scratch-path "$tool_root/.build/fixtures" --show-bin-path)"
export TTS_BENCH_FIXTURE_WORKER="$tool_bin/BenchmarkFixtureWorker"
swift test --package-path "$tool_root" --scratch-path "$tool_root/.build/fixtures" --disable-sandbox --jobs 4
