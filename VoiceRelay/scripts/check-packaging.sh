#!/bin/bash
# Isolated fake build/sign tools: never install, sign or launch a live app.
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/voicerelay-package.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
fixture="$test_root/VoiceRelay"
mkdir -p "$fixture/scripts" "$test_root/scripts" "$test_root/tools"
cp "$native_root/scripts/build-app.sh" "$fixture/scripts/"
cp "$native_root/../scripts/install-app.swift" "$test_root/scripts/"
for tool in xcodebuild codesign; do
  cat > "$test_root/tools/$tool" <<'TOOL'
#!/bin/bash
case "$(basename "$0")" in
 xcodebuild) exit "${BUILD_FAIL:-0}" ;;
 codesign) exit "${SIGN_FAIL:-0}" ;;
esac
TOOL
done
cat > "$test_root/tools/ditto" <<'TOOL'
#!/bin/bash
if [[ "${COPY_FAIL:-0}" == 1 ]]; then mkdir -p "$2"; exit 1; fi
/bin/cp -R "$1" "$2"
TOOL
chmod 700 "$test_root/tools/"*
export PATH="$test_root/tools:$PATH"
unset VOICERELAY_SIGNING_IDENTITY
built="$fixture/DerivedData/Build/Products/Release/VoiceRelay.app"
application="$fixture/dist/VoiceRelay.app"
mkdir -p "$built" "$application"
echo 'new package' > "$built/new"
echo 'previous valid package' > "$application/old"
package() { /bin/bash "$fixture/scripts/build-app.sh" release > "$test_root/result.log" 2>&1; }
for setting in BUILD_FAIL COPY_FAIL SIGN_FAIL; do
 if env "$setting=1" /bin/bash "$fixture/scripts/build-app.sh" release > "$test_root/result.log" 2>&1; then echo "$setting accepted" >&2; exit 1; fi
 [[ -f "$application/old" && ! -e "$application/new" ]]
done
mv "$application" "$fixture/private-original.app"
ln -s "$fixture/private-original.app" "$application"
if package; then echo 'Symlink destination accepted' >&2; exit 1; fi
[[ -L "$application" && -f "$fixture/private-original.app/old" && ! -e "$fixture/private-original.app/new" ]]
rm "$application"
mv "$fixture/private-original.app" "$application"
package
[[ -f "$application/new" && ! -e "$application/old" ]]
package
[[ -f "$application/new" ]]
[[ -z "$(find "$fixture/dist" -name '.VoiceRelay-package.*' -print)" ]]
echo 'Native packaging: build/copy/sign failures, symlink refusal and repeated atomic replacement passed.'
