#!/bin/bash
# Removes a MultiClaude account. Its data (sign-in, sessions) is kept unless --purge.
#
#   ./uninstall.sh                 remove the only account (asks for a name when there are several)
#   ./uninstall.sh "Claude C"      remove that account
#   ./uninstall.sh --all           remove every account
#   ... --purge                    also move the account's data to the Trash
#
# The link router and its login item go away with the last account.
set -euo pipefail

ROOT="$HOME/Library/Application Support/MultiClaude"
ROUTER="$ROOT/Claude Router.app"
ROUTER_ID="app.multiclaude.router"
AGENT_PLIST="$HOME/Library/LaunchAgents/$ROUTER_ID.plist"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
STAMP="$(date +%Y%m%d-%H%M%S)"

NAMES=() ALL=0 PURGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --all) ALL=1; shift ;;
    --purge) PURGE=1; shift ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
    *) NAMES+=("$1"); shift ;;
  esac
done

INSTALLED=()
while IFS= read -r d; do INSTALLED+=("$(basename "$d")"); done < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '*.app' 2>/dev/null | sort)
if [ "$ALL" = 1 ]; then NAMES=("${INSTALLED[@]+"${INSTALLED[@]}"}"); fi
if [ ${#NAMES[@]} -eq 0 ]; then
  if [ ${#INSTALLED[@]} -eq 1 ]; then NAMES=("${INSTALLED[0]}")
  elif [ ${#INSTALLED[@]} -eq 0 ]; then echo "No MultiClaude account is installed."; NAMES=()
  else echo "Several accounts are installed: ${INSTALLED[*]}" >&2; echo "Name one, or use --all." >&2; exit 2; fi
fi

stop() { ps -axwwo pid=,command= | grep -F "$1/Contents/MacOS/" | grep -v grep | awk '{print $1}' | while read -r pid; do kill "$pid" 2>/dev/null || true; done || true; }
trash() { [ -e "$1" ] && mv "$1" "$HOME/.Trash/$2 $STAMP" || true; }

DOCK_CHANGED=0
for NAME in "${NAMES[@]+"${NAMES[@]}"}"; do
  APP="/Applications/$NAME.app"; COPY_DIR="$ROOT/$NAME"; DATA_DIR="$HOME/Library/Application Support/$NAME"
  [ -d "$COPY_DIR" ] || [ -e "$APP" ] || { echo "$NAME is not installed."; continue; }
  if ps -axwwo command= | grep -F "$COPY_DIR/Claude.app/Contents/MacOS/Claude" | grep -qv grep; then echo "Quit $NAME first." >&2; exit 1; fi
  stop "$APP"
  if [ -e "$APP" ]; then "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true; trash "$APP" "$NAME.app"; fi
  # its Dock tile
  if /usr/bin/python3 - "$COPY_DIR/Claude.app" <<'PY'
import plistlib, subprocess, sys, urllib.parse
target = "file://" + urllib.parse.quote(sys.argv[1].rstrip("/")) + "/"
d = plistlib.loads(subprocess.run(["defaults", "export", "com.apple.dock", "-"], capture_output=True, check=True).stdout)
apps = d.get("persistent-apps", [])
kept = [e for e in apps if e.get("tile-data", {}).get("file-data", {}).get("_CFURLString", "") != target]
if len(kept) == len(apps): sys.exit(1)
d["persistent-apps"] = kept
subprocess.run(["defaults", "import", "com.apple.dock", "-"], input=plistlib.dumps(d), check=True)
PY
  then DOCK_CHANGED=1; fi
  # the copy can always be rebuilt from /Applications/Claude.app; the data is the account itself
  "$LSREGISTER" -u "$COPY_DIR/Claude.app" >/dev/null 2>&1 || true
  trash "$COPY_DIR" "$NAME copy"
  if [ "$PURGE" = 1 ]; then
    trash "$DATA_DIR" "$NAME data"
    echo "$NAME removed; its data is in the Trash."
  else
    echo "$NAME removed. Its data is kept in: $DATA_DIR"
  fi
done
if [ "$DOCK_CHANGED" = 1 ]; then killall Dock 2>/dev/null || true; fi

# The router serves every account: it only goes with the last one.
LEFT="$(find "$ROOT" -mindepth 2 -maxdepth 2 -name Claude.app 2>/dev/null | wc -l | tr -d ' ')"
if [ "$LEFT" = "0" ] && { [ -e "$ROUTER" ] || [ -f "$AGENT_PLIST" ]; }; then
  launchctl bootout "gui/$(id -u)/$ROUTER_ID" >/dev/null 2>&1 || true
  stop "$ROUTER"
  if [ -f "$AGENT_PLIST" ]; then trash "$AGENT_PLIST" "$ROUTER_ID.plist"; fi
  if [ -e "$ROUTER" ]; then "$LSREGISTER" -u "$ROUTER" >/dev/null 2>&1 || true; trash "$ROUTER" "Claude Router.app"; fi
  "$LSREGISTER" -f /Applications/Claude.app >/dev/null 2>&1 || true
  echo "Router removed. Restart Claude once so it takes its claude:// links back."
fi
