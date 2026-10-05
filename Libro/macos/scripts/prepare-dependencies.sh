#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
dependency_dir="$native_root/.build/dependencies/mlx-audio-swift"
revision=8d86630ade569728aaea3dc1a29fc44e2efa719b
patch_file="$native_root/Patches/misaki-local-resources.patch"
mkdir -p "$native_root/.build/dependencies"
if [[ ! -d "$dependency_dir/.git" ]]; then
    git clone --no-checkout https://github.com/Blaizzy/mlx-audio-swift.git "$dependency_dir"
    git -C "$dependency_dir" checkout --detach "$revision"
fi
[[ "$(git -C "$dependency_dir" rev-parse HEAD)" == "$revision" ]] || {
    echo 'Native dependency revision differs; preserve it and resolve manually.' >&2
    exit 1
}
if git -C "$dependency_dir" apply --reverse --check "$patch_file" 2>/dev/null; then
    cmp -s "$patch_file" <(git -C "$dependency_dir" diff) || {
        echo 'Native dependency has edits beyond the recorded patch; preserve them and resolve manually.' >&2
        exit 1
    }
    [[ -z "$(git -C "$dependency_dir" ls-files --others --exclude-standard)" ]] || {
        echo 'Native dependency has unexpected untracked files; preserve them and resolve manually.' >&2
        exit 1
    }
    echo 'Pinned native dependency and local-resource patch already prepared.'
else
    [[ -z "$(git -C "$dependency_dir" status --porcelain)" ]] || {
        echo 'Native dependency has unexpected edits; preserve them and resolve manually.' >&2
        exit 1
    }
    git -C "$dependency_dir" apply --check "$patch_file"
    git -C "$dependency_dir" apply "$patch_file"
fi
