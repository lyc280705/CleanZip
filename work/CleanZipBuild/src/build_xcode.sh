#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/CleanZip.xcodeproj"
DERIVED_DATA="${CLEANZIP_DERIVED_DATA:-$ROOT/build/XcodeDerivedData}"
CONFIGURATION="${CONFIGURATION:-Release}"
APP="$ROOT/CleanZip.app"
SERVICE="$ROOT/CleanZipService.service"
PRODUCTS="$DERIVED_DATA/Build/Products/$CONFIGURATION"

if ! xcodebuild -version >/dev/null 2>&1; then
  cat >&2 <<'MSG'
CleanZip's release build now uses an Xcode project.
Install full Xcode locally, or run the GitHub Actions workflow that builds with Xcode on macOS.
MSG
  exit 2
fi

if [[ ! -d "$PROJECT" ]]; then
  echo "Missing Xcode project: $PROJECT" >&2
  exit 2
fi

rm -rf "$DERIVED_DATA"

common_settings=(
  -project "$PROJECT"
  -configuration "$CONFIGURATION"
  -derivedDataPath "$DERIVED_DATA"
  -destination "generic/platform=macOS"
  CODE_SIGNING_ALLOWED=NO
  ONLY_ACTIVE_ARCH=NO
)

xcodebuild "${common_settings[@]}" -scheme CleanZip build
xcodebuild "${common_settings[@]}" -scheme CleanZipService build

if [[ ! -d "$PRODUCTS/CleanZip.app" ]]; then
  echo "Xcode did not produce $PRODUCTS/CleanZip.app" >&2
  exit 3
fi

if [[ ! -d "$PRODUCTS/CleanZipService.service" ]]; then
  echo "Xcode did not produce $PRODUCTS/CleanZipService.service" >&2
  exit 3
fi

rm -rf "$APP" "$SERVICE"
ditto "$PRODUCTS/CleanZip.app" "$APP"
ditto "$PRODUCTS/CleanZipService.service" "$SERVICE"

if [[ -x "$APP/Contents/Resources/7zz" ]]; then
  chmod +x "$APP/Contents/Resources/7zz"
fi

if [[ -x "$SERVICE/Contents/Resources/7zz" ]]; then
  chmod +x "$SERVICE/Contents/Resources/7zz"
fi

codesign --force --deep --sign - "$APP"
codesign --force --deep --sign - "$SERVICE"

echo "Built $APP"
echo "Built $SERVICE"
