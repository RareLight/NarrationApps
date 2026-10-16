#!/bin/bash
# Source this helper from preparation scripts; mutations require an exact
# recorded prefix of the patch sequence, including the clean upstream state.
prepare_patches() (
    set -euo pipefail
    local checkout="$1" revision="$2" scratch="$3"
    shift 3
    local patches=("$@") audit matched=-1 i
    [[ "$(git -C "$checkout" rev-parse HEAD)" == "$revision" ]] &&
        git -C "$checkout" diff --cached --quiet &&
        [[ -z "$(git -C "$checkout" ls-files --others --exclude-standard)" ]] || {
        echo "$checkout has an unexpected revision, staged edits or untracked files; preserve them and resolve manually." >&2
        exit 1
    }
    mkdir -p "$scratch"
    audit="$(mktemp -d "$scratch/patch-audit.XXXXXX")"
    trap 'rm -rf "$audit"' EXIT
    export GIT_INDEX_FILE="$audit/index"
    git -C "$checkout" read-tree HEAD
    git -C "$checkout" diff --no-ext-diff --binary --ignore-submodules=all > "$audit/actual"
    for ((i=0; i<=${#patches[@]}; i++)); do
        git -C "$checkout" diff --cached --no-ext-diff --binary --ignore-submodules=all > "$audit/expected"
        if cmp -s "$audit/actual" "$audit/expected"; then matched=$i; fi
        if ((i<${#patches[@]})); then
            git -C "$checkout" apply --cached "${patches[$i]}"
        fi
    done
    ((matched>=0)) || {
        echo "$checkout has edits beyond the recorded patches; preserve them and resolve manually." >&2
        exit 1
    }
    unset GIT_INDEX_FILE
    for ((i=matched; i<${#patches[@]}; i++)); do
        git -C "$checkout" apply --check "${patches[$i]}"
        git -C "$checkout" apply "${patches[$i]}"
    done
)
