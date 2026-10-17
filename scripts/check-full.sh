#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
bash scripts/check-static.sh
bash scripts/test-development.sh
bash Libro/scripts/check.sh
export NARRATION_FIXTURE_WORKER="$project_root/swift-packages/.build/debug/NarrationFixtureWorker"
swift test --package-path "$project_root/VoiceRelay" --disable-sandbox --skip-update \
    --force-resolved-versions --no-parallel --jobs 4
bash VoiceRelay/scripts/check-packaging.sh
