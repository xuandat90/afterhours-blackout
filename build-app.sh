#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/Afterhours BlackOut.app"
BIN="$ROOT/.build/debug/AfterhoursBlackOut"

swift build --package-path "$ROOT" -c debug
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/AfterhoursBlackOut"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" 2>/dev/null || true
printf 'Built %s\n' "$APP"
