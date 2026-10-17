#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tool="$(mktemp -d "${TMPDIR:-/tmp}/narration-development.XXXXXX")"
trap 'rm -rf "$tool"' EXIT
xcrun swiftc "$root"/scripts/development/*.swift -o "$tool/develop"
cd "$root"
"$tool/develop" "$@"
