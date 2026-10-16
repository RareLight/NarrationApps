#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
notice_dir="$native_root/ThirdPartyNotices"
mkdir -p "$notice_dir"
for checkout in "$native_root"/.build/checkouts/* "$native_root"/.build/SourcePackages/checkouts/* "$native_root"/.build/dependencies/* "$native_root"/.build/notices/lame \
    "$native_root"/.build/dependencies/mlx-swift/Source/Cmlx/{mlx,mlx-c}; do
    [[ -d "$checkout" ]] || continue
    name="$(basename "$checkout")"
    mkdir -p "$notice_dir/$name"
    for file in "$checkout"/LICENSE* "$checkout"/NOTICE* "$checkout"/COPYING*; do
        [[ -f "$file" ]] || continue
        cp -f "$file" "$notice_dir/$name/"
    done
done
