#!/bin/bash
# test-app-versioning.sh - isolated verification for scripts/generate-app-info.sh.
# Builds a synthetic Git repository (private fixture commits, no signing, no
# network) inside a temp directory whose path contains spaces, then exercises
# clean/dirty/detached/malformed/shallow cases. Exits nonzero on any failure.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
GEN="$REPO_ROOT/scripts/generate-app-info.sh"
WORK="$(mktemp -d -t "narration versioning test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/fixture repo"
OUT="$WORK/derived/NarrationApps-Info.plist"
TEMPLATE="$WORK/template.plist"
fail=0
check() { # check <name> <condition-true=0/1>
    if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}
expect() { # expect <name> <expected> <actual>
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (expected '$2' got '$3')"; fail=1; fi
}
value() { /usr/libexec/PlistBuddy -c "Print :$1" "$OUT" 2>/dev/null || true; }
expectReject() { # expectReject <name> <args...>
    local name="$1"; shift
    if bash "$GEN" "$@" >"$WORK/reject.log" 2>&1; then
        echo "FAIL $name (unexpected success)"; fail=1
    else
        echo "ok   $name"; fi
    cmp -s "$OUT" "$WORK/good.plist" || { echo "FAIL $name output changed"; fail=1; }
}

cat > "$TEMPLATE" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Fixture</string>
<key>CFBundleShortVersionString</key><string>$(MARKETING_VERSION)</string>
<key>CFBundleVersion</key><string>$(CURRENT_PROJECT_VERSION)</string>
<key>UnrelatedKey</key><string>preserved-value</string>
</dict></plist>
EOF
cp "$TEMPLATE" "$WORK/template-original.plist"

mkdir -p "$REPO" && cd "$REPO"
git init -q
git config user.name "Versioning Fixture" && git config user.email "fixture@example.invalid"
git config commit.gpgsign false
echo "one" > tracked.txt && git add tracked.txt && git commit -qm "first"
FIRST="$(git rev-parse HEAD)"

bash "$GEN" "$REPO" "$TEMPLATE" "$OUT" "0.1.0" >/dev/null
expect "clean HEAD build=1" "1" "$(value CFBundleVersion)"
expect "clean HEAD revision" "$FIRST" "$(value NarrationAppsGitRevision)"
expect "clean HEAD unmodified" "false" "$(value NarrationAppsSourceModified)"
expect "marketing stamped" "0.1.0" "$(value CFBundleShortVersionString)"
expect "unrelated key survives" "preserved-value" "$(value UnrelatedKey)"
cmp -s "$TEMPLATE" "$WORK/template-original.plist"; check "source template untouched" $?

cp "$OUT" "$WORK/first.plist"
bash "$GEN" "$REPO" "$TEMPLATE" "$OUT" "0.1.0" >/dev/null
cmp -s "$OUT" "$WORK/first.plist"; check "same-state repeat identical" $?

echo "two" >> tracked.txt && git add tracked.txt && git commit -qm "second"
bash "$GEN" "$REPO" "$TEMPLATE" "$OUT" "0.1.0" >/dev/null
expect "second commit increments" "2" "$(value CFBundleVersion)"

# Dirty states: staged, unstaged and untracked flag modified; ignored do not.
echo "ignored-*.log" > .gitignore && git add .gitignore && git commit -qm "ignore"
bash "$GEN" "$REPO" "$TEMPLATE" "$OUT" "0.1.0" >/dev/null
expect "clean again" "false" "$(value NarrationAppsSourceModified)"
echo "x" >> tracked.txt
bash "$GEN" "$REPO" "$TEMPLATE" "$OUT" "0.1.0" >/dev/null
expect "unstaged flags" "true" "$(value NarrationAppsSourceModified)"
git add tracked.txt
bash "$GEN" "$REPO" "$TEMPLATE" "$OUT" "0.1.0" >/dev/null
expect "staged flags" "true" "$(value NarrationAppsSourceModified)"
git checkout -q HEAD -- tracked.txt && rm -f "$OUT"
echo "scratch" > newfile.txt
bash "$GEN" "$REPO" "$TEMPLATE" "$OUT" "0.1.0" >/dev/null
expect "untracked flags" "true" "$(value NarrationAppsSourceModified)"
rm newfile.txt && echo "tmp" > ignored-run.log
bash "$GEN" "$REPO" "$TEMPLATE" "$OUT" "0.1.0" >/dev/null
expect "ignored outputs do not flag" "false" "$(value NarrationAppsSourceModified)"
rm ignored-run.log

# Detached HEAD still produces count/revision.
git checkout -q --detach HEAD
bash "$GEN" "$REPO" "$TEMPLATE" "$OUT" "0.1.0" >/dev/null
expect "detached HEAD works" "3" "$(value CFBundleVersion)"
git checkout -q -

# Failure paths preserve the previous output.
cp "$OUT" "$WORK/good.plist"
expectReject "non-Git root fails" "$WORK" "$TEMPLATE" "$OUT" "0.1.0"
expectReject "malformed version fails" "$REPO" "$TEMPLATE" "$OUT" "not.a.version!!"
SHALLOW="$WORK/shallow repo"
git clone -q --depth 1 "file://$REPO" "$SHALLOW"
if bash "$GEN" "$SHALLOW" "$TEMPLATE" "$SHALLOW/out.plist" "0.1.0" >"$WORK/reject.log" 2>&1; then
    echo "FAIL shallow clone (unexpected success)"; fail=1; else echo "ok   shallow clone fails"; fi
[ ! -f "$SHALLOW/out.plist" ] && echo "ok   shallow creates nothing" || { echo "FAIL shallow created output"; fail=1; }

# Marketing validation rejects missing/extra components, prerelease text,
# leading zeros and control characters without writing.
for bad in "1.0" "1" "1.2.3.4" "01.2.3" "1.02.3" "1.0.0-beta.1" "1.0.0
" "a.b.c"; do
    expectReject "version '$bad' fails" "$REPO" "$TEMPLATE" "$OUT" "$bad"
done

# Unborn HEAD cannot produce a build number.
UNBORN="$WORK/unborn repo"
mkdir -p "$UNBORN" && git -C "$UNBORN" init -q
if bash "$GEN" "$UNBORN" "$TEMPLATE" "$UNBORN/out.plist" "0.1.0" >"$WORK/reject.log" 2>&1; then
    echo "FAIL unborn HEAD (unexpected success)"; fail=1; else echo "ok   unborn HEAD fails"; fi
[ ! -f "$UNBORN/out.plist" ] && echo "ok   unborn creates nothing" || { echo "FAIL unborn created output"; fail=1; }

# A git that can inspect everything except `status` must still refuse to
# stamp clean metadata.
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/git" <<'EOF'
#!/bin/bash
for arg in "$@"; do
    if [ "$arg" = "status" ]; then echo "fixture status failure" >&2; exit 129; fi
done
exec /usr/bin/git "$@"
EOF
chmod +x "$FAKEBIN/git"
if PATH="$FAKEBIN:$PATH" bash "$GEN" "$REPO" "$TEMPLATE" "$OUT" "0.1.0" >"$WORK/reject.log" 2>&1; then
    echo "FAIL status failure (unexpected success)"; fail=1; else echo "ok   status failure refuses" ; fi
cmp -s "$OUT" "$WORK/good.plist" && echo "ok   status failure preserves output" || { echo "FAIL status failure changed output"; fail=1; }

# A git that exits 0 but warns (incomplete read) must not stamp clean either.
cat > "$FAKEBIN/git" <<'EOF'
#!/bin/bash
for arg in "$@"; do
    if [ "$arg" = "status" ]; then echo "warning: could not open directory 'Sources/': Operation not permitted" >&2; exit 0; fi
done
exec /usr/bin/git "$@"
EOF
if PATH="$FAKEBIN:$PATH" bash "$GEN" "$REPO" "$TEMPLATE" "$OUT" "0.1.0" >"$WORK/reject.log" 2>&1; then
    echo "FAIL status warning (unexpected success)"; fail=1; else echo "ok   status warning refuses"; fi
cmp -s "$OUT" "$WORK/good.plist" && echo "ok   status warning preserves output" || { echo "FAIL status warning changed output"; fail=1; }

if [ "$fail" -eq 0 ]; then echo "test-app-versioning: all checks passed"; else echo "test-app-versioning: FAILURES"; fi
exit "$fail"
