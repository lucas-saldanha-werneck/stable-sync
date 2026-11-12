#!/bin/bash
# install.sh - copy op-stable-sync into ~/.local/bin and write its launchd job with your real
# paths. Loads nothing unless --load.
#
#   ./install.sh [--dry-run] [--load] [--prefix com.stable-sync.]
#   ./install.sh --uninstall [--dry-run]
#
# Environment: INSTALL_BIN_DIR (default ~/.local/bin). OP_STABLE_SOURCE, OP_STABLE_DEST,
# STABLE_SYNC_LOG_DIR, OP_STABLE_TEAM_ID, STABLE_SYNC_ALERT_AFTER and STABLE_SYNC_ALERT_CMD,
# when set, are written into the job.
set -u
R="$(cd "$(dirname "$0")" && pwd)"
BIN="${INSTALL_BIN_DIR:-$HOME/.local/bin}"
LA="$HOME/Library/LaunchAgents"
LOGDIR="${STABLE_SYNC_LOG_DIR:-$HOME/Library/Logs}"
PREFIX="${STABLE_SYNC_LABEL_PREFIX:-com.stable-sync.}"
OS="${INSTALL_OS:-$(uname -s)}"   # INSTALL_OS: test hook
DRY=0; LOAD=0; UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --load) LOAD=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --only)  # kept so old commands work: op is the only tool now
      case "${2:-}" in
        op) ;;
        *) echo "install.sh: --only takes only op (claude-stable-sync was removed, see README)" >&2; exit 2 ;;
      esac; shift ;;
    --prefix) PREFIX="${2:-}"; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "install.sh: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
case "$PREFIX" in *.) ;; *) PREFIX="$PREFIX." ;; esac
T=op-stable-sync
LABEL="${PREFIX}$T"
P="$LA/$LABEL.plist"

run() { if [ $DRY = 1 ]; then echo "(dry-run) $*"; else "$@"; fi; }
have_launchctl() { [ "$OS" = Darwin ] && command -v launchctl >/dev/null 2>&1; }
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

if [ $UNINSTALL = 1 ]; then
  if [ -f "$P" ]; then
    have_launchctl && run launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
    run rm -f "$P" && echo "removed $P"
  fi
  [ -e "$BIN/$T" ] && run rm -f "$BIN/$T" && echo "removed $BIN/$T"
  echo "The stable copy was kept (your privacy permissions point at it). Delete it yourself if you want:"
  echo "  ${OP_STABLE_DEST:-$HOME/.local/bin/op}"
  exit 0
fi

run mkdir -p "$BIN" || { echo "install.sh: cannot create $BIN" >&2; exit 1; }
{ run cp "$R/bin/$T" "$BIN/$T" && run chmod 755 "$BIN/$T"; } \
  || { echo "install.sh: could not install $BIN/$T; no job written" >&2; exit 1; }
echo "installed $BIN/$T"

if [ "$OS" != Darwin ]; then
  echo "launchd is macOS-only: no job written. Run the tool by hand or from cron if you want."
  exit 0
fi

BREW="$(brew --prefix 2>/dev/null || true)"
[ -n "$BREW" ] || { [ -d /opt/homebrew ] && BREW=/opt/homebrew || BREW=/usr/local; }

env_block() {  # EnvironmentVariables with the variables that are set
  local out="" n v
  for n in OP_STABLE_SOURCE OP_STABLE_DEST OP_STABLE_TEAM_ID \
           STABLE_SYNC_LOG_DIR STABLE_SYNC_ALERT_AFTER STABLE_SYNC_ALERT_CMD; do
    v="$(eval "printf '%s' \"\${$n:-}\"")"
    [ -n "$v" ] && out="$out
		<key>$n</key>
		<string>$(xml_escape "$v")</string>"
  done
  [ -n "$out" ] && printf '\t<key>EnvironmentVariables</key>\n\t<dict>%s\n\t</dict>\n' "$out"
}

valid_plist() {  # plutil on macOS, else Python's plistlib, else trust the heredoc
  if command -v plutil >/dev/null 2>&1; then plutil -lint -s "$1" >/dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then python3 -c 'import plistlib,sys; plistlib.load(open(sys.argv[1],"rb"))' "$1" 2>/dev/null
  else return 0; fi
}

plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/sh</string>
		<string>$(xml_escape "$BIN/$T")</string>
	</array>
$(env_block)
	<key>WatchPaths</key>
	<array>
		<string>$(xml_escape "$BREW/Caskroom/1password-cli")</string>
		<string>$(xml_escape "$BREW/bin/op")</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>3600</integer>
	<key>StandardErrorPath</key>
	<string>$(xml_escape "$LOGDIR/$T.err")</string>
</dict>
</plist>
EOF
}

if [ -z "${OP_STABLE_SOURCE:-}" ] && [ ! -e /opt/homebrew/bin/op ] && [ ! -e /usr/local/bin/op ]; then
  echo "op (1Password CLI) not found: no job written (set OP_STABLE_SOURCE to write it anyway)"
  exit 0
fi
if [ $DRY = 1 ]; then
  echo "(dry-run) would write $P:"; plist
else
  mkdir -p "$LA" "$LOGDIR" || { echo "install.sh: cannot create $LA or $LOGDIR" >&2; exit 1; }
  # Written next to the old plist, checked, then moved over it: a failure leaves the old one.
  TMPP=$(mktemp "$P.tmp.XXXXXX") || { echo "install.sh: cannot write in $LA" >&2; exit 1; }
  if ! { plist | grep -v '^$' > "$TMPP" && valid_plist "$TMPP" && mv -f "$TMPP" "$P"; }; then
    rm -f "$TMPP"; echo "install.sh: could not write a valid $P; the old one (if any) is kept" >&2; exit 1
  fi
  echo "wrote $P"
fi
if [ $LOAD = 1 ]; then
  if have_launchctl; then
    run launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
    run launchctl bootstrap "gui/$(id -u)" "$P" && echo "loaded $LABEL"
  else
    echo "launchctl not found: $LABEL not loaded"
  fi
else
  echo "not loaded. Load with: launchctl bootstrap gui/\$(id -u) '$P'  (or re-run with --load)"
fi
