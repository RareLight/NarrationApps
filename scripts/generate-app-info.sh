#!/bin/bash
# generate-app-info.sh <repo-root> <template-plist> <output-plist> <marketing-version>
# Generates the application Info.plist under DERIVED_FILE_DIR from a copy of the
# source template, stamping the marketing version, the commit-count build
# number, the full HEAD revision and a clean/modified flag. Never edits tracked
# source and never mutates the repository; the previous output stays in place
# when any step fails.
set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "usage: $0 <repo-root> <template-plist> <output-plist> <marketing-version>" >&2
    exit 64
fi

ROOT="$1" TEMPLATE="$2" OUTPUT="$3" MARKETING="$4"

# Canonicalize the repository root: it must exist as a directory and resolve to
# a real path so build settings cannot smuggle in relative segments.
ROOT="$(cd "$ROOT" 2>/dev/null && pwd -P)" || {
    echo "generate-app-info: repository root '$1' is not a directory" >&2; exit 66; }
[ -f "$TEMPLATE" ] || { echo "generate-app-info: template plist '$TEMPLATE' is missing" >&2; exit 66; }

# Require real full Git history: no detached metadata directory, no missing or
# unborn HEAD and no shallow clone (a shallow clone would fabricate the count).
[ -e "$ROOT/.git" ] || { echo "generate-app-info: '$ROOT' is not a Git work tree" >&2; exit 69; }
export GIT_OPTIONAL_LOCKS=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
GIT() { git -C "$ROOT" -c core.fsmonitor=false "$@"; }
GIT rev-parse --git-dir >/dev/null 2>&1 || { echo "generate-app-info: '$ROOT' is not a Git work tree" >&2; exit 69; }
SHALLOW="$(GIT rev-parse --is-shallow-repository 2>/dev/null)" || {
    echo "generate-app-info: cannot read Git history under '$ROOT'" >&2; exit 69; }
[ "$SHALLOW" = "false" ] || { echo "generate-app-info: shallow clones have incomplete history; build number refused" >&2; exit 69; }
REVISION="$(GIT rev-parse HEAD 2>/dev/null)" || {
    echo "generate-app-info: repository has no commits yet" >&2; exit 69; }
BUILD="$(GIT rev-list --count HEAD 2>/dev/null)" || {
    echo "generate-app-info: cannot count commits under '$ROOT'" >&2; exit 69; }

# Validate metadata: full lowercase hex revision, decimal build inside Apple's
# four-digit bound and a three-component numeric marketing version.
case "$REVISION" in
    *[!0-9a-f]*|"") echo "generate-app-info: unexpected revision '$REVISION'" >&2; exit 70 ;;
esac
case ${#REVISION} in 40|64) ;; *) echo "generate-app-info: unexpected revision length" >&2; exit 70 ;; esac
case "$BUILD" in *[!0-9]*|""|0*) echo "generate-app-info: unexpected build number '$BUILD'" >&2; exit 70 ;; esac
if [ "$BUILD" -lt 1 ] || [ "$BUILD" -gt 9999 ]; then
    echo "generate-app-info: build number $BUILD is outside Apple's 1-9999 bound" >&2; exit 70
fi
case "$MARKETING" in
    ""|*[![:print:]]*) echo "generate-app-info: malformed marketing version" >&2; exit 64 ;;
esac
if ! printf '%s' "$MARKETING" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
    echo "generate-app-info: malformed marketing version '$MARKETING'" >&2; exit 64
fi

mkdir -p "$(dirname "$OUTPUT")"
STATUS_TMP="${OUTPUT}.status.tmp"
rm -f "$STATUS_TMP"
if ! STATUS="$(GIT status --porcelain --untracked-files=normal 2>"$STATUS_TMP")"; then
    rm -f "$STATUS_TMP"
    echo "generate-app-info: cannot inspect worktree status under '$ROOT'" >&2; exit 69
fi
if [ -s "$STATUS_TMP" ]; then
    cat "$STATUS_TMP" >&2; rm -f "$STATUS_TMP"
    echo "generate-app-info: worktree status is incomplete under this environment; refusing to stamp clean metadata" >&2; exit 69
fi
rm -f "$STATUS_TMP"
if [ -n "$STATUS" ]; then MODIFIED=YES; else MODIFIED=NO; fi

PB="/usr/libexec/PlistBuddy"
OUTRESOLVED="$(cd "$(dirname "$OUTPUT")" && pwd -P)/$(basename "$OUTPUT")"
TPLRESOLVED="$(cd "$(dirname "$TEMPLATE")" && pwd -P)/$(basename "$TEMPLATE")"
[ "$OUTRESOLVED" = "$TPLRESOLVED" ] && { echo "generate-app-info: output must not overwrite the source template" >&2; exit 64; }
TMP="${OUTPUT}.tmp"; trap 'rm -f "$TMP"' EXIT
rm -f "$TMP"
cp "$TEMPLATE" "$TMP"
$PB -c "Set :CFBundleShortVersionString $MARKETING" "$TMP" 2>/dev/null || \
    $PB -c "Add :CFBundleShortVersionString string $MARKETING" "$TMP"
$PB -c "Set :CFBundleVersion $BUILD" "$TMP" 2>/dev/null || \
    $PB -c "Add :CFBundleVersion string $BUILD" "$TMP"
$PB -c "Add :NarrationAppsGitRevision string $REVISION" "$TMP" 2>/dev/null || \
    $PB -c "Set :NarrationAppsGitRevision $REVISION" "$TMP"
$PB -c "Add :NarrationAppsSourceModified bool $MODIFIED" "$TMP" 2>/dev/null || \
    $PB -c "Set :NarrationAppsSourceModified $MODIFIED" "$TMP"

# Compare before replacing so identical rebuilds keep the same file timestamp;
# otherwise swap the finished plist into place atomically.
NOTE="$BUILD, ${REVISION:0:7}"
if [ "$MODIFIED" = YES ]; then NOTE="$NOTE modified"; fi
if [ -f "$OUTPUT" ] && /usr/bin/plutil -lint "$OUTPUT" >/dev/null 2>&1 \
   && cmp -s "$TMP" "$OUTPUT"; then
    echo "generate-app-info: $MARKETING ($NOTE) unchanged"
    exit 0
fi
/usr/bin/plutil -lint "$TMP" >/dev/null
mv -f "$TMP" "$OUTPUT"
trap - EXIT
echo "generate-app-info: $MARKETING ($NOTE)"
