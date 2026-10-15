#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
bash "$native_root/../../swift-packages/scripts/check-preparation.sh" "$@"
