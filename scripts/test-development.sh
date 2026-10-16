#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/narration-tool-tests.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
xcrun swiftc -D TOOL_TESTS "$root"/scripts/development/*.swift \
    "$root/scripts/tests/DevelopmentTests.swift" -o "$fixture/tests"
cd "$root"
"$fixture/tests"
