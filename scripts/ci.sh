#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
tier="${REQUESTED_TIER:-}"
if [[ -z "$tier" ]]; then
    tier="$(swift scripts/select-ci-tier.swift "${BEFORE_REVISION:-}")"
fi
case "$tier" in
    quick|full) bash scripts/check.sh --tier "$tier" ;;
    release) bash scripts/check.sh && bash scripts/check.sh --tier release --adhoc ;;
    *) echo 'CI tier must be quick, full or release.' >&2; exit 2 ;;
esac
