#!/bin/bash
set -euo pipefail
shared_root="$(cd "$(dirname "$0")/.." && pwd)"
checkout="$shared_root/.build/dependencies/ZIPFoundation"
revision=22787ffb59de99e5dc1fbfe80b19c97a904ad48d
source "$shared_root/scripts/prepare-patches.sh"
mkdir -p "$shared_root/.build/dependencies"
if [[ ! -d "$checkout/.git" ]]; then
    git clone --no-checkout https://github.com/weichsel/ZIPFoundation.git "$checkout"
    git -C "$checkout" checkout --detach "$revision"
fi
prepare_patches "$checkout" "$revision" "$shared_root/.build" \
    "$shared_root/Patches/zipfoundation-watchos-minimum.patch"
echo 'Pinned ZIPFoundation and watchOS manifest compatibility patch prepared.'
