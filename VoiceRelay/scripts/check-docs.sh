#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
exec /usr/bin/swift "$native_root/../scripts/check-docs.swift" "$native_root"
