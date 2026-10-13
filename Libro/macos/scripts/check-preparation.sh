#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$native_root/scripts/prepare-patches.sh"
mkdir -p "$native_root/.build"
fixture="$(mktemp -d "$native_root/.build/preparation-tests.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
checkout="$fixture/repo"
git init -q "$checkout"
git -C "$checkout" config user.name 'Libro Fixture'
git -C "$checkout" config user.email 'fixture@localhost'
printf 'original one\n' > "$checkout/one"
printf 'original two\n' > "$checkout/two"
git -C "$checkout" add .
git -C "$checkout" commit -qm fixture
revision="$(git -C "$checkout" rev-parse HEAD)"
printf 'patched one\n' > "$checkout/one"
git -C "$checkout" diff > "$fixture/one.patch"
git -C "$checkout" restore one
printf 'patched two\n' > "$checkout/two"
git -C "$checkout" diff > "$fixture/two.patch"
git -C "$checkout" restore two
prepare() {
    prepare_patches "$checkout" "$revision" "$fixture" "$fixture/one.patch" "$fixture/two.patch"
}
refuses_unchanged() {
    git -C "$checkout" diff --binary HEAD > "$fixture/before"
    if prepare > "$fixture/rejection.log" 2>&1; then
        echo 'Preparation unexpectedly accepted altered checkout.' >&2
        exit 1
    fi
    git -C "$checkout" diff --binary HEAD > "$fixture/after"
    cmp "$fixture/before" "$fixture/after"
}
# Clean setup, idempotence, and migration from the previously recorded prefix.
prepare
git -C "$checkout" diff --binary > "$fixture/prepared"
prepare
git -C "$checkout" diff --binary > "$fixture/repeated"
cmp "$fixture/prepared" "$fixture/repeated"
git -C "$checkout" restore one two
git -C "$checkout" apply "$fixture/one.patch"
prepare
git -C "$checkout" diff --binary > "$fixture/migrated"
cmp "$fixture/prepared" "$fixture/migrated"
# Reject unrelated unstaged, staged, untracked edits and revision drift.
printf 'unexpected\n' >> "$checkout/one"
refuses_unchanged
git -C "$checkout" restore one
git -C "$checkout" apply "$fixture/one.patch"
git -C "$checkout" add one
refuses_unchanged
git -C "$checkout" restore --staged one
printf 'private edit\n' > "$checkout/private"
refuses_unchanged
[[ "$(cat "$checkout/private")" == 'private edit' ]]
rm "$checkout/private"
revision=0000000000000000000000000000000000000000
refuses_unchanged
echo 'Dependency preparation: 7 safety and reproducibility checks passed.'
