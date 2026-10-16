#!/bin/bash
set -euo pipefail
export MACOSX_DEPLOYMENT_TARGET=15.0
native_root="$(cd "$(dirname "$0")/.." && pwd)"
archive="$native_root/.build/lame-3.100.tar.gz"
archive_sha=ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
prefix="$native_root/.build/codecs/lame"
library="$prefix/lib/libmp3lame.0.dylib"
patch_file="$native_root/Patches/lame-export-symbols.patch"
artwork_patch="$native_root/Patches/lame-front-cover.patch"
mkdir -p "$native_root/.build/codecs"
signature="$( { shasum -a 256 "$0" "$patch_file" "$artwork_patch"; xcodebuild -version; } | shasum -a 256 | cut -d ' ' -f 1)"
if [[ -f "$prefix/build.signature" && "$(cat "$prefix/build.signature")" == "$signature" && -f "$library" ]]; then
    (cd "$prefix" && shasum -a 256 -c library.sha256)
    exit 0
fi
if [[ ! -f "$archive" ]]; then
    curl -fL --retry 2 https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz -o "$archive.incomplete"
    mv "$archive.incomplete" "$archive"
fi
[[ "$(shasum -a 256 "$archive" | cut -d ' ' -f 1)" == "$archive_sha" ]] || {
    echo 'LAME source archive checksum differs; preserve it and resolve manually.' >&2
    exit 1
}
work="$(mktemp -d "$native_root/.build/codecs/lame-build.XXXXXX")"
tar -xzf "$archive" -C "$work"
cd "$work/lame-3.100"
patch --dry-run -p1 < "$patch_file"
patch -p1 < "$patch_file"
patch --dry-run -p1 < "$artwork_patch"
patch -p1 < "$artwork_patch"
# Enable decoder symbols declared by the upstream shared-library export list;
# Libro never enables on-the-fly decoding or ReplayGain. No frontend is built.
CC=clang ./configure --build=aarch64-apple-darwin --host=aarch64-apple-darwin \
    --prefix="$prefix" --enable-shared --disable-static --disable-frontend --enable-decoder
make -j4
make install
[[ "$(lipo -archs "$library")" == arm64 ]]
install_name_tool -id @rpath/libmp3lame.0.dylib "$library"
mkdir -p "$native_root/.build/notices/lame"
cp -f COPYING README "$native_root/.build/notices/lame/"
(cd "$prefix" && shasum -a 256 lib/libmp3lame.0.dylib > library.sha256)
printf '%s\n' "$signature" > "$prefix/build.signature"
