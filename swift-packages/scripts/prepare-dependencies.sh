#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
dependency_dir="$native_root/.build/dependencies/mlx-audio-swift"
revision=8d86630ade569728aaea3dc1a29fc44e2efa719b
patch_file="$native_root/Patches/misaki-local-resources.patch"
source "$native_root/scripts/prepare-patches.sh"
mkdir -p "$native_root/.build/dependencies"
bash "$native_root/scripts/prepare-zipfoundation.sh"
bash "$native_root/scripts/prepare-hub.sh"
if [[ ! -d "$dependency_dir/.git" ]]; then
    git clone --no-checkout https://github.com/Blaizzy/mlx-audio-swift.git "$dependency_dir"
    git -C "$dependency_dir" checkout --detach "$revision"
fi
bash "$native_root/scripts/prepare-codecs.sh"

# Every native consumer uses the same local package locations.
# Keep upstream revisions; adapt the Metal build minimum and empty-vector bug.
mlx_dir="$native_root/.build/dependencies/mlx-swift"
mlx_revision=dc43e62d7055353c7f99fa071a4e71d29dfddc44
mlx_patch="$native_root/Patches/mlx-empty-vector-metal.patch"
if [[ ! -d "$mlx_dir/.git" ]]; then
    git clone --no-checkout https://github.com/ml-explore/mlx-swift.git "$mlx_dir"
    git -C "$mlx_dir" checkout --detach "$mlx_revision"
fi
prepare_patches "$mlx_dir" "$mlx_revision" "$native_root/.build" \
    "$native_root/Patches/mlx-metal4-platform.patch" \
    "$native_root/Patches/mlx-vendor-warning-policy.patch" \
    "$native_root/Patches/mlx-swift-warning-compatibility.patch"
for module in mlx mlx-c; do
    module_dir="$mlx_dir/Source/Cmlx/$module"
    module_revision="$(git -C "$mlx_dir" rev-parse "HEAD:Source/Cmlx/$module")"
    if [[ ! -e "$module_dir/.git" && ! -L "$module_dir/.git" ]]; then
        git -C "$mlx_dir" submodule update --init -- "Source/Cmlx/$module"
    fi
    [[ "$(git -C "$module_dir" rev-parse HEAD)" == "$module_revision" ]] &&
        git -C "$module_dir" diff --cached --quiet &&
        [[ -z "$(git -C "$module_dir" ls-files --others --exclude-standard)" ]] || {
        echo 'MLX submodule has an unexpected revision or edits; preserve them and resolve manually.' >&2
        exit 1
    }
    if [[ "$module" == mlx ]]; then
        # Audit applied content in this checkout. Git's abbreviated blob IDs
        # vary with object-store size, so a literal diff/patch cmp is unstable.
        prepare_patches "$module_dir" "$module_revision" "$native_root/.build" "$mlx_patch"
    else
        git -C "$module_dir" diff --quiet || {
            echo 'MLX C has unexpected edits; preserve them and resolve manually.' >&2
            exit 1
        }
    fi

done
echo 'Pinned MLX Swift and Metal empty-vector backport prepared.'
lm_dir="$native_root/.build/dependencies/mlx-swift-lm"
lm_revision=bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57
if [[ ! -d "$lm_dir/.git" ]]; then
    git clone --no-checkout https://github.com/ml-explore/mlx-swift-lm.git "$lm_dir"
    git -C "$lm_dir" checkout --detach "$lm_revision"
fi
prepare_patches "$lm_dir" "$lm_revision" "$native_root/.build" \
    "$native_root/Patches/mlx-lm-local-dependency.patch" \
    "$native_root/Patches/mlx-lm-encoding-detection.patch"
prepare_patches "$dependency_dir" "$revision" "$native_root/.build" \
    "$patch_file" "$native_root/Patches/mlx-audio-build-compatibility.patch" \
    "$native_root/Patches/kokoro-prepared-frontend.patch" \
    "$native_root/Patches/kokoro-vocabulary-contract.patch" \
    "$native_root/Patches/kokoro-loaded-voice-shape.patch" \
    "$native_root/Patches/misaki-bart-input-bound.patch" \
    "$native_root/Patches/misaki-number-parity.patch" \
    "$native_root/Patches/misaki-currency-tags.patch" \
    "$native_root/Patches/misaki-subtoken-ranges.patch"
echo 'Pinned native packages and recorded compatibility patches prepared.'
