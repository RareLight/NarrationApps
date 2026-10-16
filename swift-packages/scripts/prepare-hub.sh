#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
hub_dir="$native_root/.build/dependencies/swift-huggingface"
hub_revision=de01c0ab8fd537bbd8216cea7f774275178501a2
hub_patch="$native_root/Patches/hub-workspace-downloads.patch"
mkdir -p "$native_root/.build/dependencies"
if [[ ! -d "$hub_dir/.git" ]]; then
    git clone --no-checkout https://github.com/huggingface/swift-huggingface.git "$hub_dir"
    git -C "$hub_dir" checkout --detach "$hub_revision"
fi
[[ "$(git -C "$hub_dir" rev-parse HEAD)" == "$hub_revision" ]] &&
    git -C "$hub_dir" diff --cached --quiet &&
    [[ -z "$(git -C "$hub_dir" ls-files --others --exclude-standard)" ]] || {
    echo 'Hub SDK has an unexpected revision or edits; preserve them and resolve manually.' >&2
    exit 1
}
if git -C "$hub_dir" apply --reverse --check "$hub_patch" 2>/dev/null; then
    cmp -s "$hub_patch" <(git -C "$hub_dir" diff) || {
        echo 'Hub SDK has edits beyond the recorded patch; preserve them and resolve manually.' >&2
        exit 1
    }
else
    git -C "$hub_dir" diff --quiet || {
        echo 'Hub SDK has unexpected edits; preserve them and resolve manually.' >&2
        exit 1
    }
    git -C "$hub_dir" apply --check "$hub_patch"
    git -C "$hub_dir" apply "$hub_patch"
fi
echo 'Pinned Hub SDK and workspace download adaptation prepared.'
