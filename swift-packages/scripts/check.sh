#!/bin/bash
set -euo pipefail
shared_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$shared_root"
bash scripts/check-voice-sample-help.sh
swift test --package-path "$shared_root/AppPresentation" --disable-sandbox --skip-update --force-resolved-versions --no-parallel --jobs 4
sandbox-exec -p '(version 1)(allow default)(deny network*)' bash scripts/prepare-dependencies.sh
bash scripts/check-native-numbers.sh
swift build --disable-sandbox --skip-update --force-resolved-versions --product NarrationFixtureWorker --jobs 4
export NARRATION_FIXTURE_WORKER="$shared_root/.build/debug/NarrationFixtureWorker"
export NARRATION_MP3_LIBRARY="$shared_root/.build/codecs/lame/lib/libmp3lame.0.dylib"
swift test --disable-sandbox --skip-update --force-resolved-versions --no-parallel --jobs 4
bash scripts/check-preparation.sh
bash -n scripts/*.sh
