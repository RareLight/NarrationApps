#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
notice_dir="$native_root/.build/notices"
mkdir -p "$notice_dir"
for checkout in "$native_root/.build/dependencies/mlx-audio-swift" "$native_root"/.build/SourcePackages/checkouts/*; do
    [[ -d "$checkout" ]] || continue
    name="$(basename "$checkout")"
    mkdir -p "$notice_dir/$name"
    for file in "$checkout"/LICENSE* "$checkout"/NOTICE* "$checkout"/COPYING*; do
        [[ -f "$file" ]] || continue
        cp "$file" "$notice_dir/$name/"
    done
done
