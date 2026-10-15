#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
export NARRATION_CONFIGURATION="${LIBRO_CONFIGURATION:-Debug}"
export NARRATION_DERIVED_DATA="${NARRATION_DERIVED_DATA:-$native_root/.build/DerivedData}"
export NARRATION_PACKAGE_CHECKOUTS="${NARRATION_PACKAGE_CHECKOUTS:-$native_root/.build/SourcePackages/checkouts}"
export NARRATION_WORKER_OBJECTS="${NARRATION_WORKER_OBJECTS:-$NARRATION_DERIVED_DATA/Build/Intermediates.noindex/Libro.build/$NARRATION_CONFIGURATION/LibroSpeechWorker.build/Objects-normal/arm64/LibroSpeechWorker.LinkFileList}"
exec bash "$native_root/../../swift-packages/scripts/check-engine-api.sh"
