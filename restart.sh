#!/usr/bin/env bash
# Build, bundle, sign, install and relaunch Recall It.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${RECALL_IT_APP_PATH:-$HOME/Applications/Recall It.app}"
BUNDLE_ID='com.mikerosoft.recall-it'
# Stop only processes running from this exact destination, including isolated test installs.
app_pids() {
  local PID
  while read -r PID; do
    if [[ "$(ps -p "$PID" -o comm= 2>/dev/null || true)" == "$APP/Contents/MacOS/RecallIt" ]]; then echo "$PID"; fi
  done < <(pgrep -x RecallIt || true)
}
stop_app() {
  local PID WAIT
  while read -r PID; do
    [[ -n "$PID" ]] || continue
    kill -TERM "$PID" 2>/dev/null || true
    for WAIT in {1..30}; do
      if ! kill -0 "$PID" 2>/dev/null; then break; fi
      sleep 0.1
    done
    if kill -0 "$PID" 2>/dev/null; then
      echo 'Recall It is still running at this install path. Quit it before continuing.' >&2
      return 1
    fi
  done < <(app_pids)
}
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/module-cache"
cd "$ROOT"
BUILD_ARGS=(--disable-sandbox)
swift build -c release "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build -c release --show-bin-path "${BUILD_ARGS[@]}")"
STAGE_ROOT="$(mktemp -d "$ROOT/.build/stage.XXXXXX")"
trap 'rm -rf "$STAGE_ROOT"' EXIT
STAGE="$STAGE_ROOT/Recall It.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN_DIR/RecallIt" "$STAGE/Contents/MacOS/RecallIt"
ICON_KEY=''
if [[ -f "$ROOT/icons/recall-it.png" ]]; then
  mkdir -p "$STAGE_ROOT/icon.iconset"
  for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$ROOT/icons/recall-it.png" --out "$STAGE_ROOT/icon.iconset/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$ROOT/icons/recall-it.png" --out "$STAGE_ROOT/icon.iconset/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
  done
  iconutil -c icns "$STAGE_ROOT/icon.iconset" -o "$STAGE/Contents/Resources/RecallIt.icns"
  ICON_KEY='<key>CFBundleIconFile</key><string>RecallIt.icns</string>'
fi
cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>Recall It</string>
<key>CFBundleDisplayName</key><string>Recall It</string>
<key>CFBundleExecutable</key><string>RecallIt</string>
$ICON_KEY
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Recall It asks your browser whether its front window is private, so it never records incognito windows.</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Mike Cann. MIT licensed.</string>
</dict></plist>
PLIST
IDENTITY="${RECALL_IT_CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1)}"
# Keep the designated requirement stable so the Accessibility grant survives a rebuild.
codesign --force --timestamp=none --sign "${IDENTITY:--}" --requirements "=designated => identifier \"$BUNDLE_ID\"" "$STAGE"
codesign --verify --strict "$STAGE"
# Validate the destination before stopping or replacing anything.
if [[ -e "$APP" || -L "$APP" ]]; then
  if [[ -L "$APP" || "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)" != "$BUNDLE_ID" ]]; then
    echo "An unrelated item exists at $APP. Move it before installing." >&2
    exit 1
  fi
fi
stop_app
mkdir -p "$(dirname "$APP")"
if [[ -d "$APP" ]]; then rm -rf "$APP"; fi
mv "$STAGE" "$APP"
if [[ "${RECALL_IT_OPEN:-1}" != 0 ]]; then open "$APP"; fi
echo "Installed $APP"
echo "Log: tail -f ~/Library/Logs/recall-it.log"
