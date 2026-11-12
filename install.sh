#!/bin/bash
# install.sh - copy claude-stable-sync and op-stable-sync into ~/.local/bin and write their launchd
# jobs with your real paths. Loads nothing unless --load.
#
#   ./install.sh [--dry-run] [--load] [--only claude|op] [--prefix com.stable-sync.]
#   ./install.sh --uninstall [--dry-run]
#
# Environment: INSTALL_BIN_DIR (default ~/.local/bin). CLAUDE_STABLE_SOURCE, CLAUDE_STABLE_DIR,
# OP_STABLE_SOURCE, OP_STABLE_DEST, STABLE_SYNC_LOG_DIR, CLAUDE_STABLE_TEAM_ID, OP_STABLE_TEAM_ID,
# STABLE_SYNC_ALERT_AFTER and STABLE_SYNC_ALERT_CMD, when set, are written into the jobs.
set -u
R="$(cd "$(dirname "$0")" && pwd)"
BIN="${INSTALL_BIN_DIR:-$HOME/.local/bin}"
LA="$HOME/Library/LaunchAgents"
LOGDIR="${STABLE_SYNC_LOG_DIR:-$HOME/Library/Logs}"
PREFIX="${STABLE_SYNC_LABEL_PREFIX:-com.stable-sync.}"
OS="${INSTALL_OS:-$(uname -s)}"   # INSTALL_OS: test hook
DRY=0; LOAD=0; UNINSTALL=0; ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --load) LOAD=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --only) ONLY="${2:-}"; shift ;;
    --prefix) PREFIX="${2:-}"; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "install.sh: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
case "$ONLY" in ""|claude|op) ;; *) echo "install.sh: --only takes claude or op" >&2; exit 2 ;; esac
case "$PREFIX" in *.) ;; *) PREFIX="$PREFIX." ;; esac
TOOLS=""
[ "$ONLY" != op ] && TOOLS="$TOOLS claude"
[ "$ONLY" != claude ] && TOOLS="$TOOLS op"

run() { if [ $DRY = 1 ]; then echo "(dry-run) $*"; else "$@"; fi; }
have_launchctl() { [ "$OS" = Darwin ] && command -v launchctl >/dev/null 2>&1; }
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

if [ $UNINSTALL = 1 ]; then
  for t in $TOOLS; do
    label="${PREFIX}$t-stable-sync"
    if [ -f "$LA/$label.plist" ]; then
      have_launchctl && run launchctl bootout "gui/$(id -u)/$label" 2>/dev/null
      run rm -f "$LA/$label.plist" && echo "removed $LA/$label.plist"
    fi
    [ -e "$BIN/$t-stable-sync" ] && run rm -f "$BIN/$t-stable-sync" && echo "removed $BIN/$t-stable-sync"
  done
  echo "The stable copies were kept (your privacy permissions point at them). Delete them yourself if you want:"
  echo "  ${CLAUDE_STABLE_DIR:-$HOME/.local/libexec/claude-stable}   ${OP_STABLE_DEST:-$HOME/.local/bin/op}"
  exit 0
fi

run mkdir -p "$BIN" || { echo "install.sh: cannot create $BIN" >&2; exit 1; }
for t in $TOOLS; do
  { run cp "$R/bin/$t-stable-sync" "$BIN/$t-stable-sync" && run chmod 755 "$BIN/$t-stable-sync"; } \
    || { echo "install.sh: could not install $BIN/$t-stable-sync; no job written" >&2; exit 1; }
  echo "installed $BIN/$t-stable-sync"
done

if [ "$OS" != Darwin ]; then
  echo "launchd is macOS-only: no jobs written. Run the tools by hand or from cron if you want."
  exit 0
fi

BREW="$(brew --prefix 2>/dev/null || true)"
[ -n "$BREW" ] || { [ -d /opt/homebrew ] && BREW=/opt/homebrew || BREW=/usr/local; }

env_block() {  # EnvironmentVariables with the variables that are set, for tool $1
  local names out="" n v
  if [ "$1" = claude ]; then names="CLAUDE_STABLE_SOURCE CLAUDE_STABLE_DIR CLAUDE_STABLE_TEAM_ID"
  else names="OP_STABLE_SOURCE OP_STABLE_DEST OP_STABLE_TEAM_ID"; fi
  names="$names STABLE_SYNC_LOG_DIR STABLE_SYNC_ALERT_AFTER STABLE_SYNC_ALERT_CMD"
  for n in $names; do
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

plist() {  # $1 = claude|op
  local t="$1" label="${PREFIX}$1-stable-sync" watch interval
  if [ "$t" = claude ]; then
    local src="${CLAUDE_STABLE_SOURCE:-$HOME/.local/bin/claude}"
    watch="		<string>$(xml_escape "$HOME/.local/share/claude/versions")</string>
		<string>$(xml_escape "$(dirname "$src")")</string>"
    interval=900
  else
    watch="		<string>$(xml_escape "$BREW/Caskroom/1password-cli")</string>
		<string>$(xml_escape "$BREW/bin/op")</string>"
    interval=3600
  fi
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/sh</string>
		<string>$(xml_escape "$BIN/$t-stable-sync")</string>
	</array>
$(env_block "$t")
	<key>WatchPaths</key>
	<array>
$watch
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>$interval</integer>
	<key>StandardErrorPath</key>
	<string>$(xml_escape "$LOGDIR/$t-stable-sync.err")</string>
</dict>
</plist>
EOF
}

for t in $TOOLS; do
  if [ "$t" = op ] && [ -z "$ONLY" ] && [ -z "${OP_STABLE_SOURCE:-}" ] \
     && [ ! -e /opt/homebrew/bin/op ] && [ ! -e /usr/local/bin/op ]; then
    echo "op (1Password CLI) not found: skipped its job (use --only op to write it anyway)"
    continue
  fi
  label="${PREFIX}$t-stable-sync"
  P="$LA/$label.plist"
  if [ $DRY = 1 ]; then
    echo "(dry-run) would write $P:"; plist "$t"
  else
    mkdir -p "$LA" "$LOGDIR" || { echo "install.sh: cannot create $LA or $LOGDIR" >&2; exit 1; }
    # Written next to the old plist, checked, then moved over it: a failure leaves the old one.
    TMPP=$(mktemp "$P.tmp.XXXXXX") || { echo "install.sh: cannot write in $LA" >&2; exit 1; }
    if ! { plist "$t" | grep -v '^$' > "$TMPP" && valid_plist "$TMPP" && mv -f "$TMPP" "$P"; }; then
      rm -f "$TMPP"; echo "install.sh: could not write a valid $P; the old one (if any) is kept" >&2; exit 1
    fi
    echo "wrote $P"
  fi
  if [ $LOAD = 1 ]; then
    if have_launchctl; then
      run launchctl bootout "gui/$(id -u)/$label" 2>/dev/null
      run launchctl bootstrap "gui/$(id -u)" "$P" && echo "loaded $label"
    else
      echo "launchctl not found: $label not loaded"
    fi
  else
    echo "not loaded. Load with: launchctl bootstrap gui/\$(id -u) '$P'  (or re-run with --load)"
  fi
done
