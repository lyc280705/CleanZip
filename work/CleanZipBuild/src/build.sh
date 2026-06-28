#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/CleanZip.app"
SERVICE="$ROOT/CleanZipService.service"

mkdir -p "$APP/Contents/MacOS" "$SERVICE/Contents/MacOS"

xcrun swiftc -O -parse-as-library \
  -framework AppKit \
  -framework SwiftUI \
  -framework Combine \
  -framework UniformTypeIdentifiers \
  -framework UserNotifications \
  "$ROOT/src/main.swift" \
  -o "$APP/Contents/MacOS/CleanZip"

xcrun swiftc -O -parse-as-library \
  -framework AppKit \
  -framework UserNotifications \
  "$ROOT/src/service.swift" \
  -o "$SERVICE/Contents/MacOS/CleanZipService"

chmod +x "$APP/Contents/MacOS/CleanZip" "$SERVICE/Contents/MacOS/CleanZipService"
codesign --force --deep --sign - "$APP"
codesign --force --deep --sign - "$SERVICE"

echo "Built $APP"
echo "Built $SERVICE"
