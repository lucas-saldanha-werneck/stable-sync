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
  'case "$*" in *-R*) grep -q ADHOC "$f" && exit 1 ;; esac' \
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
if [ $SYMLINKS = 1 ]; then
  # SSC-06: no `readlink -f` (macOS before 12.3) and no python3: the shell fallback resolves links
  RL="$(command -v readlink)"; mkdir -p "$W/oldmac"
  printf '#!/bin/sh\n[ "$1" = -f ] && exit 1\nexec %s "$@"\n' "$RL" > "$W/oldmac/readlink"
  printf '#!/bin/sh\nexit 1\n' > "$W/oldmac/python3"; chmod +x "$W/oldmac/readlink" "$W/oldmac/python3"
  mkdir -p "$W/chain/a" "$W/chain/b"; fakebin "$W/chain/b/real-claude" vchain
  ln -s ../b/real-claude "$W/chain/a/link1"; ln -s "$W/chain/a/link1" "$W/chain/link2"
  PATH="$W/oldmac:$PATH" CLAUDE_STABLE_SOURCE="$W/chain/link2" CLAUDE_STABLE_DIR="$W/oldmac-copy" sh "$CSS" 2>/dev/null
  [ "$(sh "$W/oldmac-copy/claude" 2>/dev/null)" = vchain ] && grep -q "chain/b/real-claude" "$W/oldmac-copy/.source" \
    && ok "no readlink -f and no python3: shell fallback follows relative links" || bad "fallback: $(tail -1 "$LOGF")"
fi
# SSC-02: a source file updated in place (same path) is copied again
fakebin "$W/inplace" vA
CLAUDE_STABLE_SOURCE="$W/inplace" CLAUDE_STABLE_DIR="$W/inplace-copy" sh "$CSS" 2>/dev/null
sleep 1; fakebin "$W/inplace" vB-longer
CLAUDE_STABLE_SOURCE="$W/inplace" CLAUDE_STABLE_DIR="$W/inplace-copy" sh "$CSS" 2>/dev/null
[ "$(sh "$W/inplace-copy/claude")" = vB-longer ] && ok "source changed in place: copied again" || bad "stale copy: $(sh "$W/inplace-copy/claude")"
# SSC-07: the signature must come from the expected team; an ad-hoc signature is refused
: > "$W/codesign-calls"
printf '#!/bin/sh\necho vadhoc # ADHOC\n' > "$W/adhoc"; chmod +x "$W/adhoc"
CLAUDE_STABLE_SOURCE="$W/adhoc" CLAUDE_STABLE_DIR="$W/adhoc-copy" sh "$CSS" 2>/dev/null; rc=$?
[ $rc = 1 ] && [ ! -e "$W/adhoc-copy/claude" ] && grep -q 'Q6L2SF6YDW' "$W/codesign-calls" \
  && ok "ad-hoc signature refused; team id required (default Anthropic)" || bad "rc=$rc $(cat "$W/codesign-calls")"
CLAUDE_STABLE_TEAM_ID= CLAUDE_STABLE_SOURCE="$W/adhoc" CLAUDE_STABLE_DIR="$W/adhoc-copy" sh "$CSS" 2>/dev/null
[ "$(sh "$W/adhoc-copy/claude")" = vadhoc ] && ok "CLAUDE_STABLE_TEAM_ID empty: any valid signature" || bad "team id off"
# SSC-08: repeated failures raise one alert outside the log, and success resets the count
printf '#!/bin/sh\necho "$1" >> "%s/alerts"\n' "$W" > "$W/fakebin/alert"; chmod +x "$W/fakebin/alert"
printf '#!/bin/sh\necho vbad # BADSIG\n' > "$W/badsrc"; chmod +x "$W/badsrc"
for i in 1 2 3; do
  STABLE_SYNC_ALERT_CMD="$W/fakebin/alert" STABLE_SYNC_ALERT_AFTER=2 CLAUDE_STABLE_SOURCE="$W/badsrc" \
    CLAUDE_STABLE_DIR="$W/bad-copy" sh "$CSS" 2>/dev/null
done
[ "$(wc -l < "$W/alerts" 2>/dev/null | tr -d ' ')" = 1 ] && grep -q "claude-stable-sync" "$W/alerts" \
  && ok "2 failures in a row: one alert; the 3rd stays quiet" || bad "alerts: $(cat "$W/alerts" 2>&1)"
fakebin "$W/badsrc" vgood
STABLE_SYNC_ALERT_CMD="$W/fakebin/alert" STABLE_SYNC_ALERT_AFTER=2 CLAUDE_STABLE_SOURCE="$W/badsrc" CLAUDE_STABLE_DIR="$W/bad-copy" sh "$CSS" 2>/dev/null
[ ! -e "$W/logs/claude-stable-sync.failures" ] && ok "success resets the failure count" || bad "count kept"
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
# SSC-01: the temp file is unique (mktemp), so a fixed $DST.new left by another run does not matter
mkdir -p "$W/opdest2/op.new"
OP_STABLE_SOURCE="$W/op-src" OP_STABLE_DEST="$W/opdest2/op" sh "$OSS" 2>/dev/null; rc=$?
[ $rc = 0 ] && [ "$(sh "$W/opdest2/op" 2>/dev/null)" = op3 ] && [ -d "$W/opdest2/op.new" ] && [ -z "$(ls -A "$W/opdest2/op.new")" ] \
  && [ "$(ls "$W/opdest2" | wc -l | tr -d ' ')" = 2 ] && ok "unique temp file, nothing left behind" || bad "rc=$rc $(ls -R "$W/opdest2")"
printf '#!/bin/sh\necho opadhoc # ADHOC\n' > "$W/op-adhoc"; chmod +x "$W/op-adhoc"
OP_STABLE_SOURCE="$W/op-adhoc" OP_STABLE_DEST="$W/opdest3/op" sh "$OSS" 2>/dev/null; rc=$?
[ $rc = 1 ] && [ ! -e "$W/opdest3/op" ] && grep -q '2BUA8C4S2C' "$W/codesign-calls" && ok "op: ad-hoc signature refused (team id)" || bad "rc=$rc"

echo "== install.sh"
I="$R/install.sh"
OUT=$(INSTALL_OS=Darwin OP_STABLE_SOURCE="$W/op-src" bash "$I" --dry-run)
[ ! -e "$H/.local/bin/claude-stable-sync" ] && [ ! -e "$H/Library" ] && echo "$OUT" | grep -q "would write" && ok "--dry-run writes nothing" || bad "$OUT"
rm -f "$W/launchctl-calls"
OUT=$(env -u STABLE_SYNC_LOG_DIR INSTALL_OS=Darwin OP_STABLE_SOURCE="$W/op-src" bash "$I" --prefix org.example)
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
# SSC-05: STABLE_SYNC_LOG_DIR goes into both jobs (and their .err files)
OUT=$(INSTALL_OS=Darwin STABLE_SYNC_LOG_DIR="$W/joblogs" bash "$I" --prefix org.logs)
"$PY" - "$H/Library/LaunchAgents/org.logs.claude-stable-sync.plist" "$W/joblogs" <<'EOF' && ok "STABLE_SYNC_LOG_DIR written into the job" || bad "log dir not in job: $OUT"
import plistlib, sys
c = plistlib.load(open(sys.argv[1], "rb"))
# Compared by the folder name: Git Bash on Windows rewrites path arguments for Python.
assert c["EnvironmentVariables"]["STABLE_SYNC_LOG_DIR"].endswith("/joblogs"), c
assert "/joblogs/" in c["StandardErrorPath"], c
EOF
# SSC-03: a failed copy of the tool stops the install with an error, and writes no job
printf x > "$W/notadir"
OUT=$(INSTALL_OS=Darwin INSTALL_BIN_DIR="$W/notadir/bin" bash "$I" --prefix org.fail 2>&1); rc=$?
[ $rc != 0 ] && ! ls "$H/Library/LaunchAgents/" | grep -q org.fail && ok "copy failure: rc=$rc, no job written" || bad "rc=$rc $OUT"
# SSC-04: a plist that does not validate never replaces the one in place
mkdir -p "$W/badplutil"; printf '#!/bin/sh\nexit 1\n' > "$W/badplutil/plutil"; chmod +x "$W/badplutil/plutil"
PK="$H/Library/LaunchAgents/org.keep.claude-stable-sync.plist"; printf 'OLD\n' > "$PK"
OUT=$(PATH="$W/badplutil:$PATH" INSTALL_OS=Darwin bash "$I" --prefix org.keep --only claude 2>&1); rc=$?
[ $rc != 0 ] && [ "$(cat "$PK")" = OLD ] && [ "$(ls "$H/Library/LaunchAgents/" | grep -c org.keep)" = 1 ] \
  && ok "invalid new plist: old one kept, no temp left" || bad "rc=$rc $(cat "$PK") $OUT"
OUT=$(INSTALL_OS=Darwin bash "$I" --uninstall --prefix org.example)
[ ! -f "$PC" ] && [ ! -f "$PO" ] && [ ! -e "$H/.local/bin/claude-stable-sync" ] && [ "$(grep -c '^bootout gui/.*org.example' "$W/launchctl-calls")" -ge 4 ] \
  && echo "$OUT" | grep -q "stable copies were kept" && ok "--uninstall removes tools and jobs, keeps the copies" || bad "$OUT"

echo
echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
[ $FAIL -eq 0 ]
