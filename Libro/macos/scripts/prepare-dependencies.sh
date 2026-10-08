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

# Root-local MLX overrides the same package identity throughout the graph.
# Keep its upstream version/submodule pins; backport only the empty-vector fix.
mlx_dir="$native_root/.build/dependencies/mlx-swift"
mlx_revision=dc43e62d7055353c7f99fa071a4e71d29dfddc44
mlx_patch="$native_root/Patches/mlx-empty-vector-metal.patch"
if [[ ! -d "$mlx_dir/.git" ]]; then
    git clone --no-checkout https://github.com/ml-explore/mlx-swift.git "$mlx_dir"
    git -C "$mlx_dir" checkout --detach "$mlx_revision"
fi
[[ "$(git -C "$mlx_dir" rev-parse HEAD)" == "$mlx_revision" ]] &&
    git -C "$mlx_dir" diff --quiet --ignore-submodules=all &&
    git -C "$mlx_dir" diff --cached --quiet &&
    [[ -z "$(git -C "$mlx_dir" ls-files --others --exclude-standard)" ]] || {
    echo 'MLX Swift has an unexpected revision or edits; preserve them and resolve manually.' >&2
    exit 1
}
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
        if git -C "$module_dir" apply --reverse --check "$mlx_patch" 2>/dev/null; then
            cmp -s "$mlx_patch" <(git -C "$module_dir" diff --unified=1) || {
                echo 'MLX core has edits beyond the recorded patch; preserve them and resolve manually.' >&2
                exit 1
            }
        else
            git -C "$module_dir" diff --quiet || {
                echo 'MLX core has unexpected edits; preserve them and resolve manually.' >&2
                exit 1
            }
            git -C "$module_dir" apply --check "$mlx_patch"
            git -C "$module_dir" apply "$mlx_patch"
        fi
    else
        git -C "$module_dir" diff --quiet || {
            echo 'MLX C has unexpected edits; preserve them and resolve manually.' >&2
            exit 1
        }
    fi
done
echo 'Pinned MLX Swift and Metal empty-vector backport prepared.'
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
