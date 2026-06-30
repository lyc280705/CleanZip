#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/CleanZip.app"
SERVICE="$ROOT/CleanZipService.service"
RESOURCES="$ROOT/src/Resources"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
ARCHS="${CLEANZIP_ARCHS:-arm64 x86_64}"
BUILD_DIR="$ROOT/build"

export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$SERVICE/Contents/MacOS" "$SERVICE/Contents/Resources"

if [[ -d "$RESOURCES" ]]; then
  rsync -a "$RESOURCES/" "$APP/Contents/Resources/"
  rsync -a "$RESOURCES/" "$SERVICE/Contents/Resources/"
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

app_slices=()
service_slices=()
for arch in $ARCHS; do
  target="${arch}-apple-macos${DEPLOYMENT_TARGET}"
  app_slice="$BUILD_DIR/CleanZip.${arch}"
  service_slice="$BUILD_DIR/CleanZipService.${arch}"

  xcrun swiftc -O -parse-as-library \
    -target "$target" \
    -framework AppKit \
    -framework SwiftUI \
    -framework Combine \
    -framework UniformTypeIdentifiers \
    -framework UserNotifications \
    "$ROOT/src/main.swift" \
    -o "$app_slice"

  xcrun swiftc -O -parse-as-library \
    -target "$target" \
    -framework AppKit \
    -framework UserNotifications \
    "$ROOT/src/service.swift" \
    -o "$service_slice"

  app_slices+=("$app_slice")
  service_slices+=("$service_slice")
done

if [[ "${#app_slices[@]}" -gt 1 ]]; then
  lipo -create "${app_slices[@]}" -output "$APP/Contents/MacOS/CleanZip"
  lipo -create "${service_slices[@]}" -output "$SERVICE/Contents/MacOS/CleanZipService"
else
  cp "${app_slices[0]}" "$APP/Contents/MacOS/CleanZip"
  cp "${service_slices[0]}" "$SERVICE/Contents/MacOS/CleanZipService"
fi

chmod +x "$APP/Contents/MacOS/CleanZip" "$SERVICE/Contents/MacOS/CleanZipService"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $DEPLOYMENT_TARGET" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $DEPLOYMENT_TARGET" "$SERVICE/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
codesign --force --deep --sign - "$SERVICE"

echo "Built $APP"
echo "Built $SERVICE"
