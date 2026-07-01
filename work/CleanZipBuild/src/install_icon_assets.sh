#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/CleanZip.app"
SERVICE="$ROOT/CleanZipService.service"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  for candidate in \
    "/Applications/Xcode.app/Contents/Developer" \
    "/Applications/Xcode-beta.app/Contents/Developer" \
    "$HOME/Applications/Xcode.app/Contents/Developer" \
    "$HOME/Applications/Xcode-beta.app/Contents/Developer"; do
    if [[ -x "$candidate/usr/bin/actool" ]]; then
      export DEVELOPER_DIR="$candidate"
      break
    fi
  done
fi

if [[ -z "${DEVELOPER_DIR:-}" || ! -x "$DEVELOPER_DIR/usr/bin/actool" ]]; then
  echo "No real Xcode actool found. Install or mount Xcode 26+, or run .github/workflows/cleanzip-liquid-glass-icon.yml and install its artifact." >&2
  exit 2
fi

python3 "$ROOT/src/generate_filled_icon.py"

codesign --force --deep --sign - "$APP"
codesign --force --deep --sign - "$SERVICE"
ditto "$APP" "$HOME/Applications/CleanZip.app"
ditto "$SERVICE" "$HOME/Library/Services/CleanZipService.service"
codesign --force --deep --sign - "$HOME/Applications/CleanZip.app"
codesign --force --deep --sign - "$HOME/Library/Services/CleanZipService.service"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Applications/CleanZip.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Library/Services/CleanZipService.service"
/System/Library/CoreServices/pbs -flush 2>/dev/null || true
qlmanage -r cache >/dev/null 2>&1 || true
if [[ "${CLEANZIP_RESTART_FINDER:-0}" == "1" ]]; then
  killall Finder 2>/dev/null || true
fi
if [[ "${CLEANZIP_RESTART_DOCK:-0}" == "1" ]]; then
  killall Dock 2>/dev/null || true
fi

if [[ -f "$HOME/Applications/CleanZip.app/Contents/Resources/Assets.car" ]]; then
  echo "Installed dynamic Liquid Glass Assets.car for CleanZip."
else
  echo "Installed static fallback only; Assets.car was not created." >&2
  exit 3
fi
