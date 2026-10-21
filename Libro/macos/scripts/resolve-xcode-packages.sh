#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"

# Refresh the same package workspace used by Xcode's GUI. build.sh deliberately
# uses isolated build directories, so its resolution cannot refresh this workspace.
bash "$native_root/scripts/prepare-dependencies.sh"
xcodebuild -project "$native_root/Libro/Libro.xcodeproj" -scheme Libro \
    -resolvePackageDependencies -onlyUsePackageVersionsFromResolvedFile "$@"
printf '%s\n' 'Package resolution completed. If Xcode was open, save your work, quit Xcode completely and reopen Libro before rebuilding.'
