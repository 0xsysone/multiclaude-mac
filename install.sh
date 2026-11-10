#!/bin/bash
# MultiClaude — run several Claude Desktop apps side by side, one account each.
#
#   ./install.sh                         add a second Claude ("Claude B", green)
#   ./install.sh "Claude C"              add another account (next free colour)
#   ./install.sh "Claude C" --color blue green | blue | purple | pink | teal | yellow, or --hue <degrees>
#   ./install.sh --status                what is installed and running
#
# Options: --refresh-copy (rebuild the account's copy from /Applications/Claude.app),
#          --no-dock (leave the Dock alone), --no-agent (no login item: the router only runs while a copy does).
#
# Nothing is modified in /Applications/Claude.app. Safe to run again at any time, apps open or not.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REAL="/Applications/Claude.app"
BUILD="$HERE/build"
ROOT="$HOME/Library/Application Support/MultiClaude"
ROUTER="$ROOT/Claude Router.app"
ROUTER_ID="app.multiclaude.router"
AGENT_PLIST="$HOME/Library/LaunchAgents/$ROUTER_ID.plist"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

NAME="" COLOR="" HUE="" REFRESH=0 DOCK=1 AGENT=1 STATUS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --color) COLOR="${2:-}"; shift 2 ;;
    --hue) HUE="${2:-}"; shift 2 ;;
    --refresh-copy) REFRESH=1; shift ;;
    --no-dock) DOCK=0; shift ;;
    --no-agent) AGENT=0; shift ;;
    --status) STATUS=1; shift ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
    *) NAME="$1"; shift ;;
  esac
done
NAME="${NAME:-Claude B}"

die() { echo "error: $*" >&2; exit 1; }
[ "$(uname)" = "Darwin" ] || die "MultiClaude is for macOS."
[ -d "$REAL" ] || die "Claude.app was not found in /Applications. Install Claude Desktop first."
command -v swiftc >/dev/null || die "swiftc was not found. Install the Command Line Tools: xcode-select --install"

mkdir -p "$BUILD"
build_tools() {
  swiftc -O -o "$BUILD/hue" "$HERE/src/hue.swift" 2>&1 | grep -E "error" || true
  swiftc -O -o "$BUILD/multiclaude" "$HERE/src/MultiClaude.swift" 2>&1 | grep -E "error" || true
  [ -x "$BUILD/hue" ] && [ -x "$BUILD/multiclaude" ] || die "compilation failed"
}
if [ "$STATUS" = 1 ]; then
  [ -x "$BUILD/multiclaude" ] || build_tools
  exec "$BUILD/multiclaude" --status
fi

# The data folder is "~/Library/Application Support/<name>": keep names in the Claude family so an account
# can never land in another app's folder.
[[ "$NAME" =~ ^Claude\ [A-Za-z0-9][A-Za-z0-9\ ]*$ ]] || die "the name must look like \"Claude B\" (\"Claude \" followed by letters or digits)"
[ "$NAME" != "Claude Router" ] || die "\"Claude Router\" is taken by MultiClaude itself"
SLUG="$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"
BUNDLE_ID="app.multiclaude.$SLUG"
APP="/Applications/$NAME.app"
COPY_DIR="$ROOT/$NAME"
COPY_APP="$COPY_DIR/Claude.app"
DATA_DIR="$HOME/Library/Application Support/$NAME"

# Colour: asked for, else the one this account already has, else the next free one.
hue_of() { case "$1" in green) echo 120 ;; blue) echo 215 ;; purple) echo 255 ;; pink) echo 320 ;; teal) echo 165 ;; yellow) echo 45 ;; *) return 1 ;; esac; }
if [ -n "$COLOR" ]; then HUE="$(hue_of "$COLOR")" || die "unknown colour \"$COLOR\" (green, blue, purple, pink, teal, yellow) — or use --hue <degrees>"; fi
if [ -z "$HUE" ] && [ -f "$COPY_DIR/hue" ]; then HUE="$(cat "$COPY_DIR/hue")"; fi
if [ -z "$HUE" ]; then
  USED="$(cat "$ROOT"/*/hue 2>/dev/null || true)"
  for c in 120 215 255 320 165 45; do if ! grep -qx "$c" <<<"$USED"; then HUE="$c"; break; fi; done
  HUE="${HUE:-120}"
fi
[[ "$HUE" =~ ^[0-9]+$ ]] || die "--hue takes a number of degrees"

echo "→ $NAME"

# The account's own untouched copy of Claude.app: it updates itself from then on.
if [ "$REFRESH" = 1 ] && [ -d "$COPY_APP" ]; then
  if ps -axwwo command= | grep -F "$COPY_APP/Contents/MacOS/Claude" | grep -qv grep; then die "quit $NAME before --refresh-copy"; fi
  mv "$COPY_APP" "$HOME/.Trash/$NAME Claude.app $(date +%Y%m%d-%H%M%S)"
fi
if [ ! -d "$COPY_APP" ]; then
  echo "  copying Claude.app (about 650 MB)"
  mkdir -p "$COPY_DIR"
  ditto "$REAL" "$COPY_APP"
  codesign -v --deep --strict "$COPY_APP" || die "the copy's signature is invalid"
fi

echo "  building"
build_tools

echo "  icon"
ICONSET="$BUILD/$SLUG.iconset"
[ -d "$BUILD/orig.iconset" ] && rm -r "$BUILD/orig.iconset"
[ -d "$ICONSET" ] && rm -r "$ICONSET"
iconutil -c iconset "$REAL/Contents/Resources/electron.icns" -o "$BUILD/orig.iconset"
mkdir -p "$ICONSET"
for png in "$BUILD/orig.iconset"/*.png; do "$BUILD/hue" "$png" "$ICONSET/$(basename "$png")" "$HUE"; done
iconutil -c icns "$ICONSET" -o "$BUILD/$SLUG.icns"
rm -r "$BUILD/orig.iconset" "$ICONSET"

# bundle <folder.app> <name> <identifier> <role> <icon> <extra Info.plist keys>
bundle() {
  local dst="$1" name="$2" id="$3" role="$4" icon="$5" extra="$6"
  [ -d "$dst" ] && rm -r "$dst"
  mkdir -p "$dst/Contents/MacOS" "$dst/Contents/Resources"
  cp "$BUILD/multiclaude" "$dst/Contents/MacOS/multiclaude"
  cp "$icon" "$dst/Contents/Resources/AppIcon.icns"
  cat > "$dst/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>multiclaude</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>MultiClaudeRole</key><string>$role</string>
$extra
</dict></plist>
EOF
  echo "APPL????" > "$dst/Contents/PkgInfo"
  codesign --force --sign - "$dst" >/dev/null 2>&1 || true
}

STAGE="$BUILD/stage"
[ -d "$STAGE" ] && rm -r "$STAGE"
mkdir -p "$STAGE"
bundle "$STAGE/$NAME.app" "$NAME" "$BUNDLE_ID" launcher "$BUILD/$SLUG.icns" "  <key>MultiClaudeProfile</key><string>$NAME</string>"
bundle "$STAGE/Claude Router.app" "Claude Router" "$ROUTER_ID" router "$REAL/Contents/Resources/electron.icns" "  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Claude links, routed to the right instance</string>
      <key>CFBundleURLSchemes</key>
      <array><string>claude</string><string>msauth.com.anthropic.claudefordesktop</string></array>
    </dict>
  </array>"

# Stop our own helpers (launcher, router) before replacing them. Claude instances are independent
# processes and are never touched.
GUI="gui/$(id -u)"
launchctl bootout "$GUI/$ROUTER_ID" >/dev/null 2>&1 || true
stop_helpers() {
  ps -axwwo pid=,command= | grep -F -e "$APP/Contents/MacOS/" -e "$ROUTER/Contents/MacOS/" | grep -v grep | awk '{print $1}' | while read -r pid; do kill "$pid" 2>/dev/null || true; done || true
}
stop_helpers
sleep 1

echo "  installing"
install_bundle() {
  local src="$1" dst="$2"
  if [ -e "$dst" ]; then
    local old="$HOME/.Trash/$(basename "$dst" .app) $(date +%Y%m%d-%H%M%S).app"
    mv "$dst" "$old"
    "$LSREGISTER" -u "$old" >/dev/null 2>&1 || true
  fi
  ditto "$src" "$dst"
  "$LSREGISTER" -f "$dst" >/dev/null 2>&1 || true
  "$LSREGISTER" -u "$src" >/dev/null 2>&1 || true   # the build folder would show up as a duplicate
}
mkdir -p "$ROOT" "$DATA_DIR"
install_bundle "$STAGE/$NAME.app" "$APP"
install_bundle "$STAGE/Claude Router.app" "$ROUTER"
rm -r "$STAGE"

# The tinted icon goes on the copy itself: that is the tile the Dock shows while the account runs.
# It is an "Icon\r" file at the bundle root, outside the code signature, so the copy stays notarized.
# A Claude update wipes it; the router puts it back (it reads icon.icns).
cp "$BUILD/$SLUG.icns" "$COPY_DIR/icon.icns"
echo "$HUE" > "$COPY_DIR/hue"
if "$BUILD/multiclaude" --set-icon "$COPY_DIR/icon.icns" "$COPY_APP" && codesign --verify --deep "$COPY_APP" 2>/dev/null; then
  touch "$COPY_APP"
else
  echo "  note: macOS did not let this terminal put the icon on the copy; allow Claude Router (below) and it will do it" >&2
fi

# The ad hoc signature changes with every build: permissions granted to the previous identity are stale.
tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true
tccutil reset All "$ROUTER_ID" >/dev/null 2>&1 || true

# The router. As a login agent it is always there, which is what makes a click on the account's Dock tile safe.
if [ "$AGENT" = 1 ]; then
  mkdir -p "$(dirname "$AGENT_PLIST")"
  cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$ROUTER_ID</string>
  <key>ProgramArguments</key>
  <array><string>$ROUTER/Contents/MacOS/multiclaude</string><string>--agent</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF
  launchctl bootstrap "$GUI" "$AGENT_PLIST" 2>/dev/null || launchctl kickstart -k "$GUI/$ROUTER_ID" 2>/dev/null || open -g "$ROUTER"
else
  [ -f "$AGENT_PLIST" ] && mv "$AGENT_PLIST" "$HOME/.Trash/$ROUTER_ID $(date +%Y%m%d-%H%M%S).plist"
  open -g "$ROUTER"
fi

# One Dock tile per account: the copy itself (it shows the running dot), in place of the launcher.
dock_pin() {
  /usr/bin/python3 - "$COPY_APP" "$APP" <<'PY'
import plistlib, subprocess, sys, urllib.parse
copy, launcher = sys.argv[1], sys.argv[2]
def url(p): return "file://" + urllib.parse.quote(p.rstrip("/")) + "/"
d = plistlib.loads(subprocess.run(["defaults", "export", "com.apple.dock", "-"], capture_output=True, check=True).stdout)
apps = d.get("persistent-apps", [])
def u(e): return e.get("tile-data", {}).get("file-data", {}).get("_CFURLString", "")
tile = {"tile-type": "file-tile", "tile-data": {"file-data": {"_CFURLString": url(copy), "_CFURLStringType": 15},
        "file-label": "Claude", "bundle-identifier": "com.anthropic.claudefordesktop"}}
before = [u(e) for e in apps]
placed = url(copy) in before
out, seen = [], set()
for e in apps:
    x = u(e)
    if x == url(launcher):                      # the launcher's tile becomes the account's tile
        if not placed: out.append(tile); placed = True; seen.add(url(copy))
        continue
    if x in seen and "/Claude" in urllib.parse.unquote(x): continue   # a Claude tile pinned twice
    seen.add(x); out.append(e)
if not placed:                                  # otherwise right after the last Claude tile
    idx = max([i for i, e in enumerate(out) if e.get("tile-data", {}).get("bundle-identifier") == "com.anthropic.claudefordesktop"], default=len(out) - 1)
    out.insert(idx + 1, tile)
if [u(e) for e in out] == before: sys.exit(1)
d["persistent-apps"] = out
subprocess.run(["defaults", "import", "com.apple.dock", "-"], input=plistlib.dumps(d), check=True)
PY
}
if [ "$DOCK" = 1 ] && [ "$AGENT" = 1 ]; then
  if dock_pin; then killall Dock 2>/dev/null || true; echo "  Dock: one tile for $NAME"; fi
fi

cat <<EOF

$NAME is installed.

  Open it      click its tile in the Dock, or look for "$NAME" in Spotlight
  First time   sign in with the other account in the window that opens
  One setting  System Settings › Privacy & Security › App Management › turn on "Claude Router"
               (lets it put the coloured icon back after each Claude update)
  Status       ./install.sh --status        Log: ~/Library/Logs/MultiClaude.log
EOF
