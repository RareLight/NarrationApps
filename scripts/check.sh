#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
/usr/bin/swift scripts/check-layout.swift
/usr/bin/swift scripts/check-docs.swift "$project_root"
/usr/bin/swift scripts/check-docs.swift "$project_root/swift-packages"
/usr/bin/swift scripts/check-docs.swift "$project_root/Libro"
bash Libro/scripts/check.sh
export NARRATION_FIXTURE_WORKER="$project_root/swift-packages/.build/debug/NarrationFixtureWorker"
swift test --package-path "$project_root/VoiceRelay" --disable-sandbox --no-parallel --jobs 4
bash VoiceRelay/scripts/check-packaging.sh
bash VoiceRelay/scripts/check-docs.sh
bash -n scripts/*.sh
