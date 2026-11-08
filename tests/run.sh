#!/bin/bash
# Tests for claude-stable-sync, op-stable-sync and install.sh. Everything runs in a temp folder with a
# fake HOME, fake "claude" / "op" binaries, a fake codesign and a fake launchctl. Nothing touches
# your real binaries, permissions or launchd. Run: bash tests/run.sh
T="$(cd "$(dirname "$0")" && pwd)"
R="$(dirname "$T")"
W="$(mktemp -d "${TMPDIR:-/tmp}/stable-sync-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0; SKIP=0
ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP: $*"; SKIP=$((SKIP+1)); }
PY="$(command -v python3 || command -v python)"

mkdir -p "$W/fakebin"
# fake codesign: valid unless the file contains BADSIG
printf '%s\n' '#!/bin/sh' 'echo "$*" >> "$FAKE_DIR/codesign-calls"' 'f=""; for a; do f="$a"; done' \
  '! grep -q BADSIG "$f"' > "$W/fakebin/codesign"
printf '%s\n' '#!/bin/sh' 'echo "$*" >> "$FAKE_DIR/launchctl-calls"' > "$W/fakebin/launchctl"
chmod +x "$W/fakebin/codesign" "$W/fakebin/launchctl"
export FAKE_DIR="$W" PATH="$W/fakebin:$PATH" STABLE_SYNC_CODESIGN="$W/fakebin/codesign"
H="$W/home"; mkdir -p "$H/.local/bin" "$H/.local/share/claude/versions/1.0" "$H/.local/share/claude/versions/2.0"
export HOME="$H" STABLE_SYNC_LOG_DIR="$W/logs"
fakebin() { printf '#!/bin/sh\necho %s\n' "$2" > "$1"; chmod +x "$1"; }
fakebin "$H/.local/share/claude/versions/1.0/claude" v1
fakebin "$H/.local/share/claude/versions/2.0/claude" v2
CSS="$R/bin/claude-stable-sync"
COPY="$H/.local/libexec/claude-stable/claude"
LOGF="$W/logs/claude-stable-sync.log"

# Real symlinks? (Git Bash on Windows makes copies unless symlinks are enabled.)
ln -s "$H/.local/share/claude/versions/1.0/claude" "$W/probe" 2>/dev/null
if [ -L "$W/probe" ]; then SYMLINKS=1; else SYMLINKS=0; fi

echo "== claude-stable-sync"
if [ $SYMLINKS = 1 ]; then
  ln -sf "$H/.local/share/claude/versions/1.0/claude" "$H/.local/bin/claude"
  sh "$CSS" 2>/dev/null; rc=$?
  [ $rc = 0 ] && [ "$(sh "$COPY")" = v1 ] && [ ! -L "$COPY" ] && ok "first run: real copy of v1" || bad "rc=$rc $(cat "$LOGF" 2>&1)"
  grep -q "versions/1.0/claude" "$H/.local/libexec/claude-stable/.source" && ok "state file records the source" || bad "state"
  n=$(wc -l < "$LOGF"); sh "$CSS" 2>/dev/null
  [ "$(wc -l < "$LOGF")" = "$n" ] && ok "second run: no-op, nothing logged" || bad "re-copied: $(tail -1 "$LOGF")"
  ln -sf "$H/.local/share/claude/versions/2.0/claude" "$H/.local/bin/claude"
  sh "$CSS" 2>/dev/null
  [ "$(sh "$COPY")" = v2 ] && ok "after update: copy is v2 at the same path" || bad "copy: $(sh "$COPY")"
  printf '#!/bin/sh\necho v3 # BADSIG\n' > "$H/.local/share/claude/versions/2.0/claude"
  sh "$CSS" --force 2>/dev/null; rc=$?
  [ $rc = 1 ] && [ "$(sh "$COPY")" = v2 ] && grep -q "invalid code signature" "$LOGF" && ok "bad signature: kept previous copy, rc=1" || bad "rc=$rc copy=$(sh "$COPY")"
  ls "$H/.local/libexec/claude-stable/" | grep -q tmp && bad "temp file left behind" || ok "no temp file left"
  fakebin "$H/.local/share/claude/versions/2.0/claude" v2b
  STABLE_SYNC_CODESIGN=/nonexistent/codesign sh "$CSS" --force 2>/dev/null
  [ "$(sh "$COPY")" = v2b ] && grep -q "codesign not available" "$LOGF" && ok "no codesign: copies with a note" || bad "$(tail -2 "$LOGF")"
  ln -sf "$COPY" "$H/.local/bin/claude"
  sh "$CSS" --force 2>/dev/null; rc=$?
  [ $rc = 1 ] && grep -q "points at the stable copy itself" "$LOGF" && ok "source pointing at the copy: refused" || bad "rc=$rc"
else
  skip "symlink cases: this system makes copies instead of symlinks"
fi
CLAUDE_STABLE_SOURCE="$W/nothing" sh "$CSS" 2>/dev/null; rc=$?
[ $rc = 1 ] && grep -q "does not lead to an executable" "$LOGF" && ok "missing source: rc=1 with a clear log line" || bad "rc=$rc"
CLAUDE_STABLE_SOURCE="$H/.local/share/claude/versions/1.0/claude" CLAUDE_STABLE_DIR="$W/alt" sh "$CSS" 2>/dev/null
[ "$(sh "$W/alt/claude")" = v1 ] && ok "CLAUDE_STABLE_SOURCE / CLAUDE_STABLE_DIR honored (plain file source)" || bad "alt copy"

echo "== op-stable-sync"
OSS="$R/bin/op-stable-sync"
OPLOG="$W/logs/op-stable-sync.log"
fakebin "$W/op-src" op1
OP_STABLE_SOURCE="$W/none" sh "$OSS" 2>/dev/null; rc=$?
[ $rc = 0 ] && [ ! -e "$H/.local/bin/op" ] && ok "op not installed: quiet no-op" || bad "rc=$rc"
OP_STABLE_SOURCE="$W/op-src" sh "$OSS" 2>/dev/null
[ "$(sh "$H/.local/bin/op")" = op1 ] && ok "copies op" || bad "$(cat "$OPLOG" 2>&1)"
n=$(wc -l < "$OPLOG"); OP_STABLE_SOURCE="$W/op-src" sh "$OSS" 2>/dev/null
[ "$(wc -l < "$OPLOG")" = "$n" ] && ok "identical: no-op" || bad "re-copied"
printf '#!/bin/sh\necho op2 # BADSIG\n' > "$W/op-src"
OP_STABLE_SOURCE="$W/op-src" sh "$OSS" 2>/dev/null; rc=$?
[ $rc = 1 ] && [ "$(sh "$H/.local/bin/op")" = op1 ] && [ ! -e "$H/.local/bin/op.new" ] && ok "bad signature: kept op1" || bad "rc=$rc"
fakebin "$W/op-src" op3
OP_STABLE_SOURCE="$W/op-src" OP_STABLE_DEST="$W/opdest/op" sh "$OSS" 2>/dev/null
[ "$(sh "$W/opdest/op")" = op3 ] && ok "OP_STABLE_DEST honored" || bad "dest"

echo "== install.sh"
I="$R/install.sh"
OUT=$(INSTALL_OS=Darwin OP_STABLE_SOURCE="$W/op-src" bash "$I" --dry-run)
[ ! -e "$H/.local/bin/claude-stable-sync" ] && [ ! -e "$H/Library" ] && echo "$OUT" | grep -q "would write" && ok "--dry-run writes nothing" || bad "$OUT"
rm -f "$W/launchctl-calls"
OUT=$(INSTALL_OS=Darwin OP_STABLE_SOURCE="$W/op-src" bash "$I" --prefix org.example)
PC="$H/Library/LaunchAgents/org.example.claude-stable-sync.plist"
PO="$H/Library/LaunchAgents/org.example.op-stable-sync.plist"
[ -x "$H/.local/bin/claude-stable-sync" ] && [ -x "$H/.local/bin/op-stable-sync" ] && ok "tools copied" || bad "$OUT"
"$PY" - "$PC" "$PO" <<'EOF' && ok "both plists parse; labels, real paths, watch paths, env" || bad "plist check failed"
import plistlib, sys
c = plistlib.load(open(sys.argv[1], "rb")); o = plistlib.load(open(sys.argv[2], "rb"))
assert c["Label"] == "org.example.claude-stable-sync", c
assert c["ProgramArguments"][0] == "/bin/sh" and c["ProgramArguments"][1].endswith("/.local/bin/claude-stable-sync"), c
assert any(p.endswith("/.local/share/claude/versions") for p in c["WatchPaths"]), c
assert c["RunAtLoad"] is True and c["StartInterval"] == 900
assert "EnvironmentVariables" not in c, c
assert o["Label"] == "org.example.op-stable-sync" and o["WatchPaths"][0].endswith("/Caskroom/1password-cli"), o
assert o["EnvironmentVariables"]["OP_STABLE_SOURCE"].endswith("/op-src"), o
EOF
grep -q "$H" "$PC" && ! grep -qF '$HOME' "$PC" && ok "home path expanded" || bad "home not expanded"
if command -v plutil >/dev/null 2>&1; then plutil -lint "$PC" "$PO" >/dev/null && ok "plutil -lint" || bad "plutil -lint"; fi
[ ! -f "$W/launchctl-calls" ] && ok "nothing loaded without --load" || bad "launchctl called"
OUT=$(INSTALL_OS=Darwin OP_STABLE_SOURCE="$W/op-src" bash "$I" --prefix org.example --load)
[ "$(grep -c '^bootstrap gui/' "$W/launchctl-calls" 2>/dev/null)" = 2 ] && ok "--load bootstraps both jobs (fake launchctl)" || bad "$OUT"
OUT=$(INSTALL_OS=Darwin bash "$I" --prefix org.only --only claude)
[ -f "$H/Library/LaunchAgents/org.only.claude-stable-sync.plist" ] && [ ! -f "$H/Library/LaunchAgents/org.only.op-stable-sync.plist" ] && ok "--only claude" || bad "$OUT"
OUT=$(INSTALL_OS=Linux bash "$I" --prefix org.linux)
echo "$OUT" | grep -q "macOS-only" && ! ls "$H/Library/LaunchAgents/" | grep -q org.linux && ok "non-macOS: no jobs" || bad "$OUT"
OUT=$(INSTALL_OS=Darwin bash "$I" --uninstall --prefix org.example)
[ ! -f "$PC" ] && [ ! -f "$PO" ] && [ ! -e "$H/.local/bin/claude-stable-sync" ] && [ "$(grep -c '^bootout gui/.*org.example' "$W/launchctl-calls")" -ge 4 ] \
  && echo "$OUT" | grep -q "stable copies were kept" && ok "--uninstall removes tools and jobs, keeps the copies" || bad "$OUT"

echo
echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
[ $FAIL -eq 0 ]
