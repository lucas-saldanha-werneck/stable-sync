#!/bin/bash
# Tests for op-stable-sync and install.sh. Everything runs in a temp folder with a fake HOME, a fake
# "op" binary, a fake codesign and a fake launchctl. Nothing touches your real binaries, permissions
# or launchd. Run: bash tests/run.sh
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
H="$W/home"; mkdir -p "$H/.local/bin"
export HOME="$H" STABLE_SYNC_LOG_DIR="$W/logs"
fakebin() { printf '#!/bin/sh\necho %s\n' "$2" > "$1"; chmod +x "$1"; }

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
# SSC-06: no `readlink -f` (macOS before 12.3) and no python3: the shell fallback resolves links
ln -s "$W/op-src" "$W/probe" 2>/dev/null
if [ -L "$W/probe" ]; then
  RL="$(command -v readlink)"; mkdir -p "$W/oldmac"
  printf '#!/bin/sh\n[ "$1" = -f ] && exit 1\nexec %s "$@"\n' "$RL" > "$W/oldmac/readlink"
  printf '#!/bin/sh\nexit 1\n' > "$W/oldmac/python3"; chmod +x "$W/oldmac/readlink" "$W/oldmac/python3"
  mkdir -p "$W/chain/a" "$W/chain/b"; fakebin "$W/chain/b/real-op" opchain
  ln -s ../b/real-op "$W/chain/a/link1"; ln -s "$W/chain/a/link1" "$W/chain/link2"
  PATH="$W/oldmac:$PATH" OP_STABLE_SOURCE="$W/chain/link2" OP_STABLE_DEST="$W/oldmac-copy/op" sh "$OSS" 2>/dev/null
  [ "$(sh "$W/oldmac-copy/op" 2>/dev/null)" = opchain ] && grep -q "chain/b/real-op" "$OPLOG" \
    && ok "no readlink -f and no python3: shell fallback follows relative links" || bad "fallback: $(tail -1 "$OPLOG")"
  ln -sf "$W/opdest/op" "$W/selflink"
  OP_STABLE_SOURCE="$W/selflink" OP_STABLE_DEST="$W/opdest/op" sh "$OSS" 2>/dev/null; rc=$?
  [ $rc = 1 ] && grep -q "is the stable copy itself" "$OPLOG" && ok "source pointing at the copy: refused" || bad "rc=$rc"
else
  skip "symlink cases: this system makes copies instead of symlinks"
fi
# SSC-08: repeated failures raise one alert outside the log, and success resets the count
printf '#!/bin/sh\necho "$1" >> "%s/alerts"\n' "$W" > "$W/fakebin/alert"; chmod +x "$W/fakebin/alert"
printf '#!/bin/sh\necho vbad # BADSIG\n' > "$W/badsrc"; chmod +x "$W/badsrc"
for i in 1 2 3; do
  STABLE_SYNC_ALERT_CMD="$W/fakebin/alert" STABLE_SYNC_ALERT_AFTER=2 OP_STABLE_SOURCE="$W/badsrc" \
    OP_STABLE_DEST="$W/bad-copy/op" sh "$OSS" 2>/dev/null
done
[ "$(wc -l < "$W/alerts" 2>/dev/null | tr -d ' ')" = 1 ] && grep -q "op-stable-sync" "$W/alerts" \
  && ok "2 failures in a row: one alert; the 3rd stays quiet" || bad "alerts: $(cat "$W/alerts" 2>&1)"
fakebin "$W/badsrc" vgood
STABLE_SYNC_ALERT_CMD="$W/fakebin/alert" STABLE_SYNC_ALERT_AFTER=2 OP_STABLE_SOURCE="$W/badsrc" OP_STABLE_DEST="$W/bad-copy/op" sh "$OSS" 2>/dev/null
[ ! -e "$W/logs/op-stable-sync.failures" ] && ok "success resets the failure count" || bad "count kept"

echo "== install.sh"
I="$R/install.sh"
LA="$H/Library/LaunchAgents"
OUT=$(INSTALL_OS=Darwin OP_STABLE_SOURCE="$W/op-src" bash "$I" --dry-run)
[ ! -e "$H/.local/bin/op-stable-sync" ] && [ ! -e "$H/Library" ] && echo "$OUT" | grep -q "would write" && ok "--dry-run writes nothing" || bad "$OUT"
rm -f "$W/launchctl-calls"
OUT=$(env -u STABLE_SYNC_LOG_DIR INSTALL_OS=Darwin OP_STABLE_SOURCE="$W/op-src" bash "$I" --prefix org.example)
PO="$LA/org.example.op-stable-sync.plist"
[ -x "$H/.local/bin/op-stable-sync" ] && ok "tool copied" || bad "$OUT"
"$PY" - "$PO" <<'PYEOF' && ok "plist parses; label, real paths, watch paths, env" || bad "plist check failed"
import plistlib, sys
o = plistlib.load(open(sys.argv[1], "rb"))
assert o["Label"] == "org.example.op-stable-sync", o
assert o["ProgramArguments"][0] == "/bin/sh" and o["ProgramArguments"][1].endswith("/.local/bin/op-stable-sync"), o
assert o["WatchPaths"][0].endswith("/Caskroom/1password-cli") and o["WatchPaths"][1].endswith("/bin/op"), o
assert o["RunAtLoad"] is True and o["StartInterval"] == 3600, o
assert o["EnvironmentVariables"]["OP_STABLE_SOURCE"].endswith("/op-src"), o
assert "STABLE_SYNC_LOG_DIR" not in o["EnvironmentVariables"], o
PYEOF
grep -q "$H" "$PO" && ! grep -qF '$HOME' "$PO" && ok "home path expanded" || bad "home not expanded"
if command -v plutil >/dev/null 2>&1; then plutil -lint "$PO" >/dev/null && ok "plutil -lint" || bad "plutil -lint"; fi
[ ! -f "$W/launchctl-calls" ] && ok "nothing loaded without --load" || bad "launchctl called"
ls "$LA" "$H/.local/bin" | grep -qi claude && bad "something claude was written" || ok "no claude tool or job written"
OUT=$(INSTALL_OS=Darwin OP_STABLE_SOURCE="$W/op-src" bash "$I" --prefix org.example --load)
[ "$(grep -c '^bootstrap gui/' "$W/launchctl-calls" 2>/dev/null)" = 1 ] && ok "--load bootstraps the job (fake launchctl)" || bad "$OUT"
OUT=$(INSTALL_OS=Darwin OP_STABLE_SOURCE="$W/op-src" bash "$I" --prefix org.only --only op)
[ -f "$LA/org.only.op-stable-sync.plist" ] && ok "--only op still accepted" || bad "$OUT"
OUT=$(INSTALL_OS=Darwin bash "$I" --prefix org.noclaude --only claude 2>&1); rc=$?
[ $rc = 2 ] && echo "$OUT" | grep -q "removed" && ! ls "$LA" | grep -q org.noclaude && ok "--only claude: refused, nothing written" || bad "rc=$rc $OUT"
if [ ! -e /opt/homebrew/bin/op ] && [ ! -e /usr/local/bin/op ]; then
  OUT=$(INSTALL_OS=Darwin bash "$I" --prefix org.noop)
  echo "$OUT" | grep -q "not found: no job written" && ! ls "$LA" | grep -q org.noop && ok "op not installed: no job" || bad "$OUT"
else
  skip "op not installed case: this machine has op in Homebrew"
fi
OUT=$(INSTALL_OS=Linux OP_STABLE_SOURCE="$W/op-src" bash "$I" --prefix org.linux)
echo "$OUT" | grep -q "macOS-only" && ! ls "$LA" | grep -q org.linux && ok "non-macOS: no job" || bad "$OUT"
# SSC-05: STABLE_SYNC_LOG_DIR goes into the job (and its .err file)
OUT=$(INSTALL_OS=Darwin OP_STABLE_SOURCE="$W/op-src" STABLE_SYNC_LOG_DIR="$W/joblogs" bash "$I" --prefix org.logs)
"$PY" - "$LA/org.logs.op-stable-sync.plist" <<'PYEOF' && ok "STABLE_SYNC_LOG_DIR written into the job" || bad "log dir not in job: $OUT"
import plistlib, sys
c = plistlib.load(open(sys.argv[1], "rb"))
# Compared by the folder name: Git Bash on Windows rewrites path arguments for Python.
assert c["EnvironmentVariables"]["STABLE_SYNC_LOG_DIR"].endswith("/joblogs"), c
assert "/joblogs/" in c["StandardErrorPath"], c
PYEOF
# SSC-03: a failed copy of the tool stops the install with an error, and writes no job
printf x > "$W/notadir"
OUT=$(INSTALL_OS=Darwin OP_STABLE_SOURCE="$W/op-src" INSTALL_BIN_DIR="$W/notadir/bin" bash "$I" --prefix org.fail 2>&1); rc=$?
[ $rc != 0 ] && ! ls "$LA" | grep -q org.fail && ok "copy failure: rc=$rc, no job written" || bad "rc=$rc $OUT"
# SSC-04: a plist that does not validate never replaces the one in place
mkdir -p "$W/badplutil"; printf '#!/bin/sh\nexit 1\n' > "$W/badplutil/plutil"; chmod +x "$W/badplutil/plutil"
PK="$LA/org.keep.op-stable-sync.plist"; printf 'OLD\n' > "$PK"
OUT=$(PATH="$W/badplutil:$PATH" INSTALL_OS=Darwin OP_STABLE_SOURCE="$W/op-src" bash "$I" --prefix org.keep 2>&1); rc=$?
[ $rc != 0 ] && [ "$(cat "$PK")" = OLD ] && [ "$(ls "$LA" | grep -c org.keep)" = 1 ] \
  && ok "invalid new plist: old one kept, no temp left" || bad "rc=$rc $(cat "$PK") $OUT"
OUT=$(INSTALL_OS=Darwin bash "$I" --uninstall --prefix org.example)
[ ! -f "$PO" ] && [ ! -e "$H/.local/bin/op-stable-sync" ] && [ "$(grep -c '^bootout gui/.*org.example' "$W/launchctl-calls")" -ge 2 ] \
  && echo "$OUT" | grep -q "stable copy was kept" && ok "--uninstall removes the tool and the job, keeps the copy" || bad "$OUT"

echo
echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
[ $FAIL -eq 0 ]
