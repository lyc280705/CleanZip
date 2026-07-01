#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/CleanZip.app"
SERVICE="$ROOT/CleanZipService.service"
DIST="$ROOT/dist"
ROOT_DIR="$DIST/pkgroot"
SCRIPTS_DIR="$DIST/scripts"

export COPYFILE_DISABLE=1

if [[ ! -d "$APP" || ! -d "$SERVICE" ]]; then
  echo "CleanZip.app or CleanZipService.service is missing. Run src/build.sh first." >&2
  exit 2
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
PACKAGE_VERSION="$VERSION.$BUILD"
PKG_NAME="CleanZip-$PACKAGE_VERSION.pkg"
ZIP_NAME="CleanZip-$PACKAGE_VERSION.zip"

rm -rf "$DIST"
mkdir -p "$ROOT_DIR/Applications" "$ROOT_DIR/Library/Services" "$SCRIPTS_DIR"

ditto --norsrc "$APP" "$ROOT_DIR/Applications/CleanZip.app"
ditto --norsrc "$SERVICE" "$ROOT_DIR/Library/Services/CleanZipService.service"
xattr -cr "$ROOT_DIR" 2>/dev/null || true
find "$ROOT_DIR" -name '._*' -delete

cat > "$SCRIPTS_DIR/postinstall" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

APP="/Applications/CleanZip.app"
SERVICE="/Library/Services/CleanZipService.service"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
  "$LSREGISTER" -f "$SERVICE" >/dev/null 2>&1 || true
fi

/System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true
if [[ "${CLEANZIP_RESTART_FINDER:-0}" == "1" ]]; then
  killall Finder >/dev/null 2>&1 || true
fi

exit 0
SCRIPT
chmod +x "$SCRIPTS_DIR/postinstall"

pkgbuild \
  --root "$ROOT_DIR" \
  --scripts "$SCRIPTS_DIR" \
  --identifier "local.codex.cleanzip.pkg" \
  --version "$PACKAGE_VERSION" \
  --install-location "/" \
  "$DIST/$PKG_NAME"

ZIP_ROOT="$DIST/ziproot/CleanZip"
mkdir -p "$ZIP_ROOT"
ditto --norsrc "$APP" "$ZIP_ROOT/CleanZip.app"
ditto --norsrc "$SERVICE" "$ZIP_ROOT/CleanZipService.service"
xattr -cr "$ZIP_ROOT" 2>/dev/null || true
find "$ZIP_ROOT" -name '._*' -delete
ditto -c -k --norsrc --keepParent "$ZIP_ROOT" "$DIST/$ZIP_NAME"

(
  cd "$DIST"
  shasum -a 256 "$PKG_NAME" "$ZIP_NAME" > SHA256SUMS.txt
)

echo "$DIST/$PKG_NAME"
echo "$DIST/$ZIP_NAME"
echo "$DIST/SHA256SUMS.txt"
