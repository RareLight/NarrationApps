#!/bin/bash
set -euo pipefail
launcher="$(cd "$(dirname "$0")" && pwd)/regenerate-voice-samples.sh"
check_help() {
    local expected="$1" output status
    shift
    if output="$(bash "$launcher" "$@" 2>&1)"; then
        status=0
    else
        status=$?
    fi
    if [[ "$status" -ne "$expected" || "$output" != *'Usage:'* ||
          "$output" != *'Use single quotes'* || "$output" != *"'I can narrate"* ||
          "$output" != *'dquote>'* || "$output" != *'-h, --help'* ]]; then
        printf 'Voice sample launcher help regression (exit %s, expected %s):\n%s\n' "$status" "$expected" "$output" >&2
        exit 1
    fi
}
check_help 0 -h
check_help 0 --help
check_help 2
check_help 2 ''
check_help 2 one two
check_help 2 --help extra
printf 'Voice sample launcher: help flags, missing/empty/extra arguments and quoting guidance passed.\n'
